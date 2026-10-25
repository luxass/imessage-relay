#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="${repo_root}/Sources/RelayServer/Server.swift"
source_version="$(sed -nE 's|^[[:space:]]*public let packageVersion = "([^"]+)"([[:space:]]*//.*)?[[:space:]]*$|\1|p' "${version_file}")"

if [[ -z "${source_version}" ]]; then
    echo "Could not read packageVersion from ${version_file}" >&2
    exit 1
fi

requested_version="${1:-${source_version}}"
version_number='(0|[1-9][0-9]*)'
prerelease_identifier='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
build_identifier='[0-9A-Za-z-]+'
version_pattern="^${version_number}\.${version_number}\.${version_number}"
version_pattern+="(-${prerelease_identifier}(\.${prerelease_identifier})*)?"
version_pattern+="(\+${build_identifier}(\.${build_identifier})*)?$"
if [[ ! "${requested_version}" =~ ${version_pattern} ]]; then
    echo "Release version must be a semantic version without a leading v: ${requested_version}" >&2
    exit 1
fi
if [[ "${requested_version}" != "${source_version}" ]]; then
    echo "Release version ${requested_version} does not match packageVersion ${source_version}" >&2
    exit 1
fi

output_dir="${2:-dist}"
if [[ "${output_dir}" != /* ]]; then
    output_dir="${repo_root}/${output_dir}"
fi

archive_name="imessage-relay-${requested_version}-macos-universal.zip"
release_tmp="$(mktemp -d "${TMPDIR:-/tmp}/imessage-relay-release.XXXXXX")"
codesign_identity="${CODESIGN_IDENTITY:--}"
notarize_release="${NOTARIZE_RELEASE:-0}"

cleanup() {
    rm -rf "${release_tmp}"
}
trap cleanup EXIT

copy_resource_bundles() {
    local destination="$1"
    local bundle
    for bundle in "${binary_dir}"/*.bundle; do
        [[ -d "${bundle}" ]] || continue
        ditto "${bundle}" "${destination}/$(basename "${bundle}")"
    done
}

sign_path() {
    local path="$1"
    local identifier="$2"
    local entitlements="${3:-}"
    local arguments=(
        --force
        --sign "${codesign_identity}"
        --identifier "${identifier}"
        --options runtime
    )
    if [[ "${codesign_identity}" == "-" ]]; then
        arguments+=(--timestamp=none)
    else
        arguments+=(--timestamp)
    fi
    if [[ -n "${entitlements}" ]]; then
        arguments+=(--entitlements "${entitlements}")
    fi
    codesign "${arguments[@]}" "${path}"
}

cd "${repo_root}"
./scripts/check-swift-version.sh
swift build -c release --arch arm64 --arch x86_64 --product imessage-relay
swift build -c release --arch arm64 --arch x86_64 --product imessage-relay-app
binary_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
cli_binary="${binary_dir}/imessage-relay"
app_binary="${binary_dir}/imessage-relay-app"

if [[ ! -d "${binary_dir}/PhoneNumberKit_PhoneNumberKit.bundle" ]]; then
    echo "PhoneNumberKit resource bundle is missing from ${binary_dir}" >&2
    exit 1
fi
resource_bundle_names=()
for bundle in "${binary_dir}"/*.bundle; do
    [[ -d "${bundle}" ]] || continue
    resource_bundle_names+=("$(basename "${bundle}")")
done

for binary in "${cli_binary}" "${app_binary}"; do
    if [[ ! -x "${binary}" ]]; then
        echo "Release binary is missing or not executable: ${binary}" >&2
        exit 1
    fi
    lipo "${binary}" -verify_arch arm64
    lipo "${binary}" -verify_arch x86_64
done

reported_version="$(${cli_binary} --version)"
if [[ "${reported_version}" != "${requested_version}" ]]; then
    echo "Binary reports ${reported_version}; expected ${requested_version}" >&2
    exit 1
fi

mkdir -p "${output_dir}"
release_staging="${release_tmp}/staging"
mkdir -p "${release_staging}"
install -m 0755 "${cli_binary}" "${release_staging}/imessage-relay"
install -m 0644 "${repo_root}/LICENSE" "${release_staging}/LICENSE"
copy_resource_bundles "${release_staging}"
sign_path \
    "${release_staging}/imessage-relay" \
    "dev.luxass.imessage-relay.cli" \
    "${repo_root}/Distribution/iMessageRelay.entitlements"
codesign --verify --strict --verbose=2 "${release_staging}/imessage-relay"

app_path="${release_staging}/iMessage Relay.app"
mkdir -p "${app_path}/Contents/MacOS" "${app_path}/Contents/Resources"
install -m 0755 "${app_binary}" "${app_path}/Contents/MacOS/iMessage Relay"
install -m 0644 "${repo_root}/LICENSE" "${app_path}/Contents/Resources/LICENSE"
copy_resource_bundles "${app_path}/Contents/Resources"
bash "${repo_root}/scripts/create-app-icon.sh" \
    "${repo_root}/Distribution/AppIcon.svg" \
    "${app_path}/Contents/Resources/AppIcon.icns"
build_version="${requested_version%%[-+]*}"
sed \
    -e "s/__VERSION__/${requested_version}/g" \
    -e "s/__BUILD_VERSION__/${build_version}/g" \
    "${repo_root}/Distribution/Info.plist.template" > "${app_path}/Contents/Info.plist"
plutil -lint "${app_path}/Contents/Info.plist"
xattr -cr "${app_path}"
sign_path \
    "${app_path}" \
    "dev.luxass.imessage-relay" \
    "${repo_root}/Distribution/iMessageRelay.entitlements"
codesign --verify --deep --strict --verbose=2 "${app_path}"

notary_submission="${release_tmp}/notary-submission.zip"
if [[ "${notarize_release}" == "1" ]]; then
    if [[ "${codesign_identity}" == "-" ]]; then
        echo "NOTARIZE_RELEASE=1 requires a Developer ID CODESIGN_IDENTITY." >&2
        exit 1
    fi
    : "${NOTARY_KEY_PATH:?NOTARIZE_RELEASE=1 requires NOTARY_KEY_PATH}"
    : "${NOTARY_KEY_ID:?NOTARIZE_RELEASE=1 requires NOTARY_KEY_ID}"
    : "${NOTARY_ISSUER_ID:?NOTARIZE_RELEASE=1 requires NOTARY_ISSUER_ID}"
    ditto -c -k --sequesterRsrc "${release_staging}" "${notary_submission}"
    xcrun notarytool submit "${notary_submission}" \
        --key "${NOTARY_KEY_PATH}" \
        --key-id "${NOTARY_KEY_ID}" \
        --issuer "${NOTARY_ISSUER_ID}" \
        --wait
    xcrun stapler staple "${app_path}"
    xcrun stapler validate "${app_path}"
    spctl --assess --type execute --verbose=2 "${app_path}"
fi

release_verification="${release_tmp}/verification"
ditto -c -k --sequesterRsrc "${release_staging}" "${output_dir}/${archive_name}"
mkdir -p "${release_verification}"
ditto -x -k "${output_dir}/${archive_name}" "${release_verification}"

archive_entries="$(for entry in "${release_verification}"/*; do basename "${entry}"; done | LC_ALL=C sort)"
expected_entries="$(printf '%s\n' 'iMessage Relay.app' imessage-relay LICENSE "${resource_bundle_names[@]}" | LC_ALL=C sort)"
if [[ "${archive_entries}" != "${expected_entries}" ]]; then
    echo "Release archive contains unexpected entries:" >&2
    printf '%s\n' "${archive_entries}" >&2
    exit 1
fi

lipo "${release_verification}/imessage-relay" -verify_arch arm64
lipo "${release_verification}/imessage-relay" -verify_arch x86_64
codesign --verify --strict --verbose=2 "${release_verification}/imessage-relay"
for bundle_name in "${resource_bundle_names[@]}"; do
    [[ -d "${release_verification}/${bundle_name}" ]] || {
        echo "Release archive is missing CLI resource bundle ${bundle_name}." >&2
        exit 1
    }
done
if [[ "$("${release_verification}/imessage-relay" --version)" != "${requested_version}" ]]; then
    echo "Packaged CLI version does not match ${requested_version}." >&2
    exit 1
fi

verified_app="${release_verification}/iMessage Relay.app"
codesign --verify --deep --strict --verbose=2 "${verified_app}"
for bundle_name in "${resource_bundle_names[@]}"; do
    [[ -d "${verified_app}/Contents/Resources/${bundle_name}" ]] || {
        echo "App archive is missing resource bundle ${bundle_name}." >&2
        exit 1
    }
done
lipo "${verified_app}/Contents/MacOS/iMessage Relay" -verify_arch arm64
lipo "${verified_app}/Contents/MacOS/iMessage Relay" -verify_arch x86_64
if [[ "$(defaults read "${verified_app}/Contents/Info" CFBundleShortVersionString)" != "${requested_version}" ]]; then
    echo "Packaged app version does not match ${requested_version}." >&2
    exit 1
fi
if [[ "$(defaults read "${verified_app}/Contents/Info" CFBundleIdentifier)" != "dev.luxass.imessage-relay" ]]; then
    echo "Packaged app has an unexpected bundle identifier." >&2
    exit 1
fi
if [[ "$(defaults read "${verified_app}/Contents/Info" LSUIElement)" != "1" ]]; then
    echo "Packaged app is not configured as a menu-bar app." >&2
    exit 1
fi
verified_entitlements="${release_tmp}/verified-entitlements.plist"
codesign -d --entitlements :- "${verified_app}" > "${verified_entitlements}" 2>/dev/null
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "${verified_entitlements}")" != "true" ]]; then
    echo "Packaged app is missing the Apple Events entitlement." >&2
    exit 1
fi
if [[ "${notarize_release}" == "1" ]]; then
    xcrun stapler validate "${verified_app}"
fi

(
    cd "${output_dir}"
    shasum -a 256 "${archive_name}" > SHA256SUMS
    shasum -a 256 --check SHA256SUMS
)

for artifact in "${archive_name}" SHA256SUMS; do
    printf 'Created %s\n' "${output_dir}/${artifact}"
done

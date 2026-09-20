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

cli_archive_name="imessage-relay-server-${requested_version}-macos-universal.tar.gz"
latest_cli_archive_name="relay-server-macos-universal.tar.gz"
app_archive_name="imessage-relay-${requested_version}-macos-universal.zip"
latest_app_archive_name="imessage-relay-macos-universal.zip"
release_tmp="$(mktemp -d "${TMPDIR:-/tmp}/imessage-relay-release.XXXXXX")"
codesign_identity="${CODESIGN_IDENTITY:--}"
notarize_release="${NOTARIZE_RELEASE:-0}"

cleanup() {
    rm -rf "${release_tmp}"
}
trap cleanup EXIT

checksum() {
    local filename="$1"
    (
        cd "${output_dir}"
        shasum -a 256 "${filename}" > "${filename}.sha256"
        shasum -a 256 --check "${filename}.sha256"
    )
}

create_icon() {
    local iconset="${release_tmp}/AppIcon.iconset"
    mkdir -p "${iconset}"
    while read -r filename size; do
        sips -s format png -z "${size}" "${size}" \
            "${repo_root}/Distribution/AppIcon.svg" \
            --out "${iconset}/${filename}" >/dev/null
    done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES
    iconutil --convert icns --output "$1" "${iconset}"
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
swift build -c release --arch arm64 --arch x86_64 --product relay-server
swift build -c release --arch arm64 --arch x86_64 --product imessage-relay-app
binary_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
cli_binary="${binary_dir}/relay-server"
app_binary="${binary_dir}/imessage-relay-app"

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
cli_staging="${release_tmp}/cli-staging"
cli_verification="${release_tmp}/cli-verification"
mkdir -p "${cli_staging}" "${cli_verification}"
install -m 0755 "${cli_binary}" "${cli_staging}/relay-server"
install -m 0644 "${repo_root}/LICENSE" "${cli_staging}/LICENSE"
sign_path \
    "${cli_staging}/relay-server" \
    "dev.luxass.imessage-relay.cli" \
    "${repo_root}/Distribution/iMessageRelay.entitlements"
codesign --verify --strict --verbose=2 "${cli_staging}/relay-server"
touch -t 198001010000 "${cli_staging}/relay-server" "${cli_staging}/LICENSE"

export COPYFILE_DISABLE=1
tar -C "${cli_staging}" -cf - relay-server LICENSE \
    | gzip -n > "${output_dir}/${cli_archive_name}"
checksum "${cli_archive_name}"
install -m 0644 \
    "${output_dir}/${cli_archive_name}" \
    "${output_dir}/${latest_cli_archive_name}"
checksum "${latest_cli_archive_name}"

archive_entries="$(tar -tzf "${output_dir}/${cli_archive_name}")"
expected_entries=$'relay-server\nLICENSE'
if [[ "${archive_entries}" != "${expected_entries}" ]]; then
    echo "CLI archive contains unexpected entries:" >&2
    printf '%s\n' "${archive_entries}" >&2
    exit 1
fi

tar -xzf "${output_dir}/${cli_archive_name}" -C "${cli_verification}"
lipo "${cli_verification}/relay-server" -verify_arch arm64
lipo "${cli_verification}/relay-server" -verify_arch x86_64
codesign --verify --strict --verbose=2 "${cli_verification}/relay-server"
if [[ "$("${cli_verification}/relay-server" --version)" != "${requested_version}" ]]; then
    echo "Packaged CLI version does not match ${requested_version}." >&2
    exit 1
fi

app_path="${release_tmp}/iMessage Relay.app"
mkdir -p "${app_path}/Contents/MacOS" "${app_path}/Contents/Resources"
install -m 0755 "${app_binary}" "${app_path}/Contents/MacOS/iMessage Relay"
install -m 0644 "${repo_root}/LICENSE" "${app_path}/Contents/Resources/LICENSE"
create_icon "${app_path}/Contents/Resources/AppIcon.icns"
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
    notary_staging="${release_tmp}/notary-staging"
    mkdir -p "${notary_staging}"
    ditto "${app_path}" "${notary_staging}/iMessage Relay.app"
    install -m 0755 "${cli_staging}/relay-server" "${notary_staging}/relay-server"
    ditto -c -k --sequesterRsrc "${notary_staging}" "${notary_submission}"
    xcrun notarytool submit "${notary_submission}" \
        --key "${NOTARY_KEY_PATH}" \
        --key-id "${NOTARY_KEY_ID}" \
        --issuer "${NOTARY_ISSUER_ID}" \
        --wait
    xcrun stapler staple "${app_path}"
    xcrun stapler validate "${app_path}"
    spctl --assess --type execute --verbose=2 "${app_path}"
    spctl --assess --type execute --verbose=2 "${cli_staging}/relay-server"
fi

app_verification="${release_tmp}/app-verification"
ditto -c -k --sequesterRsrc --keepParent \
    "${app_path}" "${output_dir}/${app_archive_name}"
checksum "${app_archive_name}"
install -m 0644 \
    "${output_dir}/${app_archive_name}" \
    "${output_dir}/${latest_app_archive_name}"
checksum "${latest_app_archive_name}"
mkdir -p "${app_verification}"
ditto -x -k "${output_dir}/${app_archive_name}" "${app_verification}"
verified_app="${app_verification}/iMessage Relay.app"
codesign --verify --deep --strict --verbose=2 "${verified_app}"
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

for artifact in \
    "${cli_archive_name}" "${cli_archive_name}.sha256" \
    "${latest_cli_archive_name}" "${latest_cli_archive_name}.sha256" \
    "${app_archive_name}" "${app_archive_name}.sha256" \
    "${latest_app_archive_name}" "${latest_app_archive_name}.sha256"; do
    printf 'Created %s\n' "${output_dir}/${artifact}"
done

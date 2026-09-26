#!/usr/bin/env bash

# Build a development .app bundle around the debug binary.
#
# `swift run` launches the raw binary without a bundle, so activation,
# LSUIElement behavior, and permission dialogs differ from the shipped app.
# This script assembles a real (ad hoc signed) bundle instead:
#
#   ./scripts/build-dev-app.sh [output_dir]
#   open "dist/dev/iMessage Relay.app"
#
# No notarization or universal binary: speed over ceremony.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="${repo_root}/Sources/RelayServer/Server.swift"
source_version="$(sed -nE 's|^[[:space:]]*public let packageVersion = "([^"]+)"([[:space:]]*//.*)?[[:space:]]*$|\1|p' "${version_file}")"

if [[ -z "${source_version}" ]]; then
    echo "Could not read packageVersion from ${version_file}" >&2
    exit 1
fi

output_dir="${1:-dist/dev}"
if [[ "${output_dir}" != /* ]]; then
    output_dir="${repo_root}/${output_dir}"
fi
# Ad-hoc ("-") re-signs with a fresh identity on every build, which voids
# existing TCC grants. Pass CODESIGN_IDENTITY with an Apple Development
# identity (free Apple ID works) to keep grants stable across rebuilds.
codesign_identity="${CODESIGN_IDENTITY:--}"

cd "${repo_root}"
swift build --product imessage-relay-app
binary_dir="$(swift build --show-bin-path)"
app_binary="${binary_dir}/imessage-relay-app"

if [[ ! -x "${app_binary}" ]]; then
    echo "App binary is missing or not executable: ${app_binary}" >&2
    exit 1
fi

app_path="${output_dir}/iMessage Relay.app"
rm -rf "${app_path}"
mkdir -p "${app_path}/Contents/MacOS" "${app_path}/Contents/Resources"
install -m 0755 "${app_binary}" "${app_path}/Contents/MacOS/iMessage Relay"
install -m 0644 "${repo_root}/LICENSE" "${app_path}/Contents/Resources/LICENSE"

bundle_copied=0
for bundle in "${binary_dir}"/*.bundle; do
    [[ -d "${bundle}" ]] || continue
    ditto "${bundle}" "${app_path}/Contents/Resources/$(basename "${bundle}")"
    bundle_copied=1
done
if [[ "${bundle_copied}" == "0" ]]; then
    echo "Warning: no SwiftPM resource bundles found in ${binary_dir}." >&2
fi

bash "${repo_root}/scripts/create-app-icon.sh" \
    "${repo_root}/Distribution/AppIcon.svg" \
    "${app_path}/Contents/Resources/AppIcon.icns"

build_version="${source_version%%[-+]*}"
sed \
    -e "s/__VERSION__/${source_version}/g" \
    -e "s/__BUILD_VERSION__/${build_version}/g" \
    "${repo_root}/Distribution/Info.plist.template" > "${app_path}/Contents/Info.plist"
plutil -lint "${app_path}/Contents/Info.plist" >/dev/null

xattr -cr "${app_path}"
codesign --force --sign "${codesign_identity}" \
    --entitlements "${repo_root}/Distribution/iMessageRelay.entitlements" \
    "${app_path}"
codesign --verify --deep --strict --verbose=2 "${app_path}"

printf 'Built %s\n' "${app_path}"
printf 'Run it with: open "%s"\n' "${app_path}"

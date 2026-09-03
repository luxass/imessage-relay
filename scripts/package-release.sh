#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="${repo_root}/Sources/relay-server/Application+build.swift"
source_version="$(sed -nE 's/^let packageVersion = "([^"]+)"$/\1/p' "${version_file}")"

if [[ -z "${source_version}" ]]; then
    echo "Could not read packageVersion from ${version_file}" >&2
    exit 1
fi

requested_version="${1:-${source_version}}"
if [[ ! "${requested_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
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

archive_name="relay-server-macos-universal.tar.gz"
checksum_name="${archive_name}.sha256"
release_tmp="$(mktemp -d "${TMPDIR:-/tmp}/imessage-relay-release.XXXXXX")"

cleanup() {
    rm -rf "${release_tmp}"
}
trap cleanup EXIT

cd "${repo_root}"
swift build -c release --arch arm64 --arch x86_64
binary_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
binary_path="${binary_dir}/relay-server"

if [[ ! -x "${binary_path}" ]]; then
    echo "Release binary is missing or not executable: ${binary_path}" >&2
    exit 1
fi

lipo "${binary_path}" -verify_arch arm64
lipo "${binary_path}" -verify_arch x86_64

reported_version="$(${binary_path} --version)"
if [[ "${reported_version}" != "${requested_version}" ]]; then
    echo "Binary reports ${reported_version}; expected ${requested_version}" >&2
    exit 1
fi

staging_dir="${release_tmp}/staging"
verification_dir="${release_tmp}/verification"
mkdir -p "${staging_dir}" "${verification_dir}" "${output_dir}"
install -m 0755 "${binary_path}" "${staging_dir}/relay-server"
install -m 0644 "${repo_root}/LICENSE" "${staging_dir}/LICENSE"
codesign --force --sign - --identifier relay-server --timestamp=none "${staging_dir}/relay-server"
codesign --verify --strict "${staging_dir}/relay-server"
touch -t 198001010000 "${staging_dir}/relay-server" "${staging_dir}/LICENSE"

export COPYFILE_DISABLE=1
tar -C "${staging_dir}" -cf - relay-server LICENSE | gzip -n > "${release_tmp}/${archive_name}"
install -m 0644 "${release_tmp}/${archive_name}" "${output_dir}/${archive_name}"

(
    cd "${output_dir}"
    shasum -a 256 "${archive_name}" > "${checksum_name}"
    shasum -a 256 --check "${checksum_name}"
)

archive_entries="$(tar -tzf "${output_dir}/${archive_name}")"
expected_entries=$'relay-server\nLICENSE'
if [[ "${archive_entries}" != "${expected_entries}" ]]; then
    echo "Release archive contains unexpected entries:" >&2
    printf '%s\n' "${archive_entries}" >&2
    exit 1
fi

tar -xzf "${output_dir}/${archive_name}" -C "${verification_dir}"
cmp "${staging_dir}/relay-server" "${verification_dir}/relay-server"
lipo "${verification_dir}/relay-server" -verify_arch arm64
lipo "${verification_dir}/relay-server" -verify_arch x86_64
codesign --verify --strict "${verification_dir}/relay-server"

packaged_version="$(${verification_dir}/relay-server --version)"
if [[ "${packaged_version}" != "${requested_version}" ]]; then
    echo "Packaged binary reports ${packaged_version}; expected ${requested_version}" >&2
    exit 1
fi

printf 'Created %s\n' "${output_dir}/${archive_name}"
printf 'Created %s\n' "${output_dir}/${checksum_name}"

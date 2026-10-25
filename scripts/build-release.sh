#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-.build/universal/release}"
if [[ "${output_dir}" != /* ]]; then
    output_dir="${repo_root}/${output_dir}"
fi

cd "${repo_root}"
./scripts/check-swift-version.sh

# Multi-architecture builds use Xcode's build system, which fails to resolve
# our macro target. Build each architecture with native SwiftPM instead.
binary_dirs=()
for architecture in arm64 x86_64; do
    swift build --build-system native -c release --arch "${architecture}" --product imessage-relay
    swift build --build-system native -c release --arch "${architecture}" --product imessage-relay-app
    binary_dirs+=("$(swift build --build-system native -c release --arch "${architecture}" --show-bin-path)")
done

mkdir -p "${output_dir}"
for product in imessage-relay imessage-relay-app; do
    lipo -create "${binary_dirs[0]}/${product}" "${binary_dirs[1]}/${product}" \
        -output "${output_dir}/${product}"
    lipo "${output_dir}/${product}" -verify_arch arm64 x86_64
done

# SwiftPM resource bundles contain the same data for both architectures.
for bundle in "${binary_dirs[0]}"/*.bundle; do
    [[ -d "${bundle}" ]] || continue
    ditto "${bundle}" "${output_dir}/$(basename "${bundle}")"
done

printf 'Built universal executables in %s\n' "${output_dir}"

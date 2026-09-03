#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_file="${repo_root}/Package.swift"
required_version="$(sed -nE '1s#^// swift-tools-version:([0-9]+)\.([0-9]+).*$#\1 \2#p' "${package_file}")"
installed_version="$(swift --version 2>&1 | sed -nE 's#.*Swift version ([0-9]+)\.([0-9]+).*$#\1 \2#p' | head -n 1)"

if [[ -z "${required_version}" ]]; then
    echo "Could not read swift-tools-version from ${package_file}" >&2
    exit 1
fi
if [[ -z "${installed_version}" ]]; then
    echo "Could not read the installed Swift version" >&2
    swift --version >&2
    exit 1
fi

read -r required_major required_minor <<< "${required_version}"
read -r installed_major installed_minor <<< "${installed_version}"

if (( installed_major != required_major || installed_minor < required_minor )); then
    printf 'Package.swift requires Swift %s.%s or newer within major version %s; found Swift %s.%s\n' \
        "${required_major}" \
        "${required_minor}" \
        "${required_major}" \
        "${installed_major}" \
        "${installed_minor}" >&2
    exit 1
fi

printf 'Swift %s.%s satisfies the supported %s.%s+ range\n' \
    "${installed_major}" \
    "${installed_minor}" \
    "${required_major}" \
    "${required_minor}"

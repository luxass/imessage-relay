#!/usr/bin/env bash

set -euo pipefail

: "${GH_TOKEN:?Set RELEASE_TOKEN to a token with contents:write on this repository}"
: "${GH_REPO:?Set GH_REPO to the release repository}"

tag="${1:?Usage: publish-release.sh TAG [ASSET_DIRECTORY]}"
version="${tag#v}"
asset_dir="${2:-dist}"
archive="imessage-relay-server-${version}-macos-universal.tar.gz"
latest_archive="relay-server-macos-universal.tar.gz"

# Check the complete asset set before creating or modifying a release.
cd "${asset_dir}"
shasum -a 256 --check "${archive}.sha256"
shasum -a 256 --check "${latest_archive}.sha256"
cmp "${archive}" "${latest_archive}"
assets=("${archive}" "${archive}.sha256" "${latest_archive}" "${latest_archive}.sha256")

prerelease=false
latest=true
if [[ "${version%%+*}" == *-* ]]; then
    prerelease=true
    latest=false
fi

if is_draft="$(gh release view "${tag}" --repo "${GH_REPO}" --json isDraft --jq .isDraft)"; then
    if [[ "${is_draft}" != true ]]; then
        echo "Release ${tag} is already published; refusing to replace its assets." >&2
        exit 1
    fi
    gh release upload "${tag}" "${assets[@]}" --repo "${GH_REPO}" --clobber
else
    gh release create "${tag}" "${assets[@]}" \
        --repo "${GH_REPO}" \
        --verify-tag \
        --generate-notes \
        --title "${tag}" \
        --draft \
        --prerelease="${prerelease}"
fi

# Publishing the draft emits the release event only after every asset exists.
gh release edit "${tag}" --repo "${GH_REPO}" \
    --draft=false --prerelease="${prerelease}" --latest="${latest}"

---
title: Development and releases
description: Build, test, lint, and package the Swift relay.
---

Run these commands from the repository root. Building requires Swift 6.1 or a newer Swift 6 release.


Install [`just`](https://github.com/casey/just) and
[SwiftLint](https://github.com/realm/SwiftLint), then run:

```sh
just lint
just test
just build
```

## Create a release archive

Build and verify the universal archive locally:

```sh
just package-release
```

The command writes these files to `dist/`:

- `imessage-relay-server-<version>-macos-universal.tar.gz` and its `.sha256` checksum
- `relay-server-macos-universal.tar.gz` and its `.sha256` checksum (stable download names)

The packaging script checks the binary version, architectures, ad hoc
signature, archive contents, and checksum. Pass a version to require it to
match `packageVersion`:

```sh
just package-release 0.1.0
```

## Release phases

1. Update `packageVersion` in `Sources/relay-server/Application+build.swift`,
   commit it, and push a matching tag such as `v0.1.0`.
2. **Validate:** the Release workflow calls CI to verify the toolchain and
   dependency lockfile, lint, test, and build the tagged commit.
3. **Package:** build and verify the universal binary, archives, and checksums.
   Upload them as workflow artifacts.
4. **Publish:** verify the downloaded checksums, upload all assets to a draft
   GitHub release, then publish it with generated release notes.
5. **Homebrew:** a stable published release calls
   [the shared Homebrew workflow](https://github.com/luxass/shared-workflows/blob/v0.11.2/.github/workflows/reusable-homebrew-tap.yaml)
   to open a PR updating `Formula/imessage-relay-server.rb` in `luxass/homebrew-tap`.

Tags such as `v0.2.0-rc.1` produce GitHub prereleases. They do not become the
latest release or update Homebrew. The tag version must match `packageVersion`.
Run the Release workflow manually to validate and package the selected ref
without creating a release or updating Homebrew.

## Release setup

Create these GitHub Actions environments before pushing a release tag:

| Environment | Used by | Purpose |
| --- | --- | --- |
| `release` | `publish` job | Protects GitHub release publication and stores `RELEASE_TOKEN` |
| `homebrew-tap` | shared Homebrew workflow | Protects formula update PRs |

Add these Actions secrets before pushing a release tag:

| Secret | Purpose |
| --- | --- |
| `RELEASE_TOKEN` in `release` | Fine-grained personal access token with Contents: read and write on `luxass/imessage-relay` |
| `HOMEBREW_TAP_APP_ID` | Client ID of the GitHub App installed on `luxass/homebrew-tap` |
| `HOMEBREW_TAP_APP_PRIVATE_KEY` | Private key for that GitHub App |

The Homebrew App needs Contents and Pull requests read/write permissions on
the tap. The reusable workflow runs in the `homebrew-tap` environment; add at
least one required reviewer if you want approval before it opens a tap PR.
Store the two Homebrew App credentials as repository secrets because the caller
passes them into the reusable workflow.

Publication uses `RELEASE_TOKEN` because releases created with `GITHUB_TOKEN`
[do not trigger another workflow](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).
The separate Homebrew workflow needs the `release: published` event because
the reusable workflow reads the release tag from that event.

### Tap formula format

`Formula/imessage-relay-server.rb` must already exist in `luxass/homebrew-tap`. The
shared workflow expects an explicit `version` field, a URL using
`imessage-relay-server-#{version}-macos-universal.tar.gz`, and this marker on the
`sha256` line:

```ruby
# sha-update-id: imessage-relay-server-macos-universal
```

The archive contains `relay-server` and `LICENSE` at its root. The universal
binary supports Apple silicon and Intel Macs running macOS 14 or newer.

### Recover a failed release

If validation or packaging fails, fix the cause before retrying. If publication
fails while the release is still a draft, rerun the failed job to upload the
assets and publish. Published assets cannot be replaced by this workflow;
release a new version for binary changes.

A failed Homebrew update does not undo a published GitHub release. Once its
configuration is fixed, rerun the failed Homebrew job. If its update branch or
PR was already created, finish that PR before retrying: the shared workflow
does not reconcile existing update branches.

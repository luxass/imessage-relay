---
title: Development and releases
description: Build, test, lint, and package the Swift relay.
---

Run these commands from the repository root. Building requires Swift 6.3 or newer.


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

1. Merge normal changes to `main`. Release Please opens a release PR that updates
   the version and manifest. Merge that PR to create a matching tag such as
   `v0.1.0`.
2. **Package:** build and verify the universal binary, archives, and checksums.
   Upload them as workflow artifacts.
3. **Publish:** verify the downloaded checksums, upload all assets to a draft
   GitHub release, then publish it with generated release notes.
4. **Homebrew:** a stable published release calls
   [the shared Homebrew workflow](https://github.com/luxass/shared-workflows/blob/v0.11.2/.github/workflows/reusable-homebrew-tap.yaml)
   to open a PR updating `Formula/imessage-relay-server.rb` in `luxass/homebrew-tap`.

Tags such as `v0.2.0-rc.1` produce GitHub prereleases. They do not become the
latest release or update Homebrew. The tag version must match `packageVersion`.
Run the Release workflow manually to validate and package the selected ref
without creating a release or updating Homebrew.

Release Please uses the release GitHub App to open release PRs and create tags.
The App token must have Contents and Pull requests write permissions on
`luxass/imessage-relay`. Using an App token instead of the default
`GITHUB_TOKEN` ensures the generated tag triggers the tag-based package workflow.

## Release setup

Create these GitHub Actions environments before merging a release PR:

| Environment | Used by | Purpose |
| --- | --- | --- |
| `release-guard` | `release-guard` job | Approval gate before release packaging |
| `release` | `release-please` and `publish` jobs | Protects release automation and stores the release App credentials |
| `homebrew-tap` | shared Homebrew workflow | Protects formula update PRs |

Add these Actions secrets before merging a release PR:

| Secret | Purpose |
| --- | --- |
| `RELEASE_APP_ID` in `release` | Client ID of the GitHub App used by Release Please and publication |
| `RELEASE_APP_PRIVATE_KEY` in `release` | Private key for that GitHub App |
| `HOMEBREW_TAP_APP_ID` | Client ID of the GitHub App installed on `luxass/homebrew-tap` |
| `HOMEBREW_TAP_APP_PRIVATE_KEY` | Private key for that GitHub App |

The Homebrew App needs Contents and Pull requests read/write permissions on
the tap. The reusable workflow runs in the `homebrew-tap` environment; add at
least one required reviewer if you want approval before it opens a tap PR.
Store the two Homebrew App credentials as repository secrets because the caller
passes them into the reusable workflow.

Publication uses a GitHub App token because releases created with `GITHUB_TOKEN`
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

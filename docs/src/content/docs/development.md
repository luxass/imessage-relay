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

## Run the app locally

`swift run` launches the binary without an app bundle, so activation,
menu-bar behavior, and permission dialogs differ from the shipped app. Build a
dev bundle instead and open it:

```sh
just build
open "dist/dev/iMessage Relay.app"
```

The bundle is ad hoc signed with the Apple Events entitlement. Quit it from its
menu bar item; Ctrl+C in the terminal will not stop an already-open bundle.

Ad hoc re-signing changes the app's identity and voids its macOS permissions.
To keep those permissions across rebuilds, set `CODESIGN_IDENTITY` to an Apple
Development identity when you run `just build`. Otherwise, grant permissions
again after each rebuild.

## Create a release archive

Build and verify the universal archive locally:

```sh
just package-release
```

The command writes these files to `dist/`:

- `imessage-relay-<version>-macos-universal.zip` and its `.sha256` checksum
- `imessage-relay-macos-universal.zip` and its `.sha256` checksum
- `imessage-relay-cli-<version>-macos-universal.tar.gz` and its `.sha256` checksum
- `imessage-relay-cli-macos-universal.tar.gz` and its `.sha256` checksum

Local builds are ad hoc signed and are not submitted to Apple. Release CI uses
Developer ID, hardened runtime, and the Apple Events entitlement. It notarizes
both executables, staples the app, then verifies the signatures, ticket,
architectures, versions, archive contents, and checksums. Pass a version to require it to match
`packageVersion`:

```sh
just package-release 0.1.0
```

## Release phases

1. Merge normal changes to `main`. Release Please opens a release PR that updates
   the version and manifest. Merging that PR creates a matching tag such as
   `v0.1.0` and a draft GitHub release.
2. **Package:** import the protected Developer ID identity, build universal CLI
   and app executables, sign and notarize both, staple the app, then verify and
   upload every archive and checksum as workflow artifacts.
3. **Publish:** verify the downloaded checksums, upload all assets to a draft
   GitHub release, then publish it with generated release notes.
4. **Homebrew:** a stable published release calls
   [the shared Homebrew workflow](https://github.com/luxass/shared-workflows/blob/v0.13.0/.github/workflows/reusable-homebrew-tap.yaml)
   to open one PR updating `Formula/imessage-relay-cli.rb` and
   `Casks/imessage-relay.rb` in `luxass/homebrew-tap`.

Tags such as `v0.2.0-rc.1` produce GitHub prereleases. They do not become the
latest release or update Homebrew. The tag version must match `packageVersion`.
Run the Release workflow manually on an existing `v*` tag to package that tag
without publishing a release or updating Homebrew. The `release-signing`
environment does not permit branch refs.

Release Please uses the release GitHub App to open release PRs, create tags,
and create draft releases. The App token must have Contents and Pull requests
write permissions on `luxass/imessage-relay`. The App token matters here because
a tag created with the default `GITHUB_TOKEN` would not trigger the Release
workflow. That workflow signs the artifacts and publishes the draft only after
all artifacts pass verification.

## Release setup

Create these GitHub Actions environments before merging a release PR:

| Environment | Used by | Purpose |
| --- | --- | --- |
| `release-plz` | `release-please` job | Protects release PR, tag, and draft release creation |
| `release-guard` | `release-guard` job | Requires approval before release packaging starts |
| `release-signing` | `package` job | Stores the Developer ID certificate and notarization key |
| `release` | `publish` job | Protects publication of the signed draft release |
| `homebrew-tap` | shared Homebrew workflow | Protects tap update PRs |

Add these Actions secrets before merging a release PR:

| Secret | Purpose |
| --- | --- |
| `RELEASE_APP_ID` in `release-plz` and `release` | Client ID of the GitHub App used by Release Please and publication |
| `RELEASE_APP_PRIVATE_KEY` in `release-plz` and `release` | Private key for that GitHub App |
| `HOMEBREW_TAP_APP_ID` as a repository secret | Client ID of the GitHub App installed on `luxass/homebrew-tap` |
| `HOMEBREW_TAP_APP_PRIVATE_KEY` as a repository secret | Private key for that GitHub App |

Store the release App credentials in both environments because the
`release-plz` and `release` jobs each generate a token. The Homebrew workflow
passes repository secrets to a reusable workflow. Add these secrets to the
`release-signing` environment:

| Secret | Purpose |
| --- | --- |
| `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application `.p12` |
| `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password protecting the `.p12` |
| `APPLE_CODESIGN_IDENTITY` | Full identity, such as `Developer ID Application: Name (TEAMID)` |
| `APPLE_NOTARY_PRIVATE_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer ID |

Use an App Store Connect key that can submit software for notarization. Keep the
certificate and key in the protected environment, restrict it to release tags,
and do not make it available to pull-request workflows. The `release-guard`
environment provides the human approval before the signing job starts.

Keep the bundle identifier `dev.luxass.imessage-relay` and Developer ID team
stable across releases. macOS uses that signed identity for Keychain access,
Automation, Accessibility, and Full Disk Access. Changing it can make existing
permissions and the stored token unavailable, so any identity change needs an
explicit migration and release note.

The Homebrew App needs Contents and Pull requests read/write permissions on
the tap. The reusable workflow runs in the `homebrew-tap` environment; add at
least one required reviewer if you want approval before it opens a tap PR.
Store the two Homebrew App credentials as repository secrets because the caller
passes them into the reusable workflow.

Publication uses a GitHub App token because releases created with `GITHUB_TOKEN`
[do not trigger another workflow](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).
The separate Homebrew workflow needs the `release: published` event because
the reusable workflow reads the release tag from that event.

### Tap file formats

`Formula/imessage-relay-cli.rb` must already exist in `luxass/homebrew-tap`. The
shared workflow expects an explicit `version` field, a URL using
`imessage-relay-cli-#{version}-macos-universal.tar.gz` from the next release,
and this marker on the `sha256` line:

```ruby
# sha-update-id: imessage-relay-cli-macos-universal
```

The archive contains `imessage-relay`, `LICENSE`, and the SwiftPM resource
bundles at its root. The universal binary supports Apple silicon and Intel
Macs running macOS 14 or newer.

`Casks/imessage-relay.rb` must also exist in the tap. Its `version` line and
`sha256` line marked `sha-update-id: imessage-relay-macos-universal` are updated
from `imessage-relay-<version>-macos-universal.zip`. The ZIP contains
`iMessage Relay.app` with its SwiftPM resource bundles. Review both checksums
in the generated tap PR before merging it.

### Recover a failed release

If validation or packaging fails, fix the cause before retrying. If publication
fails while the release is still a draft, rerun the failed job to upload the
assets and publish. Published assets cannot be replaced by this workflow;
release a new version for binary changes.

A failed Homebrew update does not undo a published GitHub release. Once its
configuration is fixed, rerun the failed Homebrew job. If its update branch or
PR was already created, finish that PR before retrying: the shared workflow
does not reconcile existing update branches.

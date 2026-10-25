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

## Generate the OpenAPI reference

Swift declarations generate the API description. The documentation site renders the committed JSON file.
After an API model, endpoint, or version changes, run:

```sh
just openapi
just test
pnpm check
pnpm build
```

Commit `docs/public/openapi.json` with its source changes. Do not edit the generated file by hand.
Export does not start the relay or require configuration, Messages access, or database files.

Release Please updates `info.version` through its native JSONPath updater.
`just test` fails when the committed file differs from the generated JSON content. It ignores whitespace and object-key order.

Ordinary Codable models use `@OpenAPISchema`. Custom codecs need an explicit schema strategy or a manual provider.
The macro does not replace serialization or business validation.
Read `Sources/HummingbirdOpenAPI/README.md` for model and endpoint examples.

The exporter targets OpenAPI 3.2.1. Client generators have uneven support for 3.2, especially streaming schemas.
Make sure that a client tool supports the features that it consumes.

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

The release build compiles Apple silicon and Intel executables separately with native SwiftPM.
It uses Apple’s `lipo` tool to combine each pair into one universal executable.
This avoids an Xcode build failure when resolving the Swift macro target.

To build only the executables and resource bundles in `.build/universal/release`, run:

```sh
just build-release
```

`just package-release` writes these files to `dist/`:

`imessage-relay-<version>-macos-universal.zip` contains the menu bar app, CLI,
resource bundles, and license. `SHA256SUMS` contains its SHA-256 checksum.

To verify a downloaded release, put both files in the same directory and run:

```sh
shasum -a 256 --check SHA256SUMS
```

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
   upload the combined ZIP and `SHA256SUMS` as workflow artifacts.
3. **Publish:** verify that `SHA256SUMS` matches the ZIP, upload both assets to a draft
   GitHub release, then publish it with generated release notes.
4. **Homebrew:** a published release calls
   [the shared Homebrew workflow](https://github.com/luxass/shared-workflows/blob/v0.13.0/.github/workflows/reusable-homebrew-tap.yaml)
   to open one PR in `luxass/homebrew-tap`. Stable releases update
   `Casks/imessage-relay.rb`. Prereleases update `Casks/imessage-relay@rc.rb`.

Tags such as `v0.5.0-rc.2` produce GitHub prereleases. They update only the RC cask,
not the stable cask, and do not become the latest release. The tag version must match `packageVersion`.
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

Both `Casks/imessage-relay.rb` and `Casks/imessage-relay@rc.rb` must exist in
`luxass/homebrew-tap`. The release workflow selects one file based on the
GitHub release prerelease flag. The shared workflow updates its `version` line
and `sha256` line marked `sha-update-id: imessage-relay-macos-universal` from
`imessage-relay-<version>-macos-universal.zip`. The archive prefix and checksum
marker stay the same for both casks. Review the checksum in the generated PR before merging it.

The casks declare mutual conflicts because they install the same app and CLI.
The tap CI checks syntax and formulae on macOS and Linux. Separate macOS jobs
install each changed relay cask, check the app exists, run CLI `--version` and
`--help`, then uninstall the cask. These checks do not launch the relay or access Messages.

The ZIP contains `iMessage Relay.app`, `imessage-relay`, `LICENSE`, and the CLI
SwiftPM resource bundles at its root. The app also contains its own resource
bundles. Both executables support Apple silicon and Intel Macs running macOS 14 or newer.

The cask installs the app and links the CLI from its staging directory, where
the CLI resource bundles remain beside the executable. The existing 0.4.0 cask
keeps its formula dependency because that published ZIP contains only the app.
Later releases use the combined ZIP without that dependency.

`Formula/imessage-relay-cli.rb` remains available for existing installations,
but is deprecated from November 1, 2026. The release workflow no longer updates it.
Users must uninstall that formula before installing the combined cask to avoid
a conflicting `imessage-relay` command.

### Recover a failed release

If validation or packaging fails, fix the cause before retrying. If publication
fails while the release is still a draft, rerun the failed job to upload the
assets and publish. Published assets cannot be replaced by this workflow;
release a new version for binary changes.

A failed Homebrew update does not undo a published GitHub release. Once its
configuration is fixed, rerun the failed Homebrew job. If its update branch or
PR was already created, finish that PR before retrying: the shared workflow
does not reconcile existing update branches.

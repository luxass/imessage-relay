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

- `relay-server-macos-universal.tar.gz`
- `relay-server-macos-universal.tar.gz.sha256`

The packaging script checks the binary version, architectures, ad hoc
signature, archive contents, and checksum. Pass a version to require it to
match `packageVersion`:

```sh
just package-release 0.1.0
```

Pushing a matching tag, such as `v0.1.0`, runs the same packaging script and
publishes both files to a GitHub release. Run the Release workflow manually to
build the artifacts without publishing a release.

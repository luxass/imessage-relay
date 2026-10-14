# Development tasks. Run `just --list` to see everything.

default: build

# Build the dev .app bundle in dist/dev and ad hoc sign it.
# Run it with: open "dist/dev/iMessage Relay.app"
# (swift run launches the binary without a bundle, so activation and
# menu-bar behavior differ from the shipped app.)
@build output_dir="dist/dev":
    ./scripts/build-dev-app.sh "{{output_dir}}"

# Build a universal release binary (arm64 + x86_64) in .build/release.
@build-release:
    swift build -c release --arch arm64 --arch x86_64

# Build and verify the app and CLI release archives in dist/.
@package-release version="" output_dir="dist":
    ./scripts/package-release.sh "{{version}}" "{{output_dir}}"

# Verify that Swift matches the range declared by Package.swift.
@check-toolchain:
    ./scripts/check-swift-version.sh

# Run the relay test suite.
@test:
    swift test

# Test the independent Hummingbird OpenAPI package.
@test-openapi:
    swift test --package-path Packages/HummingbirdOpenAPI --scratch-path .build/openapi-package

# Generate the prototype OpenAPI document from the live route declarations.
@openapi:
    swift run RelayOpenAPI

# Reject stale generated OpenAPI output.
@check-openapi:
    swift run RelayOpenAPI --check

# Lint with SwiftLint.
@lint:
    swiftlint lint --quiet

# Fix auto-correctable lint violations.
@lint-fix:
    swiftlint --fix --quiet

# Run the server locally.
@run *args:
    swift run imessage-relay {{ args }}

# Remove build artifacts.
@clean:
    swift package clean

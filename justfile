# Development tasks. Run `just --list` to see everything.

default: build

# Build for the host architecture (debug).
@build:
    swift build

# Build a universal release binary (arm64 + x86_64) in .build/release.
@build-release:
    swift build -c release --arch arm64 --arch x86_64

# Run the full test suite.
@test:
    swift test

# Lint with SwiftLint.
@lint:
    swiftlint lint --quiet

# Fix auto-correctable lint violations.
@lint-fix:
    swiftlint --fix --quiet

# Run the server locally.
@run *args:
    swift run relay-server {{ args }}

# Remove build artifacts.
@clean:
    swift package clean

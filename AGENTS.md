# Agent Guide

## Scope and Complexity

- Solve the requested problem directly. Keep unrelated refactors and cleanup out of the change.
- Read the surrounding code and matching tests before editing. Follow local conventions unless the task requires changing them.
- Do not extract single-use helpers preemptively. Inline the logic at the call site unless the helper is reused, hides a genuinely complex boundary, or has a clear independent name that improves the caller.
- Before adding complexity for a speculative or vanishingly unlikely race or security edge case, explain the concrete failure mode, likelihood, and complexity cost to the user and get their buy-in. Do not silently expand scope for theoretical robustness.
- Routine input validation, authorization checks, and fixes for demonstrated vulnerabilities do not require separate approval under that rule.
- Do not add retries, locks, caches, fallback paths, or configuration switches without a concrete requirement or failure scenario.
- Use existing project code, dependencies, and platform APIs first. Get approval before adding, replacing, or upgrading a dependency.

## Project Structure

This project exposes Apple Messages through a local HTTP API on macOS.

- `Sources/RelayCore`: Domain models, application services, storage, and macOS integration.
- `Sources/RelayServer`: Hummingbird routes, authentication, request handling, and server configuration.
- `Sources/RelayCLI`: Command-line entry point.
- `Sources/RelayApp`: Menu bar app, permissions, configuration, and Keychain integration.
- `Sources/AttributedBodyBridge`: Objective-C bridge for decoding attributed message bodies.
- `Tests`: Core, server, and app test targets.
- `docs/src/content/docs`: Astro Starlight documentation pages.
- `scripts` and `Distribution`: Build, packaging, and app distribution files.

Keep dependency direction from `RelayCLI` and `RelayApp` toward `RelayServer` and `RelayCore`. `RelayServer` depends on `RelayCore`, never the reverse.
Keep HTTP concerns in `RelayServer` and app presentation in `RelayApp`. Keep platform-specific implementation details out of domain models.

## Safety and Side Effects

- Keep the Apple Messages database read-only. Store relay-owned durable state separately in `relay.db`.
- Use the existing AppleScript and Accessibility integrations for Messages operations. Do not introduce private frameworks or process injection.
- Preserve bearer authentication, loopback defaults, and explicit permission for remote connections in the app.
- Preserve recipient allowlist checks. An empty allowlist denies all sends, and conversation sends require every participant to be allowlisted.
- Never log bearer tokens or message contents. Use synthetic addresses and messages in tests and examples.
- Do not send real messages or modify live conversations without explicit user approval.
- Do not use the user's Messages database or attachments as test fixtures.
- Keep status and permission checks free of permission prompts. Request permissions only through the intended user action.
- Do not blindly retry a send whose outcome is uncertain. Preserve the existing send identification and recovery behavior.

## Style Guide

### Functions and Helpers

- Keep straightforward logic in one function. Do not split it into a chain of wrappers that only forward arguments.
- If supporting details obscure the main flow, extract a helper that names a meaningful operation.
- Keep private helpers close to the code they support. Prefer placing them below the main operation when it improves reading order.
- Do not create a protocol, generic abstraction, or utility file for hypothetical future callers.
- Use existing protocols at storage and platform boundaries. Add a new boundary only when the task needs one.

```swift
// Prefer a direct expression over a helper that only renames it.
let attachmentURL = directory.appendingPathComponent(filename)

// A helper is useful when its name explains a meaningful operation.
let recipients = try resolveAllowedRecipients(request)
```

### Values and Control Flow

- Prefer `let` over `var`. Use mutable state when the operation requires it, not to avoid a direct expression.
- Prefer `guard` and early returns for invalid input and missing prerequisites. Keep the main flow easy to follow.
- Use `if`, `switch`, loops, and collection methods according to readability. Do not force a functional chain or ternary expression.
- Keep an intermediate value when its name explains intent or avoids a dense expression. Do not optimize for the fewest variables.
- Prefer typed identifiers and domain models over passing raw strings through application code.
- Validate external input at the boundary that owns it. Pass typed values inward instead of repeating the same validation.
- Use the narrowest access level that works. Add `public` only when another module needs the declaration.

### Errors and Concurrency

- Propagate errors with `throws` and `async throws`. Catch errors to translate them, recover, or release resources.
- Do not turn failures into empty results or success responses. Use `try?` only when ignoring failure is intentional.
- Prefer typed errors and the existing API error mapping over ad hoc error strings in routes.
- Preserve cancellation and cleanup behavior when changing asynchronous work.
- Respect actor isolation and `Sendable` requirements. Do not add `@unchecked Sendable` merely to silence the compiler.
- If unchecked concurrency conformance is necessary, document the synchronization that makes it safe.
- Evaluate shared state across `await` boundaries when changing actor methods. Add synchronization for a demonstrated interleaving, not a hypothetical one.

### Storage and API Contracts

- Bind SQL values through the existing SQLite statement APIs. Do not interpolate external input into SQL.
- Keep SQLite work within the existing executor and transaction boundaries.
- Follow the existing row-decoding style. Do not introduce a struct for every query tuple without a concrete benefit.
- Preserve opaque identifier, cursor, pagination, and database identity semantics when changing storage queries.
- Use the existing JSON encoding and decoding configuration. Preserve wire names and error response shapes unless the task changes the contract.
- If an API contract changes, update its contract tests and the matching API documentation in the same change.

### Formatting and Comments

- Follow `.swiftlint.yml` and the surrounding Swift formatting. Do not reformat unrelated code.
- Prefer type inference where the type is clear. Keep annotations that clarify a boundary or resolve ambiguity.
- Explain non-obvious constraints and surprising behavior in comments. Do not narrate assignments or control flow.
- Do not add lint suppressions to avoid fixing new violations. Explain any necessary suppression at its use site.

## Testing

- Test the actual implementation and observable behavior. Do not copy production logic into the test to calculate the expected result.
- Use synthetic SQLite fixtures for storage tests and the existing server test support for HTTP contract tests.
- Use test doubles at Messages, filesystem, and other external boundaries when needed. Do not mock the behavior under test.
- Add a regression test for a bug fix when practical. Cover the relevant failure path as well as the successful path.
- Keep tests independent of live Messages state, network services, permission prompts, and the user's contacts.
- Prefer explicit coordination over arbitrary sleeps in concurrency tests. Bound waits so a failure cannot hang the suite.
- Run focused tests during iteration, for example `swift test --filter RelayCoreTests` from the repository root.

## Checks and Local Development

The relay requires macOS 14 or newer and a Swift toolchain compatible with `Package.swift`.
Run these commands from the repository root for Swift changes:

```sh
just check-toolchain
just lint
just test
just build
```

`just build` creates and ad hoc signs the development app bundle in `dist/dev`.
For app behavior, launch the bundle with `open "dist/dev/iMessage Relay.app"`.
Running the executable without a bundle does not reproduce the shipped app's activation and menu bar behavior.
Do not launch the app against live data unless the task requires it and the user approves the side effects.

For documentation changes, run `pnpm check` and `pnpm build` from the repository root.
Use the pinned pnpm version from `package.json`. Do not use Bun or npm to manage this workspace.

Report which checks ran and which could not run. Do not claim a check passed without running it.

## Branches, Commits, and Releases

- The default branch is `main`. Target authorized pull requests at `main` unless instructed otherwise.
- Use conventional commit messages and PR titles, such as `fix(core): preserve send recovery state`.
- Do not create commits, publish branches, open PRs, or deploy documentation unless the user requests those actions.
- Preserve configured Git signing behavior. If signing fails, stop and ask for help rather than bypassing it.
- Release Please manages releases. Do not add Changesets or manually bump release versions unless the task requires it.
- Do not edit generated build artifacts in `.build`, `dist`, or `docs/dist`.
- Keep dependency lockfile changes limited to approved dependency work.

# Rewrite inventory

This rewrite keeps the Swift package name, the `relay-server` executable, the
`RelayCore` library, Hummingbird, bearer authentication through `RELAY_TOKEN`,
and the safe process-runner behavior from the first implementation. The new API
does not preserve the old routes or their response models.

## Files replaced

The rewrite replaces every Swift file under `Sources/RelayCore`, every
controller and service under `Sources/relay-server`, and both Swift test suites.
Release scripts and workflows stay in place unless a renamed source file forces
a release-script update.

The old implementation has four structural problems that the new design must
not carry forward:

- Public resources use SQLite `ROWID` values instead of provider GUIDs.
- HTTP controllers know storage identifiers and query-shaped models.
- `thread_originator_guid` is exposed as the immediate reply target, although
  the live schema has a separate `reply_to_guid` column.
- Sender availability means only that `/usr/bin/osascript` is executable. It
  does not describe configuration, account selection, Automation permission,
  or operation-specific support.

## Architecture sketches

### Candidate A: two package targets with internal layers

Keep `RelayCore` and `relay-server`. Organize `RelayCore` by domain, storage,
provider, and application folders. Routes depend on application services.
Services depend on storage and sender protocols. SQLite and macOS Automation
implement those protocols at the edge.

This design keeps the deployment artifact and package graph small. Protocols
still enforce the dependency direction, and tests can replace every edge with a
fixture or fake.

### Candidate B: one package target per boundary

Split domain, application, SQLite, macOS sender, and HTTP code into separate
SwiftPM targets. Compile-time imports would enforce every dependency edge.

This design makes invalid imports harder, but it creates five targets for one
local executable. Most target APIs would exist only to cross a SwiftPM boundary.
The added manifest and access-control work would not hide more behavior from a
caller.

## Decision

Use Candidate A. The caller sees three application services:
`ConversationService`, `MessageService`, and `MediaService`. Each service has a
small protocol-backed dependency set. Storage-specific pagination positions and
SQLite row IDs stay inside the SQLite folder. The HTTP target only handles
authentication, request IDs, transport decoding, and status-code mapping.

The real sender remains probe-free on status requests. It reports Automation
permission as unknown. Native reply and reaction writes remain unsupported.
Text and file sends use the public Messages `send` command. Uploaded files stay
outside Messages data, and message requests refer to their opaque media IDs.

Send request state lives in a separate relay-owned SQLite database. An
idempotency key and normalized payload replay the original response after a
restart. Reusing the key for a changed payload returns a conflict.

## Work phases

1. Repository and live-schema inventory.
2. Domain types and JSON contract tests.
3. Synthetic SQLite fixtures and mapping tests.
4. Read services, cursors, and `/v1` read routes.
5. Sender protocol, fake sender, and conservative macOS provider.
6. Safe media storage and upload routes.
7. Send validation, duplicate-request behavior, and error contracts.
8. Documentation and full verification.

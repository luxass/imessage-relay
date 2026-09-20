# imessage-relay

[![GitHub release][release-src]][release-href]
[![GitHub downloads][downloads-src]][downloads-href]
[![CI][ci-src]][ci-href]

Expose Apple Messages as a local `/v1` HTTP API on macOS. Read conversations,
search messages, stream live changes, download attachments, upload media, and
send through one local iMessage account.

Reads go directly to `~/Library/Messages/chat.db`. Sends use Messages.app's
AppleScript interface. The relay does not use private frameworks or process
injection.

## Install

Download the universal binary for Apple silicon and Intel Macs:

```sh
curl -fsSL -o relay-server.tgz \
  https://github.com/luxass/imessage-relay/releases/latest/download/relay-server-macos-universal.tar.gz
tar xzf relay-server.tgz
./relay-server
```

The binary requires macOS 14 or newer. It is ad hoc signed and not notarized.

<details>
<summary>Build from source</summary><br/>

Building requires Swift 6.3 or newer.

```sh
git clone https://github.com/luxass/imessage-relay.git
cd imessage-relay
swift build
.build/debug/relay-server
```

<br/></details>

## Usage

Grant the terminal or service that runs `relay-server` **Full Disk Access** in
**System Settings > Privacy & Security**, then restart that process.

Set a bearer token before you start the relay. To send directly, also set one
local iMessage account ID and an allowlist:

```sh
export RELAY_TOKEN='replace-with-a-long-random-token'
export RELAY_SENDER_ACCOUNT_ID='your-local-imessage-account-id'
export RELAY_ALLOWED_RECIPIENTS='person@example.com,+1 202 555 0123'
./relay-server
```

`RELAY_TOKEN` is required. Add `-H "Authorization: Bearer $RELAY_TOKEN"` to
every request.

From another terminal, check that the relay can read the Messages database:

```sh
curl -s localhost:8080/v1/status \
  -H "Authorization: Bearer $RELAY_TOKEN" | jq
curl -s 'localhost:8080/v1/conversations?limit=3' \
  -H "Authorization: Bearer $RELAY_TOKEN" | jq '.items'
```

Filter by an exact phone number or email address to find its conversations:

```sh
curl -sG localhost:8080/v1/conversations \
  -H "Authorization: Bearer $RELAY_TOKEN" \
  --data-urlencode 'participant=person@example.com' | jq '.items'
```

Use a conversation `id` to read its messages:

```sh
curl -s 'localhost:8080/v1/conversations/CONVERSATION_ID/messages?limit=10' \
  -H "Authorization: Bearer $RELAY_TOKEN" | jq
```

Watch new messages and lifecycle changes without polling:

```sh
curl -N localhost:8080/v1/events \
  -H "Authorization: Bearer $RELAY_TOKEN" \
  -H 'Accept: text/event-stream'
```

Each data event carries an SSE `id`. Reconnect with `Last-Event-ID` to replay
retained events from the current relay process. If the cursor has expired or the
process restarted, the stream sends `stream.reset` and the client must refetch
its REST resources.

From another terminal, send a top-level message. The relay detects whether `to`
is a phone number or an email address:

```sh
curl -s -X POST localhost:8080/v1/messages \
  -H "Authorization: Bearer $RELAY_TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: example-message-1' \
  -d '{"to":"person@example.com","text":"hello"}' | jq
```

The first send can prompt for **Automation > Messages** permission. Status
requests never trigger that prompt. Native inline replies and attachments use
Accessibility and require an existing conversation.

Start or reuse a group with two or more allowlisted participants:

```sh
curl -s -X POST localhost:8080/v1/messages \
  -H "Authorization: Bearer $RELAY_TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: example-group-1' \
  -d '{"participants":["person@example.com","+1 202 555 0123"],"text":"hello everyone"}' | jq
```

Poll the returned `poll_url` until `conversation_id` is present. Use that ID for
later group messages, replies, and attachments.

`GET /v1/status` and `GET /v1/sender` report whether the relay process already
has Accessibility access. This check cannot request permission. Automation
permission remains unknown until a text send is attempted.

> [!TIP]
> See the [API reference](docs/src/content/docs/api.md) for all endpoints, query parameters,
> cursor behavior, and response details.

Opaque conversation and message cursors belong to the database identity returned
by `/v1/status`. Pass a cursor back only to the same route and query.

## Configuration

The server accepts these command-line options:

| Option | Default | Purpose |
| --- | --- | --- |
| `--hostname` | `127.0.0.1` | Listen hostname |
| `--port` | `8080` | Listen port |

| Variable | Default | Purpose |
| --- | --- | --- |
| `RELAY_CHAT_DB_PATH` | `~/Library/Messages/chat.db` | Messages database path |
| `RELAY_ATTACHMENT_DIRECTORY` | `~/Library/Messages/Attachments` | Messages attachment root |
| `RELAY_MEDIA_DIRECTORY` | `~/Library/Application Support/imessage-relay/media` | Uploaded media storage |
| `RELAY_STATE_DB_PATH` | `~/Library/Application Support/imessage-relay/relay.db` | Durable send request state |
| `RELAY_SENDER_ACCOUNT_ID` | Unset | Local iMessage account ID for direct sends |
| `RELAY_ALLOWED_RECIPIENTS` | Unset | Comma-separated send allowlist |
| `RELAY_MAX_MEDIA_BYTES` | 25 MiB | Maximum upload size, capped at 25 MiB |
| `RELAY_TOKEN` | Required | Bearer token for every request |

The server binds to loopback by default. If you expose it on another interface,
terminate TLS in front of the relay. Plain HTTP exposes bearer tokens and message
data in transit.

An empty send allowlist denies every send. A conversation send requires every
participant to be allowlisted. A direct send also requires
`RELAY_SENDER_ACCOUNT_ID`; a conversation send uses that conversation's account
context from `chat.db`.

## Development

Install [`just`](https://github.com/casey/just) and
[SwiftLint](https://github.com/realm/SwiftLint), then run:

```sh
just lint
just test
just build
```

## Documentation site

The Astro Starlight site lives in [`docs/`](docs/README.md). Use pnpm to work on it:

```sh
pnpm install
pnpm dev
```

Cloudflare Workers deployment settings are in the [docs setup guide](docs/README.md#cloudflare-workers).

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

Release Please opens a release PR from conventional commits. Merging it creates
a matching tag, such as `v0.1.0`, which runs validation, packages the binary,
and publishes a GitHub release. Stable releases then use the shared Homebrew
workflow to open a formula update in `luxass/homebrew-tap`. Prereleases, such as
`v0.2.0-rc.1`, do not update Homebrew or the latest release.

Run the Release workflow manually to build artifacts without publishing. See
the [release setup guide](docs/src/content/docs/development.md#release-setup)
for required secrets, the tap formula format, and recovery steps.

## 📄 License

Published under [MIT License](./LICENSE).

<!-- Badges -->

[release-src]: https://img.shields.io/github/v/release/luxass/imessage-relay?style=flat&colorA=18181B&colorB=4169E1
[release-href]: https://github.com/luxass/imessage-relay/releases/latest
[downloads-src]: https://img.shields.io/github/downloads/luxass/imessage-relay/total?style=flat&colorA=18181B&colorB=4169E1
[downloads-href]: https://github.com/luxass/imessage-relay/releases
[ci-src]: https://img.shields.io/github/actions/workflow/status/luxass/imessage-relay/ci.yml?branch=main&style=flat&label=ci&colorA=18181B&colorB=4169E1
[ci-href]: https://github.com/luxass/imessage-relay/actions/workflows/ci.yml

# imessage-relay

[![GitHub release][release-src]][release-href]
[![GitHub downloads][downloads-src]][downloads-href]
[![CI][ci-src]][ci-href]

Expose Apple Messages as a local HTTP API on macOS. Read chat history, search
messages within a chat, and send texts from one native Swift binary.

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

Building requires Swift 6.1 or a newer Swift 6 release.

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

Start the relay:

```sh
./relay-server
```

If you set `RELAY_TOKEN`, add `-H 'Authorization: Bearer <token>'` to every
request.

From another terminal, check that the relay can read the Messages database:

```sh
curl -s localhost:8080/status | jq
curl -s 'localhost:8080/chats?limit=3' | jq '.items'
```

Use a chat `id` to read its messages:

```sh
curl -s 'localhost:8080/chats/42/messages?limit=10' | jq
```

Sending is disabled until you set `RELAY_ALLOWED_RECIPIENTS`. The first send
also prompts for **Automation > Messages** permission.

```sh
RELAY_ALLOWED_RECIPIENTS="+12025550123,mom@icloud.com" ./relay-server
```

From another terminal, send a message:

```sh
curl -s -X POST localhost:8080/send \
  -H 'Content-Type: application/json' \
  -d '{"to":"+12025550123","text":"hello"}'
```

> [!TIP]
> See the [API reference](docs/src/content/docs/api.md) for all endpoints, query parameters,
> cursor behavior, and response details.

Opaque chat and message-history cursors belong to the database fingerprint returned by
`/status`. The current `v3:` fingerprint identifies the `chat.db` filesystem
instance and remains stable across normal message inserts. Clients upgrading
from an older fingerprint format must reset stored cursors once.

## Configuration

The server accepts these command-line options:

| Option | Default | Purpose |
| --- | --- | --- |
| `--hostname` | `127.0.0.1` | Listen hostname |
| `--port` | `8080` | Listen port |

| Variable | Default | Purpose |
| --- | --- | --- |
| `RELAY_CHAT_DB_PATH` | `~/Library/Messages/chat.db` | Messages database path |
| `RELAY_ALLOWED_RECIPIENTS` | Unset | Comma-separated send allowlist |
| `RELAY_TOKEN` | Unset | Bearer token required on every request |

The server binds to loopback by default. You can pass `--hostname 0.0.0.0` or
another hostname for remote access. Set `RELAY_TOKEN` whenever untrusted clients
can reach the relay, and use TLS termination because plain HTTP exposes bearer
tokens and message data in transit.

An empty send allowlist denies every send.

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

Pushing a matching tag, such as `v0.1.0`, runs validation, packages the binary,
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

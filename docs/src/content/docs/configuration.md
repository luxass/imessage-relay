---
title: Configuration
description: Configure the listen address, bearer token, database path, and send allowlist.
---

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

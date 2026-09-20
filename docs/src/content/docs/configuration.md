---
title: Configuration
description: Configure the local database, sender, media, authentication, and allowlist.
---

The server accepts these command-line options:

| Option | Default | Purpose |
| --- | --- | --- |
| `--hostname` | `127.0.0.1` | Listen hostname |
| `--port` | `8080` | Listen port |

| Variable | Default | Purpose |
| --- | --- | --- |
| `RELAY_CHAT_DB_PATH` | `~/Library/Messages/chat.db` | Messages database path |
| `RELAY_ATTACHMENT_DIRECTORY` | `~/Library/Messages/Attachments` | Messages attachment root |
| `RELAY_MEDIA_DIRECTORY` | `~/Library/Application Support/imessage-relay/media` | Relay-owned uploaded media |
| `RELAY_STATE_DB_PATH` | `~/Library/Application Support/imessage-relay/relay.db` | Durable send request state |
| `RELAY_SENDER_ACCOUNT_ID` | Unset | Local iMessage account ID for direct sends |
| `RELAY_PHONE_REGION` | System region | Region for parsing national phone numbers |
| `RELAY_ALLOWED_RECIPIENTS` | Unset | Comma-separated send allowlist |
| `RELAY_MAX_MEDIA_BYTES` | 25 MiB | Maximum upload size, capped at 25 MiB |
| `RELAY_TOKEN` | Required | Bearer token required on every request |

The server does not start without `RELAY_TOKEN`. It binds to loopback by default.
If you expose another interface, terminate TLS in front of the relay. Plain HTTP
exposes bearer tokens and message data in transit.

An empty send allowlist denies every send. Phone comparisons ignore formatting.
Email comparisons ignore case. A group conversation is allowed only when every
participant matches the allowlist. A recipient may also be a unique Contacts
name. The resolved phone number or email address must still be allowlisted.
Contacts are loaded only for name-based sends, so slow or denied Contacts access
does not delay status checks.

`RELAY_SENDER_ACCOUNT_ID` selects your local iMessage account, not the recipient.
A direct `to` send requires it. A `conversation_id` send uses the account stored
on that conversation in `chat.db` and fails when the account is missing.

The relay writes only uploaded media and request state to its own directories.
It opens `RELAY_CHAT_DB_PATH` read-only and never writes to Messages data.

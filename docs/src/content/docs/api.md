---
title: API reference
description: HTTP endpoints, query parameters, response details, and send error handling.
---

`relay-server` exposes an HTTP API at `http://127.0.0.1:8080` by default. Pass
`--port <port>` or `--hostname <hostname>` to change the listen address.

## Authentication

If `RELAY_TOKEN` is set, every request must include the token:

```http
Authorization: Bearer <token>
```

The API returns `401` when the header is missing or invalid.

For remote access, set `RELAY_TOKEN` and terminate TLS in front of the relay.
Plain HTTP exposes bearer tokens and message data in transit. The relay permits
non-loopback hostnames because network exposure is an operator deployment
decision.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/status` | Report the server, database, and sender status. |
| `GET` | `/chats` | Page through chats. |
| `GET` | `/chats/:id` | Read one chat. |
| `GET` | `/chats/:id/messages` | Read messages from one chat. |
| `POST` | `/send` | Send a text message. |
| `GET` | `/attachments/:rowid` | Download an attachment. |

## Status

```http
GET /status
```

Returns the server version, database readiness and fingerprint, and sender
status. `sender.capabilities` lists supported operations. `sender.available`
reports whether `/usr/bin/osascript` exists and is executable.
`sender.automation_permission` is `unknown` because this endpoint never launches
the sender or triggers an Automation permission prompt.

Opaque chat and message-history cursors belong to one database fingerprint. Discard
stored cursors if the fingerprint changes. Fingerprints beginning with `v3:`
identify the `chat.db` filesystem instance and remain stable when messages are
inserted. Replacing the file or resetting its durable identity changes the
fingerprint.

Clients upgrading from the older content-derived fingerprint format must reset
their stored cursor once. After that transition, routine inserts do not require
another reset. Do not assume that restoring a backup preserves the fingerprint.
Database filesystem paths and raw database errors are not included.

## Chats

```http
GET /chats?limit=20&unread_only=false&cursor=
```

| Parameter | Default | Description |
| --- | --- | --- |
| `limit` | `20` | Maximum number of chats to return. |
| `unread_only` | `false` | Return only chats with unread messages. |
| `cursor` | Unset | Opaque cursor returned by the previous page. |

```json
{"items":[],"has_more":false}
```

The response includes `items`, `has_more`, and `next_cursor` when another page
exists. Chats with messages sort by last-message date descending, then chat row
ID descending. Chats without messages follow, ordered by chat row ID
descending. The server clamps `limit` to `1...200`.

Each chat contains `id`, `guid`, `identifier`, `name`, `service`, `is_group`,
`participants`, and `unread_count`. The server omits `display_name` when it is
empty and omits `last_message_at` when the chat has no messages.

### Chat detail

```http
GET /chats/:id
```

Returns the chat object for the positive chat row ID. The API returns `404` if
the chat does not exist.

## Chat messages

```http
GET /chats/:id/messages?limit=50&cursor=&attachments=false&include_reactions=false&q=&match=
```

`:id` is the positive chat row ID returned by `/chats`.
The API returns `404` if the chat does not exist.

| Parameter | Default | Description |
| --- | --- | --- |
| `limit` | `50` | Maximum number of messages to return. |
| `cursor` | Unset | Opaque cursor returned by the previous page. |
| `attachments` | `false` | Include attachment metadata. |
| `include_reactions` | `false` | Include reactions as message rows. |
| `q` | Unset | Filter this chat's plain-text message content. |
| `match` | Unset | Use `exact` for a case-insensitive exact match. Otherwise, `q` is a contains match. |

The response includes `items`, `has_more`, and `next_cursor` when another page
exists. Each page is ordered chronologically. Following `next_cursor` traverses
older messages. The server clamps `limit` to `1...500`.

Each message contains `id`, `chat_id`, `guid`, `text`, `sender`, `is_from_me`,
`created_at`, and `attachments`. The `attachments` field is an empty array
unless `attachments=true`. The server omits delivery, reply, and reaction
fields when they have no value.

```json
{"items":[],"has_more":false}
```

Page cursors are opaque, URL-safe, and versioned. Pass `next_cursor` unchanged
to the same endpoint. Do not parse it or construct one from dates or row IDs. A
chat cursor is bound to `unread_only`. A chat-message cursor is bound to the
chat ID, attachment mode, reaction mode, exact `q` text, and `match` mode without
storing the search text in the cursor.
All cursor types are bound to the database fingerprint. The API returns `400` if a
cursor is malformed, belongs to another route or query, uses an unsupported
version, or refers to a replaced database. Start again without `cursor` after
that response. Inserts made during traversal can change page boundaries; a
single traversal assumes stable database contents.

## Send a message

```http
POST /send
Content-Type: application/json

{"to":"+12025550123","text":"hello"}
```

Send to either an address or an existing chat:

```json
{"to":"+12025550123","text":"hello"}
```

```json
{"chat_id":42,"text":"hello"}
```

`RELAY_ALLOWED_RECIPIENTS` must match the direct address or every participant
in an existing chat. Group sends are denied when any participant is not on the
allowlist. Matching is case-insensitive and ignores phone-number formatting.

| Status | Meaning | Retry guidance |
| --- | --- | --- |
| `403` | The allowlist denies the recipient. | Change the allowlist or destination. |
| `501` | The sender implementation does not support the request. | Change the request. |
| `502` | Dispatch failed before Messages.app sent anything. | Safe to retry. |
| `500` | The outcome is uncertain. | Do not retry automatically. |

Sending supports text only. The relay cannot send files or reactions through
the public Messages.app automation interface. The request accepts only
`chat_id`, `to`, and `text`; every other field is rejected with `400`. `text`
must contain at least one non-whitespace character.

## Download an attachment

```http
GET /attachments/:rowid
```

`:rowid` is the positive attachment row ID from message attachment metadata.
The response body contains the attachment bytes. The server uses the stored MIME
type as its `Content-Type`, or `application/octet-stream` when the stored value
is empty. The attachment row must link to an existing message. The backing file
must be inside the `Attachments` directory beside the configured `chat.db`. The
API returns `404` when any of these conditions fail.

Attachment metadata contains `id`, `transfer_name`, `mime_type`, `uti`,
`total_bytes`, `is_sticker`, and `missing`. Local `filename` and
`original_path` values are not included.

## Message details

Reactions appear as message rows when `include_reactions=true`. These rows
contain `is_reaction`, `reacted_to_guid`, `reaction_type`, and
`is_reaction_add`. `reaction_type` is `love`, `like`, `dislike`, `laugh`,
`emphasis`, `question`, or `custom`.

Outgoing messages can contain `delivered_at` and `read_at`. The API returns
`read_at` only when the recipient shares read receipts over iMessage.

Some system messages, such as location-sharing notices, store content only in
a binary blob. The relay does not decode that blob, so their `text` field is
empty.

## Compatibility

The Messages database has a private schema that changes between macOS
releases. The relay is tested on macOS 27. Other versions may require changes.

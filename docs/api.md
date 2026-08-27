# API reference

`relay-server` exposes an HTTP API at `http://127.0.0.1:8080` by default. Pass
`--port <port>` or `--hostname <hostname>` to change the listen address.

## Authentication

If `RELAY_TOKEN` is set, every request must include the token:

```http
Authorization: Bearer <token>
```

The API returns `401` when the header is missing or invalid.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/status` | Report the server, database, and sender status. |
| `GET` | `/chats` | List recent chats. |
| `GET` | `/chats/:id/messages` | Read messages from one chat. |
| `GET` | `/messages/after` | Poll for messages after a row ID. |
| `GET` | `/messages/search` | Search plain-text messages. |
| `POST` | `/send` | Send a text message. |
| `GET` | `/attachments/:rowid` | Download an attachment. |

## Status

```http
GET /status
```

Returns the server version, database readiness and fingerprint, and sender
capabilities. A row ID cursor belongs to one database fingerprint. Discard
stored cursors if the fingerprint changes.

## Chats

```http
GET /chats?limit=20&unread_only=false
```

| Parameter | Default | Description |
| --- | --- | --- |
| `limit` | `20` | Maximum number of chats to return. |
| `unread_only` | `false` | Return only chats with unread messages. |

## Chat messages

```http
GET /chats/:id/messages?limit=50&before=&attachments=false&include_reactions=false
```

`:id` is the positive chat row ID returned by `/chats`.

| Parameter | Default | Description |
| --- | --- | --- |
| `limit` | `50` | Maximum number of messages to return. |
| `before` | Unset | Return messages before this row ID. |
| `attachments` | `false` | Include attachment metadata. |
| `include_reactions` | `false` | Include reactions as message rows. |

## Poll for messages

```http
GET /messages/after?since_rowid=42&chat_id=&limit=100&attachments=false&include_reactions=false
```

`since_rowid` is required and must be a non-negative integer.

| Parameter | Default | Description |
| --- | --- | --- |
| `since_rowid` | Required | Return messages after this row ID. |
| `chat_id` | Unset | Restrict results to one chat. |
| `limit` | `100` | Maximum number of messages to return. |
| `attachments` | `false` | Include attachment metadata. |
| `include_reactions` | `false` | Include reactions as message rows. |

The response contains `messages`, `next_rowid`, and `has_more`. Pass
`next_rowid` as `since_rowid` on the next request. If `has_more` is `true`,
request the next page immediately.

## Search messages

```http
GET /messages/search?q=hello&match=contains&limit=50
```

| Parameter | Default | Description |
| --- | --- | --- |
| `q` | Required | Non-empty search text. |
| `match` | `contains` | Use `exact` for an exact match. Any other value uses a contains match. |
| `limit` | `50` | Maximum number of messages to return. |

Search covers only content in the database's plain-text `text` column.

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
| `501` | The sender does not support the request. | Change the request. |
| `502` | Dispatch failed before Messages.app sent anything. | Safe to retry. |
| `500` | The outcome is uncertain. | Do not retry automatically. |

Sending supports text only. The relay cannot send files or reactions through
the public Messages.app automation interface.

## Download an attachment

```http
GET /attachments/:rowid
```

`:rowid` is the positive attachment row ID from message attachment metadata.
The response body contains the attachment bytes and uses the stored MIME type
as its `Content-Type`. The API returns `404` if either the attachment record or
its backing file is missing.

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

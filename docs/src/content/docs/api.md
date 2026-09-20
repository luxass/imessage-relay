---
title: API reference
description: The /v1 endpoints, request models, status values, and error contract.
---

`relay-server` listens on `http://127.0.0.1:8080` by default. Every endpoint uses
the `/v1` prefix.

## Authentication

Every request requires the bearer token from `RELAY_TOKEN`:

```http
Authorization: Bearer <token>
```

A missing or invalid token returns `401 invalid_authentication`.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/status` | Read service, database, and sender status. |
| `GET` | `/v1/sender` | Read sender identity and capabilities. |
| `GET` | `/v1/conversations` | Page through conversations. |
| `GET` | `/v1/conversations/{conversation_id}` | Read one conversation. |
| `GET` | `/v1/conversations/{conversation_id}/messages` | Page through messages. |
| `PUT` | `/v1/conversations/{conversation_id}/read` | Mark a conversation as read. |
| `PUT` | `/v1/conversations/{conversation_id}/typing` | Start or refresh a typing lease. |
| `DELETE` | `/v1/conversations/{conversation_id}/typing` | Stop a typing lease. |
| `GET` | `/v1/messages/{message_id}` | Read one message. |
| `PUT` | `/v1/messages/{message_id}/reaction` | Set the local sender's reaction. |
| `DELETE` | `/v1/messages/{message_id}/reaction` | Clear the local sender's reaction. |
| `POST` | `/v1/messages` | Submit a message send. |
| `GET` | `/v1/requests/{request_id}` | Read durable send request status. |
| `POST` | `/v1/media` | Upload media. |
| `GET` | `/v1/media/{media_id}` | Read metadata or download media. |
| `GET` | `/v1/events` | Stream live message changes with server-sent events. |

Public conversation IDs, message IDs, and Messages-owned media IDs are provider
GUIDs. They are not SQLite row IDs.

## Read service status

```http
GET /v1/status
```

The response contains service health, database readiness and identity, and the
sender status. The route does not run AppleScript or trigger an Automation
permission prompt.

`GET /v1/sender` returns the same sender object. Each capability is `available`,
`unavailable`, `permission_unknown`, or `unsupported`. The macOS sender reports
text as `permission_unknown` when an account is configured because a status
request does not probe Messages. Media, native replies, and reaction writes are
`available` only when the relay process has Accessibility permission.
`group_creation` follows text because it uses AppleScript and the configured
account. Its permission remains `permission_unknown` until a send attempts the
operation.

The sender also reports permissions separately:

```json
{
  "permissions": {
    "automation": "unknown",
    "accessibility": "not_granted"
  }
}
```

Accessibility is `granted` or `not_granted`. The status routes use the
non-prompting macOS trust check, so they never open System Settings or request
access. Automation remains `unknown` because probing it would contact Messages.
Media, native replies, and reaction writes report `unavailable` until
Accessibility permission is granted.

## List conversations

```http
GET /v1/conversations?limit=20&unread_only=false&participant=person@example.com&cursor=
```

| Parameter | Default | Description |
| --- | --- | --- |
| `limit` | `20` | Page size from 1 through 200. |
| `cursor` | Unset | Opaque cursor from the prior page. |
| `unread_only` | `false` | Return only conversations with unread messages. Accepts `true`, `false`, `1`, or `0`. |
| `participant` | Unset | Return conversations containing this exact normalized phone number or email address. |

The relay detects the `participant` handle type. Phone comparison ignores
supported formatting characters, and email comparison is case-insensitive. The
response can contain both direct and group conversations. No match returns an
empty page.

Conversations sort by newest message first with a stable internal tie-breaker.

The response uses the common page shape:

```json
{
  "items": [],
  "next_cursor": null,
  "has_more": false
}
```

Pass `next_cursor` unchanged to the same route and query. A cursor is opaque,
versioned, route-specific, query-bound, and database-bound.

## Mark a conversation as read

```http
PUT /v1/conversations/{conversation_id}/read
```

The request has no body. It returns `applied` only after Messages performs the
operation and `chat.db` reports zero unread messages. If the conversation is
already read, it returns `unchanged` without invoking Accessibility:

```json
{
  "request_id": "9bf177d3-cabb-41fe-bf44-e073d1a3113c",
  "conversation_id": "any;-;person@example.com",
  "status": "applied"
}
```

The relay opens the conversation through a provider message GUID and verifies
that Messages selected that message before invoking the mark-read shortcut. It
never writes to `chat.db`. Messages may send a read receipt according to the
Mac's Messages settings; this endpoint guarantees the local conversation state,
not remote receipt delivery.

A `502 read_result_unknown` response means the native action may have occurred,
but the database did not confirm it. Refetch the conversation before retrying.
The endpoint returns `503 messages_unavailable` when Accessibility permission
is unavailable.

## Send a typing indicator

Start or refresh typing for an existing conversation:

```http
PUT /v1/conversations/{conversation_id}/typing
```

The request has no body. A successful response describes a five-second local
lease:

```json
{
  "request_id": "9bf177d3-cabb-41fe-bf44-e073d1a3113c",
  "conversation_id": "any;-;person@example.com",
  "status": "active",
  "expires_at": "2026-09-17T18:30:05.000Z"
}
```

Refresh the lease with another `PUT` approximately every three seconds. Stop it
explicitly with:

```http
DELETE /v1/conversations/{conversation_id}/typing
```

The relay automatically stops an expired lease. It also stops active typing
before sending a message, changing a reaction, marking a conversation read, or
shutting down normally. There is only one relay-managed typing lease because
the Mac has one Messages UI. Starting one conversation stops the previous one.

The Accessibility provider opens an exact provider message GUID, verifies the
selection, and places one space in the normal conversation composer. It never
presses Return. It clears only that one-space value when stopping. Any other
draft content returns `409 typing_conflict` without modifying the draft.

`active` confirms only that the local composer contains the relay's typing
marker. It cannot prove that a remote device displayed the indicator. A
`502 typing_result_unknown` response means the local result could not be
determined, and `503 messages_unavailable` means Accessibility is unavailable.
Group typing requires macOS Tahoe or later.

Leases are in memory and are not restored after a process crash. A normal
shutdown clears the marker. Native timing still requires manual verification on
the target Mac before the five-second duration is treated as final.

## Read a conversation

```http
GET /v1/conversations/{conversation_id}
```

The endpoint returns `404 unknown_conversation` when no conversation has that
provider GUID.

## List messages

```http
GET /v1/conversations/{conversation_id}/messages?limit=50&include_attachments=true&q=hello&search_mode=contains
```

| Parameter | Default | Description |
| --- | --- | --- |
| `limit` | `50` | Page size from 1 through 200. |
| `cursor` | Unset | Opaque cursor from the prior page. |
| `include_attachments` | `false` | Include attachment metadata. |
| `q` | Unset | Search decoded message text within this conversation. |
| `search_mode` | `contains` | Case-insensitive `contains` or `exact` matching. |

Reaction event rows do not appear as ordinary messages. Reactions are always
nested under their target messages. A message thread object
keeps two relationships separate:

```json
{
  "thread": {
    "reply_to_message_id": null,
    "thread_originator_message_id": "root-message-guid"
  }
}
```

`thread_originator_message_id` identifies the first message in the native inline
thread. The thread object is absent for a top-level message.

On the tested macOS schema, `reply_to_guid` does not reliably identify the
immediate parent. Messages uses it to chain ordinary top-level bubbles and can
also point a nested reply at a preceding bubble from an unrelated thread. The
relay therefore reports `reply_to_message_id` as null instead of exposing that
column as a false parent relationship. A send request still accepts the exact
message to target in `reply_to.message_id`.

### Message parts

The `parts` array preserves provider order for text and attachments when the
Messages attributed body contains part metadata:

```json
{
  "text": "Caption",
  "parts": [
    {
      "index": 0,
      "type": "attachment",
      "attachment": null
    },
    {
      "index": 1,
      "type": "text",
      "text": "Caption"
    }
  ],
  "attachments": []
}
```

With `include_attachments=false`, attachment parts remain in the ordered array,
but their `attachment` value is null. With `include_attachments=true`, that
value contains the same media metadata that appears in `attachments`.

`parts: null` means that the database does not provide enough evidence to
reconstruct part order. An `unknown` part preserves a known index whose content
type cannot be decoded. The API does not use attachment table row order as
message-part order.

When a reaction target uses the provider form `p:<index>/<message-guid>`, the
reaction contains `target_part_index`. Other reaction target forms return null
for that field.

## Read one message

```http
GET /v1/messages/{message_id}
```

The endpoint returns `404 unknown_message` when no message has that provider
GUID.

## Set or clear a reaction

Set the configured local sender's reaction on a message:

```http
PUT /v1/messages/{message_id}/reaction
Content-Type: application/json

{
  "reaction": "love"
}
```

The supported values are `love`, `like`, `dislike`, `laugh`, `emphasis`, and
`question`. Sending the same `PUT` again is safe. The response status is
`unchanged` when the requested reaction is already present.

Clear the configured local sender's current reaction:

```http
DELETE /v1/messages/{message_id}/reaction
```

Deleting an absent reaction also returns `unchanged`. Both routes operate on
the provider's default message part. They do not accept a part index.

A changed reaction returns the resulting local reaction state:

```json
{
  "request_id": "9bf177d3-cabb-41fe-bf44-e073d1a3113c",
  "status": "applied",
  "message_id": "message-provider-guid",
  "reaction": "love"
}
```

After a successful `DELETE`, `reaction` is null.

Reaction writes use Accessibility and the same serialized operation queue as
replies and media. The API returns success only after it observes the expected
outgoing reaction row. A `502 reaction_result_unknown` response means Messages
may have changed the reaction, but the database did not confirm it. Refetch the
message before retrying.

## Send a message

Send to one phone number or email address. The relay detects the handle type and
normalizes it for matching:

```http
POST /v1/messages
Content-Type: application/json
Idempotency-Key: client-operation-123

{
  "to": "+1 500 555 0006",
  "text": "Hello"
}
```

Send through an existing conversation's local iMessage account context:

```json
{
  "conversation_id": "chat-provider-guid",
  "text": "Hello"
}
```

Start or reuse a group by supplying at least two other participants:

```json
{
  "participants": [
    "person@example.com",
    "+1 500 555 0006"
  ],
  "text": "Hello everyone"
}
```

Provide exactly one of `to`, `participants`, and `conversation_id`. A direct or
new-group send requires `RELAY_SENDER_ACCOUNT_ID`. A conversation send uses the
account ID stored on the conversation. Every destination participant must match
`RELAY_ALLOWED_RECIPIENTS`.

The relay normalizes every group participant and rejects duplicates. It reuses
one conversation whose normalized participant set matches exactly. If several
conversations match, the request returns `409 ambiguous_conversation`; use a
specific `conversation_id`. If none match, Messages creates the group through
the configured account.

A `participants` request requires text and does not accept `media` or
`reply_to`. Use the returned `conversation_id` for later attachment and reply
sends. Participant order does not affect idempotency.

Omit `reply_to` for a normal top-level message. The request model accepts this
native-reply shape for sender providers that support it:

```json
{
  "conversation_id": "chat-provider-guid",
  "text": "Reply text",
  "reply_to": {
    "message_id": "parent-message-guid"
  }
}
```

The macOS sender uses Accessibility for `reply_to`. The relay returns
`501 unsupported_capability` if Accessibility permission is unavailable. Reply
sends require an existing conversation.

### Uploaded media

`POST /v1/media` stores files outside the Messages database. The macOS sender
uses Accessibility to send uploaded files through an existing conversation.

The request model reserves this shape for a sender provider that supports media:

```json
{
  "conversation_id": "chat-provider-guid",
  "text": "Here is the file",
  "media": [
    { "media_id": "upload_7ee45d6e-3270-480b-97c1-aabe5763cf7b" }
  ]
}
```

A message request cannot contain an arbitrary local path. It can only refer to
relay-owned uploaded media.

### Retry a send safely

`Idempotency-Key` is optional and accepts 1 through 128 visible characters. Use
one unique key for one logical send:

- The same key and the same normalized request return the stored response. The
  relay does not dispatch again.
- The same key with a changed destination, text, media list, or reply target
  returns `409 duplicate_request`.
- Request state persists in `RELAY_STATE_DB_PATH`. The database stores a hash of
  the key, not the raw key.

Before each native send, the relay records the newest Messages row ID. After the
send, it waits up to three seconds for matching outgoing rows. One request can
produce separate text and attachment messages. The response always includes a
durable poll URL:

```json
{
  "request_id": "f066b48a-7a7b-4073-9cdd-eb65b49bad9a",
  "status": "accepted",
  "correlation_status": "pending",
  "conversation_id": null,
  "messages": [],
  "media": [],
  "poll_url": "/v1/requests/f066b48a-7a7b-4073-9cdd-eb65b49bad9a"
}
```

`correlation_status` has these values:

| Value | Meaning |
| --- | --- |
| `pending` | The relay has not identified a provider result. Poll the request. |
| `partial` | The relay has identified some requested content. Poll the request. |
| `complete` | The relay has identified the text and every requested media item. |
| `ambiguous` | The relay found conflicting evidence and did not guess. |

When correlation completes, `messages` contains every resulting Messages GUID
and its lifecycle status. The top-level `status` summarizes those messages. It
reports `failed` if any identified message failed. It reports `read`,
`delivered`, or `sent` only when every identified message reached at least that
state.

`conversation_id` is present as soon as the relay knows the stable provider
conversation. A new group normally returns null in the accepted response and
the provider ID in a later `GET /v1/requests/{request_id}` response.

Each `media` item connects one uploaded media ID to the resulting Messages
attachment and message:

```json
{
  "request_id": "f066b48a-7a7b-4073-9cdd-eb65b49bad9a",
  "status": "sent",
  "correlation_status": "complete",
  "messages": [
    {
      "message_id": "text-message-guid",
      "status": "delivered"
    },
    {
      "message_id": "attachment-message-guid",
      "status": "sent"
    }
  ],
  "media": [
    {
      "requested_media_id": "upload_7ee45d6e-3270-480b-97c1-aabe5763cf7b",
      "media_id": "messages-attachment-guid",
      "message_id": "attachment-message-guid"
    }
  ],
  "poll_url": "/v1/requests/f066b48a-7a7b-4073-9cdd-eb65b49bad9a"
}
```

For a partial result, an unmatched media item has null `media_id` and
`message_id` fields. `accepted` means the native sender completed but the relay
has not identified every provider result.

`GET /v1/requests/{request_id}` retries provider-message identification when
`correlation_status` is `pending` or `partial`. After identification, it reads
every identified message again and updates the lifecycle statuses.

`result_unknown` means the relay found ambiguous rows, observed a reply mismatch,
or could not inspect the provider result. Do not retry that operation with a new
idempotency key.

## Upload and download media

Upload the raw request body:

```http
POST /v1/media
Content-Type: image/jpeg
X-Filename: photo.jpg

<file bytes>
```

The maximum size defaults to 25 MiB and cannot exceed 25 MiB. Filenames cannot
contain path separators, control characters, quotes, or semicolons. Allowed MIME
types include image, video, audio, text, PDF, and octet-stream.

`GET /v1/media/{media_id}` returns metadata. Add `?download=true` to receive the
bytes. The endpoint never returns a stored filesystem path.

## Stream live events

Open one authenticated server-sent event stream:

```sh
curl -N http://127.0.0.1:8080/v1/events \
  -H "Authorization: Bearer $RELAY_TOKEN" \
  -H 'Accept: text/event-stream'
```

The observer starts when the first client connects and remains active until the
relay shuts down, allowing it to retain events while every client is
disconnected. It uses a dedicated read-only SQLite connection. The endpoint
does not send messages or change the Messages database.

Each data event carries an SSE `id`. The relay retains a bounded history for the
current process. Reconnect with that value in `Last-Event-ID` to replay later
events in order. Browser `EventSource` clients send this header automatically.

Replay does not survive a relay restart and old cursors expire when they leave
the bounded history. In either case the server sends `stream.reset` with
`replay_unavailable`; reconnect without the cursor and refetch the required REST
resources.

The first frame identifies the database and states the replay policy:

```text
retry: 3000

event: stream.ready
data: {"database_identity":"v1:...","replay_supported":true}
```

Events contain stable resource IDs instead of full message objects. Fetch
`GET /v1/messages/{message_id}` to read the current resource.

| Event | Meaning |
| --- | --- |
| `message.created` | A new ordinary message appeared. Reaction rows are excluded. |
| `message.updated` | `delivery_state`, `read_state`, or both changed. |
| `reaction.added` | A reaction event row appeared for a message. |
| `reaction.removed` | A reaction-removal event row appeared for a message. |
| `media.available` | A Messages attachment became safe to download through the media endpoint. |
| `stream.reset` | The client must reconnect and refetch REST resources. |

For example:

```text
id: 4f74f9cf-73fb-49d8-a596-3c724a5ce4a2:1
event: message.created
data: {"conversation_id":"chat-guid","is_from_me":false,"message_id":"message-guid","observed_at":"2026-09-15T12:00:00.000Z"}

id: 4f74f9cf-73fb-49d8-a596-3c724a5ce4a2:2
event: message.updated
data: {"changed_fields":["delivery_state","read_state"],"conversation_id":"chat-guid","message_id":"message-guid","observed_at":"2026-09-15T12:00:01.000Z"}
```

The server writes `: keep-alive` comments every 15 seconds. If a client falls
behind its bounded buffer, `stream.reset` includes `resume_after_event_id` and
`refetch_required` is `false`. Reconnect with that cursor in `Last-Event-ID`.
This safe cursor may replay duplicate events, so clients should apply events
idempotently.

A replaced database or observer failure also sends `stream.reset`, but requires
a REST refetch. An unavailable database detected before streaming starts returns
the normal JSON error shape with HTTP `503`.

## Error responses

Every error uses one JSON shape:

```json
{
  "code": "invalid_destination",
  "message": "The destination is invalid.",
  "request_id": "f066b48a-7a7b-4073-9cdd-eb65b49bad9a",
  "field_details": [
    { "field": "to", "message": "The recipient handle is invalid." }
  ]
}
```

The API uses `400` for malformed input and cursor mismatches, `401` for
authentication, `403` for the allowlist, `404` for unknown resources, `409` for
an idempotency conflict, `413` for large media, `422` for validation, `501` for
unsupported operations, `502` for an uncertain send, reaction, read, or typing
action, and `503` for unavailable Messages access, database, sender, or request
store. A conflicting idempotency key or protected typing draft returns `409`.
An ambiguous exact-participant conversation lookup also returns `409`.

## Compatibility

The Messages database schema is private and changes between macOS releases. The
current mapping was verified against the local macOS 27 schema. Startup schema
checks fail when required tables or columns are missing. Optional columns map to
`null` or an unsupported capability instead of invented values.

---
title: Messages and sending
description: Read and send messages, update reactions, and handle retries.
---

Read the [messages reference](/api/messages/) for parameters and schemas.

## List messages

```http
GET /v1/conversations/{conversation_id}/messages?limit=50&include_attachments=true&q=hello&search_mode=contains
```


Reaction event rows do not appear as ordinary messages. Reactions are always
nested under their target messages. A message thread object
keeps provider and thread-root relationships separate:

```json
{
  "thread": {
    "thread_originator_message_id": "root-message-guid",
    "provider_reply_to_message_id": "parent-message-guid"
  }
}
```

`thread_originator_message_id` identifies the first message in the native inline
thread. The thread value is null for a top-level message.

On the tested macOS schema, `reply_to_guid` does not reliably identify the
immediate parent. Messages uses it to chain ordinary top-level bubbles and can
also point a nested reply at a preceding bubble from an unrelated thread. The
relay therefore omits `reply_to_message_id` instead of exposing that
column as a verified parent relationship. For inline-thread rows,
`provider_reply_to_message_id` preserves the raw provider relationship while
`thread_originator_message_id` identifies the verified root. A send request
still accepts the exact message to target in `reply_to.message_id`.

### Native message metadata

Message responses decode additional optional provider metadata:

- `is_audio_message` marks native audio messages.
- `schedule` includes `scheduled_at`, `type`, and `state` when native scheduling
  columns are active.
- `poll.kind` is `created` for native poll balloons and `vote` for vote rows;
  votes include `original_message_id` when available.
- `balloon_bundle_id` identifies extension messages.
- Attachments include `is_sticker`.
- Recipient `display_value` uses the matching Contacts name when Contacts access
  is available.

Messages may store a URL send as adjacent text and preview rows. List and search
responses fold a `com.apple.messages.URLBalloonProvider` row into the preceding
same-sender text message as `url_preview`, avoiding a duplicate message. The
preview metadata retains its own `message_id`, `provider_guid`, and timestamp.

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
reaction contains `target_part_index`. Other reaction target forms omit that field.

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

Send to one phone number, email address, or unique Contacts name. Phone numbers
are normalized with `RELAY_PHONE_REGION` before matching:

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
`RELAY_ALLOWED_RECIPIENTS`. If the relay cannot identify every stored participant
in an existing conversation, it refuses the send rather than checking a partial
list. This currently returns `503 database_unavailable`; a known but unlisted
participant returns `403 disallowed_recipient`. Contact lookup never bypasses
the allowlist. An ambiguous or missing contact name returns `400 invalid_destination`.

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

`Idempotency-Key` is optional. The relay trims whitespace and treats a blank value as no key.
A nonblank key cannot contain control characters or exceed 128 UTF-8 bytes.
Use one unique key for one logical send:

- The same key and the same normalized request return the stored response. The
  relay does not dispatch again, even if an uploaded media file from the original
  request is no longer available.
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
| `ambiguous` | The relay cannot safely determine the result. It may have found conflicting evidence, or the send may have been interrupted before it could record a correlation checkpoint. |

When correlation completes, `messages` contains every resulting Messages GUID
and its lifecycle status. The top-level `status` summarizes those messages. It
reports `failed` if any identified message failed. It reports `read`,
`delivered`, or `sent` only when every identified message reached at least that
state.

`conversation_id` is present as soon as the relay knows the stable provider
conversation. A new group normally omits `conversation_id` from the accepted response.
A later `GET /v1/requests/{request_id}` response includes the provider ID.

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

If a send is interrupted, its durable request can have `status: result_unknown`
and `correlation_status: pending` when the relay recorded a correlation checkpoint.
Polling the request may identify a matching outgoing message, including after a
relay restart. If there is no checkpoint, the correlation status is `ambiguous`
and polling cannot identify the result automatically. An unknown result can also
come from conflicting rows, a reply mismatch, or a failed provider inspection.
Do not retry an uncertain operation with a new idempotency key. Reusing the
original key returns the stored result without sending again.

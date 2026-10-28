---
title: Live events
description: Connect to the event stream and recover after a disconnect.
---

Read the [events reference](/api/events/) for parameters and schemas.

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
| `message.updated` | Delivery, read, edit, or unsend state changed. |
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

For edits, `changed_fields` includes `edited_at`, `text`, and `parts`. For
unsends, it includes `unsent_at`, `text`, `parts`, and `attachments`. Fetch the
message again and replace the cached resource. The stream carries no old body.

Mutation checks compare exact provider stamps, including equal timestamps on
different rows and delayed updates with older timestamps. They reuse bounded
periodic checks and full reconciliation (every five minutes by default), so
updates to older rows can be delayed. Intermediate revisions are not retained.
Existing mutations at observer startup form the baseline, not new events. After
a restart or a reset that requires refetch, reconcile cached messages through
REST; the live stream is not a durable mutation archive.

The server writes `: keep-alive` comments every 15 seconds. If a client falls
behind its bounded buffer, `stream.reset` includes `resume_after_event_id` and
`refetch_required` is `false`. Reconnect with that cursor in `Last-Event-ID`.
This safe cursor may replay duplicate events, so clients should apply events
idempotently.

A replaced database or observer failure also sends `stream.reset`, but requires
a REST refetch. An unavailable database detected before streaming starts returns
the normal JSON error shape with HTTP `503`.

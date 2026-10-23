---
title: Conversations
description: Read conversations, mark them as read, and manage typing indicators.
---

Read the [conversations reference](/api/conversations/) for parameters and schemas.

## List conversations

```http
GET /v1/conversations?limit=20&unread_only=false&participant=person@example.com&cursor=
```


The relay detects the `participant` handle type. Phone comparison ignores
supported formatting characters, and email comparison is case-insensitive. The
response can contain both direct and group conversations. No match returns an
empty page.

Conversations sort by newest message first with a stable internal tie-breaker.

The response uses the common page shape:

```json
{
  "items": [],
  "has_more": false
}
```

Pass `next_cursor` unchanged to the same route and query. A cursor is opaque,
versioned, route-specific, query-bound, and database-bound.

## Read a conversation

```http
GET /v1/conversations/{conversation_id}
```

The endpoint returns `404 unknown_conversation` when no conversation has that
provider GUID.

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

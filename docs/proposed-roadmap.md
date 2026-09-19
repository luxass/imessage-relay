# Proposed roadmap and decision register

Status: Proposal. Nothing in this document is accepted merely because it is listed here.

This file records follow-up work so it can be challenged, reordered, accepted, or rejected before implementation. It does not authorize real message sends, starting a listener, or changing Messages data.

## Current implementation

The relay currently has:

- a local `/v1` HTTP API protected by the `RELAY_TOKEN` bearer token;
- read-only conversation, message, reaction, thread, and attachment mapping from `chat.db`;
- ordinary text sending through AppleScript;
- reply and media sending through macOS Accessibility automation;
- a serialized queue for Accessibility operations;
- standard reaction writes with database-confirmed results;
- database-confirmed mark-read operations;
- draft-safe, expiring typing leases for one conversation at a time;
- a live-only server-sent event stream for message changes;
- upload-then-send media storage outside the Messages database;
- durable send receipts that correlate requests with provider message GUIDs;
- durable idempotency records in the relay state database;
- synthetic database fixtures and fake senders for automated tests.

Native sends still require manual verification on the target Mac. Automated tests must never send a real iMessage.

## Proposed work

| Priority | Proposal | Why it may be useful | Decision needed |
| --- | --- | --- | --- |
| Done | Correlate a send request with the resulting Messages GUID | Lets a caller learn which message was actually created and follow its sent, delivered, read, or failed state without searching by text | Accepted on 2026-09-15. Manual verification on the target Mac remains |
| Done | Model Messages parts explicitly | Preserves verified text and attachment ordering and identifies the part targeted by a tapback | Accepted on 2026-09-15. Part-targeted writes remain deferred |
| Done | Filter conversations by participant | Lets callers find stable conversation IDs through normalized phone or email matching | Accepted on 2026-09-15. Global message search and a resolver endpoint were rejected until a concrete workflow needs them |
| Done | Add an optional event stream for message and lifecycle changes | Avoids constant polling and enables inbound-message automation | Accepted on 2026-09-15 as live-only SSE. Durable replay and webhooks remain deferred |
| Done | Improve attachment correlation and multipart representation | Connects an uploaded media ID to the resulting Messages attachment and exposes every provider message | Accepted on 2026-09-16. Filename-based matching fails closed when the result is ambiguous; transformed filenames remain future work |
| Done | Add standard reaction writes | Lets callers set or clear the local sender's whole-message Tapback through an idempotent resource | Accepted on 2026-09-16. Synthetic tests pass; manual verification on the target Mac remains. Custom emoji and part-targeted writes remain deferred |
| Done | Add mark-read | Lets an agent clear a conversation's unread state through an idempotent, database-confirmed operation | Accepted on 2026-09-17. Synthetic tests pass; manual verification on the target Mac remains |
| Done | Add typing operations | Supports interactive agent workflows through a five-second, draft-safe, single-conversation lease | Accepted on 2026-09-17. Synthetic tests pass; duration and native behavior require manual verification on the target Mac |
| Done | Add conversation and group creation | Allows an agent to start a group rather than only send to a recipient or existing conversation | [Implemented contract](group-conversation-design.md). Synthetic tests and script compilation pass; native behavior requires a user-driven Kestrel test |
| 9 | Investigate group membership and naming changes | Moves toward richer group management | Treat as a spike until reliable local operations are proven |
| 10 | Publish OpenAPI and agent-oriented client helpers | Makes the stable API easier and safer for tools and agents to call | Do this after the disputed message contract is settled |

## Explicitly deferred

Do not claim these capabilities until a safe local implementation has been verified:

- expressive message effects;
- rich cards or carousels;
- group photos;
- message editing or deletion;
- iMessage-capability lookup for arbitrary recipients;
- any provider marketplace, multi-tenant, billing, or sender-pool feature;
- a background webhook delivery worker;
- CRM, campaign, or opt-out management.

## Accepted decision: durable send receipt

Each attempted send has a durable receipt identified by a `request_id`.

The lifecycle is:

1. Validate the request and reserve its idempotency key.
2. Persist the send intent before invoking Messages.
3. Perform the AppleScript or Accessibility operation.
4. Observe `chat.db` for the resulting outgoing messages.
5. Attach every unambiguous provider GUID and media mapping to the receipt.
6. Reconcile the receipt as the provider messages become sent, delivered, read, or failed.

The receipt is not intended to become a generic job system. It is evidence for one message-send attempt across the time gap between an API call and Messages recording the result.

### API shape

The common fast path is:

```http
POST /v1/messages
Idempotency-Key: agent-run-42-message-1

{
  "to": "recipient@example.com",
  "text": "Hello"
}
```

If the provider message appears within three seconds, the response includes its
stable Messages GUID and current status:

```json
{
  "request_id": "req_123",
  "status": "sent",
  "correlation_status": "complete",
  "messages": [
    {
      "message_id": "provider-guid",
      "status": "sent"
    }
  ],
  "media": [],
  "poll_url": "/v1/requests/req_123"
}
```

If the native result is still pending or uncertain:

```json
{
  "request_id": "req_123",
  "status": "accepted",
  "correlation_status": "pending",
  "messages": [],
  "media": [],
  "poll_url": "/v1/requests/req_123"
}
```

The caller polls while `correlation_status` is `pending` or `partial`. Once it
is `complete`, each item in `messages` identifies a message resource. The
`media` array maps each uploaded media ID to the resulting attachment and
message IDs.

### Accepted decision: provider-identification gate

A durable receipt does not automatically require serializing every send.

A short identification gate records the newest database row, performs one
send, and waits for its new provider row. The next send can then start. The gate
does not wait for delivery or read state.

Rejected alternatives:

1. Allow concurrent sends and report `result_unknown` when the resulting rows
   cannot be matched safely.
2. Serialize only operations that already require Accessibility and accept weaker
   correlation for ordinary AppleScript sends.

## Examples the send receipt should handle

### Successful text

The relay accepts a text, discovers its Messages GUID, and exposes delivery changes on the same receipt. The client does not search the conversation for matching text.

### Native timeout after a possible send

AppleScript or Accessibility times out after Messages may have accepted the input. The receipt remains `result_unknown` instead of lying that the send failed. Reconciliation may later attach the provider GUID. Retrying with the same idempotency key must not create a second send.

### Duplicate client retry

The client loses the HTTP response and repeats the same key and payload. The relay returns the existing receipt. Reusing that key with a different payload returns a conflict.

### Attachment transformation

The API records the uploaded media ID. Messages may rename, copy, or transform the file and may create a separate provider message. The receipt retains the relationship between the API request and the observed message and attachment IDs.

### Native reply validation

The send intent records the requested parent message and thread root. After the outgoing row appears, the relay verifies the observed thread relationship. A mismatch is reported rather than silently presenting the reply as correct.

## Approval boundaries

- Documentation and synthetic tests can run locally.
- Live database inspection must remain read-only.
- Real iMessage operations require the user to perform the send.
- Starting an HTTP listener or event listener requires explicit user approval.
- Every newly claimed native capability requires a manual test on the target Mac.

## Accepted decision: live-only server-sent events

`GET /v1/events` gives connected clients compact notifications for new
messages, delivery and read changes, reactions, and available attachments. Each
notification contains stable resource IDs. The existing REST endpoints remain
the source of truth.

The stream starts a shared read-only SQLite observer when its first client
connects. The observer stops after its final client disconnects. A separate
SQLite connection checks `PRAGMA data_version` and compares typed snapshots only
after the database changes. Newly joined attachment files remain pending until
the media path passes the same root and regular-file checks as media downloads.

The stream does not keep a durable event journal. It emits no event IDs and
rejects `Last-Event-ID`, so it cannot imply replay that does not exist. A client
must refetch REST resources after reconnecting. A database replacement, observer
failure, or subscriber-buffer overflow emits `stream.reset` before that stream
closes.

We accept missed notifications during a disconnect in exchange for no event
journal, no delivery worker, and no second source of message truth. Durable SSE
replay would require a relay-owned journal with retention and acknowledgements.
Webhooks would also require retry scheduling and delivery state. Both remain
deferred until a concrete client needs them.

## Accepted decision: additive message parts

`Message.parts` exposes the ordered structure decoded from `attributedBody`.
The API keeps `text` and `attachments` as aggregate compatibility fields. An
attachment part contains its `MediaReference` when attachment metadata was
requested. Otherwise, the attachment value is null.

The parts value is null when the database does not contain enough evidence to
reconstruct the structure. The relay does not use `message_attachment_join` row
order as provider part order.

Read-only reactions expose `target_part_index` when
`associated_message_guid` uses the verified `p:<index>/<message-guid>` form.
The `bp:<message-guid>` form has no verified numeric part, so its value remains
null.

Part-targeted replies remain deferred. The observed `thread_originator_part`
values are composite strings such as `0:0:42`. No write contract assigns a
meaning to those components until that meaning is verified.

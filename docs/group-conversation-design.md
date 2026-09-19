# Group conversation design

Status: Implemented with synthetic tests. Native group creation still requires a
user-driven test on Kestrel. No automated test sends a real message.

## Problem

The relay can already start a one-to-one conversation by sending a message with
`to`. iMessage does not have a useful empty-conversation resource. A new chat
becomes observable in `chat.db` after Messages creates it, normally as part of a
send. The missing operation is therefore sending the first message to two or
more recipients and returning the conversation that Messages actually created
or reused.

The operation must keep the current rules. Every recipient must pass the
allowlist. The configured local iMessage account must be unambiguous. The relay
must not select a chat by display name, invent a conversation ID, or claim that
creation succeeded before `chat.db` identifies the result.

## Usage

Keep `POST /v1/messages` as the only send operation. Add `participants` as a
third destination shape:

```http
POST /v1/messages
Authorization: Bearer $RELAY_TOKEN
Idempotency-Key: agent-run-42-group-1
Content-Type: application/json

{
  "participants": [
    "alice@example.com",
    "+1 500 555 0006"
  ],
  "text": "Hello from the relay"
}
```

Exactly one of `to`, `participants`, or `conversation_id` is allowed.

The accepted response uses the existing durable send receipt. The conversation
may not be known yet:

```json
{
  "request_id": "910c16b4-88c4-4fc1-b9b3-d781ffac31ea",
  "status": "accepted",
  "correlation_status": "pending",
  "conversation_id": null,
  "messages": [],
  "media": [],
  "poll_url": "/v1/requests/910c16b4-88c4-4fc1-b9b3-d781ffac31ea"
}
```

After Messages writes the outgoing message, polling the same request returns the
stable provider conversation ID:

```json
{
  "request_id": "910c16b4-88c4-4fc1-b9b3-d781ffac31ea",
  "status": "sent",
  "correlation_status": "complete",
  "conversation_id": "iMessage;+;chat123456789",
  "messages": [
    {
      "message_id": "A-PROVIDER-MESSAGE-GUID",
      "status": "sent"
    }
  ],
  "media": [],
  "poll_url": "/v1/requests/910c16b4-88c4-4fc1-b9b3-d781ffac31ea"
}
```

The caller uses that `conversation_id` for later messages, replies, reactions,
typing, mark-read, and attachment sends.

## Shape

### Public models

```swift
enum MessageDestination {
    case conversation(ConversationID)
    case recipient(RecipientHandle)
    case participants([RecipientHandle])
}

struct SendMessageResponse {
    let requestID: RequestID
    let status: MessageStatus
    let correlationStatus: SendCorrelationStatus
    let conversationID: ConversationID?
    let messages: [MessageReceipt]
    let media: [MediaReceipt]
    let pollURL: String?
}

struct SenderCapabilities {
    // Existing fields remain.
    let groupCreation: CapabilityAvailability
}
```

`participants` contains other people in the group. It does not contain the
configured local sender. The request decoder normalizes handles, rejects a
normalized duplicate, and requires at least two participants. It also rejects
unknown fields and every request containing more than one destination shape.

Participant order has no meaning. Idempotency fingerprints sort normalized
participant keys. The same set has one fingerprint regardless of request order.
The request does not accept an account ID. The configured local sender account
is the only valid account for a new chat.

### Storage

```swift
protocol ConversationStoring {
    // Existing methods remain.
    func sendContexts(
        matchingExactParticipants participants: [RecipientHandle]
    ) async throws -> [ConversationSendContext]
}
```

The SQLite implementation compares normalized handles and requires an exact set
match. It does not use `display_name`, `chat_identifier`, or partial participant
matches. Zero matches means Messages must create a chat. One match means the
relay may send to that stable conversation. More than one match fails with
`ambiguous_conversation`; the relay will not guess which history the caller
meant.

### Application flow

`MessageService` owns the get-or-create policy because it already owns send
validation, allowlists, idempotency, and result correlation.

1. Decode exactly one destination.
2. Normalize every participant and reject duplicates.
3. Check every participant against the existing allowlist.
4. Look for an exact existing conversation.
5. Reuse one exact match with its stored local account context.
6. If none exists, require the configured iMessage account and dispatch the
   multi-recipient destination to `MessageSender`.
7. Correlate new outgoing rows by checkpoint, normalized participant set, text,
   and account context.
8. Persist the provider message GUID and conversation ID in the existing send
   receipt.

This does not introduce another sender, conversation job store, or polling
endpoint. The current `MessageSender` protocol remains the provider boundary.
`SenderDispatchRequest.destination` carries the multi-recipient destination.

### macOS provider

The native provider has two paths:

- An exact existing chat uses the current stable chat GUID and its stored account.
- A missing chat resolves every participant under the configured iMessage
  account, creates one chat with that participant list, and sends the initial
  text to the returned chat.

The local Messages scripting dictionary says that a chat's participants may be
specified at creation time. This command produced that evidence on the
development Mac on 2026-09-17:

```sh
sdef /System/Applications/Messages.app
```

The dictionary is not proof that the operation works reliably on Kestrel. The
script now compiles without running. The user still needs to verify one real
group creation on Kestrel.

The first implementation accepts text only when creating a group. Initial media
remains unsupported because the current reliable attachment path requires an
existing conversation and a provider message anchor. After the first text send
returns `conversation_id`, callers can upload and send media through that
conversation. Replies also require an existing conversation. A `participants`
request always follows these restrictions, even if an exact existing chat is
available. The API must not change validation based on hidden database state.

`GET /v1/sender` reports `capabilities.group_creation`. The provider reports
`permission_unknown` when the account and `osascript` are available because a
status request cannot test Automation permission. A status request must not run
AppleScript or trigger an Automation prompt.

### Errors

| Condition | HTTP | Code |
| --- | ---: | --- |
| Fewer than two participants | 422 | `invalid_destination` |
| Duplicate normalized participant | 422 | `invalid_destination` |
| Multiple destination fields | 400 | `ambiguous_destination` |
| Any recipient is outside the allowlist | 403 | `disallowed_recipient` |
| Several chats have the exact participant set | 409 | `ambiguous_conversation` |
| No configured account can create the group | 503 | `sender_unavailable` |
| Initial group media or reply requested | 501 | `unsupported_capability` |
| Messages may have acted but correlation is inconclusive | 502 | `send_result_unknown` |
| Idempotency key reused for another payload | 409 | `duplicate_request` |

Field errors point to `participants` or an indexed entry such as
`participants[1]`.

### Files

```text
Sources/RelayCore/Domain/Handles.swift
  Add the participants destination.

Sources/RelayCore/Domain/Messages.swift
  Decode the new request shape and add conversation_id to send receipts.

Sources/RelayCore/Domain/Sender.swift
  Report group_creation as a separate capability.

Sources/RelayCore/Storage/StorageProtocols.swift
Sources/RelayCore/Storage/SQLite/ConversationStore.swift
  Add exact participant-set lookup.

Sources/RelayCore/Application/MessageService.swift
  Normalize, authorize, resolve, dispatch, and correlate the destination.

Sources/RelayCore/Providers/MacOSMessageSender.swift
  Add the verified AppleScript group path behind the existing sender protocol.

Sources/relay-server/API/V1/MessageRoutes.swift
  Map destination validation to the stable error contract.
```

No `ConversationCreator`, second sender, or `POST /v1/conversations` route is
needed.

## Synthesis decision

Two shapes were compared.

The selected shape extends `POST /v1/messages` with `participants`. It hides
chat lookup, native creation, send correlation, and durable retry behavior
behind the send contract that clients already use.

The rejected shape adds `POST /v1/conversations`. Since Messages does not give
the relay a useful empty chat, that route would need an initial message and its
own asynchronous receipt. Clients would have to learn a second send-like API
without gaining another operation.

## Tradeoffs accepted

- We accept that creation requires initial text in exchange for a result that
  can be identified in `chat.db`.
- We accept returning `conversation_id` later through the existing poll URL in
  exchange for never inventing a provider identity.
- We accept failing when duplicate exact-match chats exist in exchange for never
  choosing a conversation by name or recency.
- We accept a text-only first group send in exchange for keeping attachments on
  the already verified upload-then-send path.
- We accept get-or-create behavior in exchange for a deterministic API. The
  first version has no `force_new` option because Messages may reuse a chat with
  the same participant set.

## Open questions and risks

- Does Kestrel's Messages version create a group through the documented chat
  participant property, and does the returned chat accept the initial send?
- Does Messages reuse an existing exact-participant chat on its own, or must the
  relay always select the stored chat first?
- Which stable account value does a newly created chat write to `chat.account_id`
  and `chat.account_login` on Kestrel?
- What participant limit should the relay document after testing the target OS?
- Can two group creations run close together without making send correlation
  ambiguous? The existing identification gate should serialize that window, but
  a synthetic concurrency test must prove it.

## Tests required before implementation is complete

- JSON contract tests for all three mutually exclusive destinations.
- Phone and email normalization plus duplicate detection.
- Allowlist checks across every participant.
- Exact participant-set matching for one match, no match, and ambiguous matches.
- Order-independent idempotency fingerprints.
- Fake sender coverage for the complete participant list and selected account.
- Correlation tests that return the stable conversation ID.
- API error contract tests for every error listed above.
- Script compilation without execution.
- One user-driven Kestrel test after synthetic tests pass.

## Next implementation step

Confirm the AppleScript creation expression by compiling it without execution,
then add the transport and domain contract tests before changing sender code.

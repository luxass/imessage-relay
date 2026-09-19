# Verified Messages database mapping

This reference records read-only inspection of
`~/Library/Messages/chat.db` on 14 September 2026. The inspected database uses
SQLite 3.54.0 and the current macOS 27 Messages schema. Row counts are evidence
from that inspection, not compatibility requirements.

No inspection query wrote to the database. Each `sqlite3` invocation used
`-readonly` and enabled `PRAGMA query_only=ON`.

## Stable identities

`chat.guid`, `message.guid`, `attachment.guid`, and
`attachment.original_guid` have `UNIQUE NOT NULL` constraints. The API uses the
provider GUID columns for conversation, message, and Messages-owned media IDs.
SQLite `ROWID` values stay inside storage queries and opaque cursors.

The database has no `databaseUUID` property. A database identity must therefore
combine filesystem identity with durable schema and GUID anchors. The identity
must not depend on mutable row counts.

## Conversations and handles

The `chat` table has 29 columns. `guid` is required. `chat_identifier`,
`service_name`, `display_name`, `room_name`, `account_id`, and `account_login`
are nullable in the schema. The inspected rows had non-null GUIDs and chat
identifiers. Group conversations had two or more rows in `chat_handle_join` and
a non-null `room_name`. One-to-one conversations had one handle.

`chat_handle_join` has foreign keys to `chat.ROWID` and `handle.ROWID` with
cascading deletes. `handle.id` and `handle.service` are required. Handles include
phone numbers, email addresses, and service-specific opaque values.
`uncanonicalized_id` is nullable and sometimes differs from `id` for SMS phone
handles. The domain model therefore keeps both a normalized value and an
optional display value.

The `participant` conversation filter reads candidate `handle.id` values and
normalizes them with the same domain rules as request input. It then filters
chats through `chat_handle_join`. The filter does not compare display names or
select one conversation when several chats contain the same handle.

Multi-recipient sends use a stricter lookup. The storage layer compares the
complete normalized handle set from `chat_handle_join`. It reuses a chat only
when that set matches exactly. Zero matches allow native group creation. More
than one match produces `ambiguous_conversation` instead of selecting by name,
date, or SQLite row ID.

Never infer a conversation from `display_name`. Resolve `ConversationID`
against `chat.guid`.

## Messages and dates

The `message` table has 103 columns. `guid` is `UNIQUE NOT NULL`; `text`,
`attributedBody`, `handle_id`, account fields, receipt dates, and thread fields
are nullable or have nullable behavior despite several numeric defaults.

All 5,080 observed message dates used SQLite integer storage. Values were
nanoseconds since 1 January 2001. Dividing by 1,000,000,000 and adding Apple’s
978,307,200-second epoch offset produced plausible UTC dates spanning March 2025
through September 2026.

`message.is_from_me` distinguishes outgoing and incoming rows. Incoming sender
handles resolve through `message.handle_id = handle.ROWID`. Outgoing rows often
have no handle. Keep the sender optional instead of inventing an empty handle.

For unread counts, the schema’s partial indexes confirm the relevant ordinary
message predicate: `is_read = 0`, `is_from_me = 0`, `item_type = 0`,
`is_finished = 1`, and `is_system_message = 0`.

For outgoing status, map `error`, `is_sent`, `is_delivered`, `is_read`,
`date_delivered`, and `date_read`. Receipt dates are evidence only when greater
than zero. Do not expose incoming delivery and read flags as recipient receipts.

## Plain text and attributed bodies

Of the inspected rows, 478 had null `text`. Of those rows, 459 had a non-null
`attributedBody`. The blobs start with the legacy `streamtyped` archive header.
A read-only sample decoded as `NSAttributedString` through Foundation’s
`NSUnarchiver`; the check printed only archive and string lengths. The mapper
uses `text` when present and otherwise attempts this attributed-string decode.
It returns `nil` when neither representation produces text.

## Replies and thread roots

The current schema has two superficially related columns, but they do not both
describe the native reply relationship:

- `thread_originator_guid` stores the root message GUID and marks an inline
  thread reply.
- `reply_to_guid` stores a preceding message GUID. Controlled top-level, root
  reply, and nested-reply sends showed that it can point at the previously sent
  bubble, including a bubble from an unrelated inline thread.

For example, a nested reply created in the thread rooted at
`323EFC7D-0903-4738-B30E-39F24160AEDE` had that value in
`thread_originator_guid`, while its `reply_to_guid` pointed at a message whose
thread root was `FDF274B9-51D7-4CEB-B5C6-2CA30EB48047`. This disproves the
earlier assumption that `reply_to_guid` is the immediate parent inside an inline
thread.

The API therefore uses `thread_originator_guid` as the verified thread root and
reports `reply_to_message_id` as null for rows read from this schema. It does not
invent an immediate parent from `reply_to_guid`.

## Reactions

Reaction event rows use `associated_message_type` values in the 2000 range for
adds. The observed values were 2000, 2001, 2002, 2003, and 2006. Type 2006 rows
had `associated_message_emoji` values. Reaction targets use either
`p:<part>/<message-guid>` or `bp:<message-guid>`. Stripping those structural
prefixes resolved 134 observed reaction events to 132 live target rows; one
resolved target belonged to a message no longer linked to the same chat.

The API always nests verified reaction events under their target message. It
does not expose reaction rows as ordinary messages. Standard whole-message
reaction writes are available through the message reaction resource.

For the `p:<part>/<message-guid>` form, the API maps the numeric part to
`target_part_index`. The observed `bp:<message-guid>` form does not contain a
verified numeric part and maps to null.

## Message parts

The live `message.part_count` values ranged from 0 through 20. Most rows had one
part, while messages with several attachments had larger values. A verified
message with six attachments and text had `part_count = 7`.

The `attributedBody` archive carries the ordered mapping. Text and attachment
runs use `__kIMMessagePartAttributeName` with a zero-based integer. Attachment
placeholders use U+FFFC and carry `__kIMFileTransferGUIDAttributeName`. That
identifier matched `attachment.guid` in the inspected examples, including
values such as `at_0_<message-guid>`.

`message_attachment_join` has no order column. The storage layer therefore
uses the attributed-body part index and attachment GUID. It never treats an
attachment row ID as provider order. If the attributed body cannot establish
the structure, the public `parts` value is null.

The live `thread_originator_part` column contains composite values such as
`0:0:42` and `2:2:1`. The rewrite does not parse these strings or expose a
part-targeted reply write until their components are verified.

## Attachments

The `attachment` table has 26 columns. `guid` and `original_guid` are unique and
required. `filename`, `uti`, and `mime_type` are nullable. `transfer_name` was
present in every observed row, and `total_bytes` used integer storage.

`message_attachment_join` has foreign keys to `message.ROWID` and
`attachment.ROWID`. All 1,230 observed join rows resolved at both ends.

Stored paths had four shapes: 822 tilde-based paths under
`~/Library/Messages/Attachments`, 383 null paths, 28 other absolute paths, and 6
relative paths. The live attachment directory contained 1,387 regular files,
2,408 directories, no symbolic links, and about 3.97 GB of data at inspection
time. Database metadata and current disk presence do not have a one-to-one
relationship.

The file reader expands a leading tilde, resolves the canonical path, requires
containment under the configured Messages attachment directory, rejects
symbolic links and non-regular files, and opens a stable descriptor before it
returns bytes. API responses never include the stored path.

## Account context

`chat.account_id` and `message.account_guid` use UUID-shaped values.
`chat.account_login` and `message.account` contain sender login identities. The
fields are nullable. For rows where both sides were present, most message and
chat values matched, but some did not. The sender must use the conversation’s
chat-level account context and must not substitute a display name or the first
available iMessage account.

The live database has no account table. The Messages AppleScript dictionary
exposes accounts with a unique `id`, enabled state, connection status, service
type, chats, and participants. Reading those live objects can trigger Automation
permission, so the rewrite does not probe them from status routes. A direct send
requires an explicitly configured account ID. A conversation send passes the
chat’s account ID and login to the sender and fails closed when the account
cannot be identified.

## Schema compatibility boundary

The storage layer requires the core tables, GUID columns, and join keys needed
to identify conversations and messages. It reports an actionable schema error
when a required item is missing. Columns for attributed text, receipts, replies,
reactions, attachment metadata, and account context are inspected as named
optional capabilities. A missing optional column produces a null domain value or
an unsupported capability. It never produces an empty identifier, a zero ID, or
a fabricated timestamp.

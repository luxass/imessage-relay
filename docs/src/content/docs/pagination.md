---
title: Pagination
description: Follow opaque cursors and handle database identity changes.
---

The chat and chat-message endpoints return `items`, `has_more`, and `next_cursor` when another page exists. Pass `next_cursor` unchanged as the next request's `cursor` parameter, keeping the original query options.

## Ordering

Chats sort by last-message date descending, then chat row ID descending. Chats without messages follow, ordered by chat row ID descending.

Each message page is chronological. Following its cursor traverses older messages. Inserts during traversal can change page boundaries; a single traversal assumes stable database contents.

## Cursor scope

A chat cursor is bound to `unread_only`. A message cursor is bound to the chat ID, attachment mode, reaction mode, exact `q` text, and `match` mode. Search text is not stored in the cursor.

Do not parse cursors or construct them from dates or row IDs. The API returns `400` for malformed cursors, unsupported versions, mismatched queries, or a replaced database. Start again without a cursor after that response.

## Database identity

Store the database fingerprint from `/status` with saved cursors. Discard the cursors when that fingerprint changes.

The `v3:` fingerprint identifies the `chat.db` filesystem instance and remains stable across normal message inserts. Replacing the database or resetting its durable identity changes the fingerprint. Do not assume that restoring a backup preserves it.

Clients upgrading from an older fingerprint format must reset stored cursors once.

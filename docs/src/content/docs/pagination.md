---
title: Pagination
description: Follow opaque cursors and handle database identity changes.
---

The conversation and message-list endpoints return `items`, `has_more`, and
`next_cursor` when another page exists. Pass `next_cursor` unchanged as the next
request's `cursor` parameter. Keep the original query options. Continue while
`has_more` is true rather than stopping when `items` is empty. A bounded message
search can return an empty continuation page while advancing through candidates
that do not match or resolving a URL-preview group at a scan boundary; that page
still includes a `next_cursor`.

## Ordering

Conversations sort by last-message date descending with a stable internal
tie-breaker. Conversations without messages follow.

Each message page is chronological. Following its cursor traverses older messages. Inserts during traversal can change page boundaries; a single traversal assumes stable database contents.

## Cursor scope

A conversation cursor is bound to `unread_only` and the normalized
`participant` filter. A message cursor is bound to the conversation ID,
attachment mode, exact `q` text, and `search_mode`. Search text
and participant values are not stored in cursors.

Do not parse cursors or construct them from dates or row IDs. The API returns `400` for malformed cursors, unsupported versions, mismatched queries, or a replaced database. Start again without a cursor after that response.

## Database identity

Store the database identity from `/v1/status` with saved cursors. Discard the
cursors when that identity changes.

The identity combines filesystem identity with stable schema and GUID anchors.
It remains stable across normal message inserts. Replacing the database changes
the identity.

Each cursor is versioned and route-specific. Do not parse it or use it with a
different endpoint.

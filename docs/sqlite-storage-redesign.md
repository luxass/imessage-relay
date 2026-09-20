# SQLite storage redesign

## Scope

This work changes `Sources/RelayCore/Storage/SQLite/` and the narrow integration points required by it. It does not redesign application sending, typing, reactions, read verification, event distribution, or HTTP contracts.

The goals are:

- Keep blocking SQLite work on dedicated workers.
- Centralize checked statement preparation, binding, stepping, and cleanup.
- Recover REST and event readers consistently after database replacement.
- Decode legacy attributed bodies once per fetched message without allowing Objective-C exceptions to terminate the process.
- Use bounded incremental work for ordinary event observation.
- Retain full snapshots as an explicit startup and reconciliation mechanism.
- Bound search candidate scanning without weakening cursor precision or preview coalescing.

Apple's database remains read-only. No tables, indexes, triggers, pragmas that change journal policy, or other schema changes may be applied to it.

## Observation model

Filesystem notifications are hints. They prompt SQLite verification but are not durable application events. No filesystem event cursor is persisted.

Each database generation owns independent in-memory observation positions. Positions never cross a database replacement and `PRAGMA data_version` values are never compared across connections.

Incremental discovery uses independent ordered streams:

- New rows ordered by `ROWID`.
- Read changes ordered by `(date_read, ROWID)` when `date_read` exists.
- Delivery changes ordered by `(date_delivered, ROWID)` when `date_delivered` exists and tests establish useful behavior.

Compound positions prevent equal-timestamp rows from being skipped while an ordered result is drained in batches. They are not a complete change log. A later update may land at or behind an existing position, or change a boolean without advancing a timestamp. Targeted rechecks and reconciliation remain required.

Undiscovered backlogs remain in SQLite behind their progress positions. The observer does not materialize the whole backlog as an in-memory queue. Pending collections contain only rows requiring follow-up work and have explicit capacity, retention, fairness, expiration, and eviction behavior.

The retained full-history baseline consumes memory proportional to observed history. Bounded pending collections do not imply bounded total observer memory.

## Detection matrix

| Change | Primary detection | Required schema | Fallback | Expected latency | Required test |
| --- | --- | --- | --- | --- | --- |
| New message | `ROWID` stream | `message.ROWID`, message/chat join | Reconciliation | Filesystem debounce or fallback check plus bounded backlog turns | Deterministic ordering and large backlog |
| Reaction addition or removal | `ROWID` stream and associated-message classification | Associated message type and GUID | Reconciliation where reaction columns are absent or relationships arrive late | Same as new rows | Addition and removal classification |
| Message initially missing a chat join | Bounded pending row-ID retries | Message/chat join | Reconciliation after expiry or eviction | Retry schedule, otherwise reconciliation | Row precedes join |
| Read update with advancing timestamp | `(date_read, ROWID)` stream | `date_read` with a usable leading index | Targeted nonterminal recheck, then reconciliation | Filesystem debounce or fallback check | Equal timestamps and old-row read update |
| Read update behind the watermark or without timestamp movement | Targeted nonterminal recheck | Read-state columns | Reconciliation | Targeted check interval or reconciliation | Update behind cursor and no timestamp advance |
| Delivery update with advancing timestamp | `(date_delivered, ROWID)` stream if validated | `date_delivered` with a usable leading index | Targeted nonterminal recheck, then reconciliation | Filesystem debounce or fallback check | Old-row delivery update |
| Delivery update behind the watermark or without timestamp movement | Targeted nonterminal recheck | Delivery-state columns | Reconciliation | Targeted check interval or reconciliation | No useful timestamp advance |
| Known attachment and path, file missing | Secure direct file check | Attachment path | Reconciliation | Pending-media poll | File appears after metadata |
| Known attachment, path missing | Targeted attachment metadata refresh | Attachment identity | Reconciliation after expiry or eviction | Pending-media poll or reconciliation | Path appears later |
| New message, association not yet visible | Targeted association lookup for a bounded candidate window | Message/attachment join | Reconciliation | Candidate retry schedule or reconciliation | Association appears later |
| Pending attachment present at startup | Startup baseline seeds pending state | Message/attachment join | Reconciliation | Pending-media poll | Startup-unavailable file appears |
| Removed attachment association | Reconciliation cleans internal state | Message/attachment join | None | Reconciliation schedule plus scan duration | Stale pending entry is removed without a deletion event |
| Database replacement | File-generation check | Filesystem identity | Controlled read failure while unavailable | Next logical read or observation check | Observer reset and REST reopen agree |

Removed relationships are internal cleanup only. This work does not add edit or deletion events.

## Pending-state policy

Pending collections process bounded batches with rotating cursors so an unresolved entry cannot monopolize a turn. Each collection has a fixed capacity and retention period. Capacity eviction and expiration increment aggregate internal diagnostics without logging message text, recipient information, or attachment paths. Reconciliation can recover work that resolves after an entry leaves a pending collection.

Concrete limits must be justified by deterministic tests and reported with the implementation. They are not copied from reference projects without evidence.

## Reconciliation

A coherent full snapshot remains for:

1. Startup baseline construction without emitting existing history.
2. Periodic correctness reconciliation.
3. Database recovery.
4. Differential tests against incremental observation.

Ordinary filesystem notifications do not request full reconciliation. Pending-media checks do not request it. Reconciliation uses one coalesced schedule and never accumulates a queue of full scans. The implementation report records the configured interval, measured fixture duration, expected latency under stated conditions, and behavior when a scan runs longer than its interval. The timer interval alone is not a hard delivery guarantee.

## SQLite execution and connection generations

The implementation uses the smallest checked statement API justified by existing callers. It must check statement preparation, bindings, row/completion stepping, and explicit cleanup without throwing from destruction or replacing an original query failure with a cleanup failure.

Messages database and relay-owned state database connections, schemas, permissions, and recovery policies remain separate even if they eventually share low-level statement mechanics.

One logical result uses a short read transaction when assembled by multiple statements. This includes message list and hydration, a single message and hydration, conversation list and participants, multi-read send-context resolution, and send-correlation candidates with related data. No transaction remains open across UI automation, timers, async sleeps, or filesystem downloads.

Before a logical operation, a cached connection verifies the path generation and reopens when needed. Reopening refreshes schema inspection. Missing databases produce controlled failures. Post-operation checks and retries are finite.

## Attributed bodies

A small local Objective-C bridge catches exceptions around the complete legacy unarchive operation. This contains a known crash mechanism but does not make unrestricted legacy object deserialization secure.

Successful decoding produces one operation-local value containing plain text and attributed parts. Attachment hydration resolves GUIDs from that value without decoding again. A failed archive produces no partial decoded value. Existing plain `message.text` and unrelated metadata remain available.

## Search

Search scans physical candidates in bounded batches and stops after enough logical matches plus lookahead, or after a documented request budget. It preserves case-insensitive and diacritic-insensitive matching, attributed-body text, integer timestamp precision, null-date ordering, query-bound cursors, and URL-preview coalescing across batch and continuation boundaries.

A bounded no-match scan may return an empty page with `has_more` set and an advancing `next_cursor`. Clients continue according to `has_more` and `next_cursor`, not item count. Tests cover repeated empty pages and prove that scanned-position continuations do not skip or duplicate logical messages.

## Evidence and reporting

Tests distinguish rows returned by SQLite from candidates examined by application decoding. Query plans or SQLite statement statistics supplement counters where needed. The final report includes deletions, replacements, fallback behavior, the implemented detection matrix, latency changes, tests, large-history evidence, remaining uncertainty, and deferred work.

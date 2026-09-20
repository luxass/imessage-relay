# SQLite storage implementation report

## Delivered changes

The storage redesign is split into reviewable layers above attachment hardening and below macOS distribution.

### Removed

- Persisted filesystem-event cursors and their server configuration were removed. Filesystem notifications remain hints and are not treated as durable message events.
- Snapshot retry-until-quiet behavior was removed. A read transaction supplies one coherent view without waiting for writes to stop.
- Raw statement preparation, unchecked bindings, unchecked row loops, and deferred unchecked finalization were removed from the Messages database readers.
- Full-history snapshots were removed from the ordinary filesystem-notification path.
- Repeated attributed-body unarchives during message mapping and attachment hydration were removed.
- Unbounded message search scans were removed.

### Replaced

- `SQLiteStatement` now checks preparation, every binding, row/completion stepping, typed column access, and explicit finalization. Cleanup cannot replace an error already thrown by the operation, and destruction does not throw.
- Multi-statement logical reads use short read transactions. This covers message list and hydration, individual message hydration, conversation list and participants, send-context resolution, send-correlation reads, status identity, and event snapshots.
- Cached Messages database connections verify the path generation before and after each logical operation. Replacement reopens the database, refreshes schema inspection, and retries a post-operation replacement once.
- Normal event observation uses bounded incremental queries. Full snapshots remain for startup, periodic reconciliation, recovery, and differential behavior.
- Legacy attributed bodies cross a narrow Objective-C exception boundary once per fetched message and become an operation-local `DecodedMessageBody` reused through hydration.
- Search reads a bounded physical candidate window and can advance through nonmatches with an empty continuation page.

The relay-owned send-request database remains a separate writable connection with its existing schema and recovery policy.

## Incremental detection behavior

| Change | Implemented primary path | Fallback and uncertainty |
| --- | --- | --- |
| New messages | `message.ROWID` batches of 256 | Reconciliation repairs relationships or rows that cannot be mapped. |
| Reaction additions and removals | The same ordered row stream classifies associated-message types | Reconciliation remains authoritative for malformed or late relationships. |
| Message before chat join | Physical candidate progress plus bounded pending row-ID retries | The independent rotating row-ID recheck and periodic reconciliation recover startup or expired work. |
| Read timestamp update | Seekable `(date_read, ROWID)` comparison when the column has a usable leading index | Independently scheduled rotating row-ID rechecks detect boolean-only, backdated, and unindexed updates; reconciliation remains final fallback. |
| Delivery timestamp update | Seekable `(date_delivered, ROWID)` comparison under the same index condition | Independently scheduled rotating rechecks and reconciliation cover unreliable or unmoved timestamps. |
| Equal update timestamps | Compound positions retain the row-ID tie-breaker | Tests update two old rows to one timestamp without skipping either. |
| New attachment association | `message_attachment_join.ROWID` batches of 256 | Reconciliation covers preexisting or removed associations. Removed associations only clean internal state; no deletion event is emitted. |
| Known attachment with missing file | Secure descriptor-based checks in rotating batches of 64 | New incremental attachments are checked before pending admission; reconciliation checks all unresolved snapshot attachments before trimming, so expired or evicted work can recover. |
| Known attachment with missing path | Targeted metadata refresh for the pending media key | Reconciliation catches remaining metadata changes. |
| Unavailable startup attachment | Startup snapshot seeds pending media | The file can produce `media.available` without another database mutation. |
| Database replacement | Device/inode generation checks around every logical read | Observer reads are bound to the stream's expected generation and reset instead of accepting old positions against a reopened database. REST readers retain their one-retry behavior. |

Filesystem notifications, directory monitoring, sidecar rearming, debounce, and fallback checks are retained. They trigger verification; they do not define commit boundaries.

## Bounded state and scheduling

- Incremental discovery batch: 256 rows per stream per turn.
- Rotating state recheck: one 256-row batch per fallback interval, scheduled independently of `data_version` changes.
- Pending relationship retries: 64 entries per turn, capacity 512, retention 30 minutes.
- Pending-media check batch: 64 entries per turn with a rotating offset.
- Pending-media capacity: 512 entries.
- Pending-media retention: 30 minutes.
- Capacity eviction and expiration are counted in internal, non-PII diagnostics.
- Large undiscovered backlogs remain represented by SQLite positions. A 600-message test requires at least three incremental turns and emits every message once.
- Periodic reconciliation interval: five minutes.
- Reconciliation triggers use a newest-one buffer. If a scan overlaps timer ticks, they coalesce rather than queueing multiple full scans. The next deadline is set after completion.

The full startup/reconciliation dictionaries still consume memory proportional to observed history. The bounded incremental and pending collections do not make total observer memory independent of history.

## Search behavior

Search examines at most `max(256, limit * 8)` ordered candidates per continuation, capped at 2,048, plus one SQLite lookahead row. Preview-group resolution may also perform up to two direct row lookups for cursor validation and association. It preserves normalized contains/exact matching, attributed-body text, integer timestamp cursors, null-date ordering, query signatures, and attachment/reaction hydration.

When the candidate budget is exhausted before a match, the response can contain:

```json
{
  "items": [],
  "has_more": true,
  "next_cursor": "..."
}
```

The cursor advances from the last scanned candidate. When enough matches fill the requested page, it resumes after the last returned match so lookahead matches are not skipped. If a window ends inside a contiguous URL-preview group, fixed-size cursor state records the group's newest row and resolution phase. Later bounded continuations find the original text or history exhaustion, then replay the group. This coalesces every associated preview without guessing an overlap length and still returns standalone preview-only histories without skips.

Clients must follow `has_more` and `next_cursor`, not infer exhaustion from `items.count`.

## Evidence

The completed stack passes 140 tests across three targets: 110 RelayCore tests, 27 RelayServer tests, and 3 app tests.

Deterministic coverage includes:

- Missing and out-of-range bindings.
- Checked `SQLITE_BUSY` stepping.
- Preservation of an original operation error during statement cleanup.
- WAL snapshot consistency across multiple statements.
- Missing database paths, stale cursors, schema refresh, and replacement before and after an operation.
- Malformed input plus two truncated valid legacy archives that would otherwise cross an Objective-C exception boundary.
- New messages, reaction additions/removals, read/delivery updates, late chat joins, equal timestamps, boolean-only updates beyond the first recheck batch, startup media, missing paths, and replacement resets.
- Progress past orphan-only timestamp and targeted batches.
- Rejection of incremental and reconciliation reads bound to an earlier database generation.
- Bounded pending-media capacity and expiration diagnostics, plus reconciliation recovery after eviction.
- A 600-message incremental backlog.
- Repeated empty search pages, advancing cursors, no duplicate or skipped matches, a 300-row preview-only candidate window, and identical logical IDs and preview associations for small and large pages across a multi-preview boundary.

On the current arm64 test host, the 10,000-message reconciliation fixture completed in 0.014–0.025 seconds across recorded runs. This fixture is synthetic and has fewer relationships and attachments than a long-lived Messages database. It supports the five-minute default as ample scheduling headroom; it is not a hard latency guarantee.

`EXPLAIN QUERY PLAN` for incremental row discovery reports:

```text
SEARCH message USING INTEGER PRIMARY KEY (rowid>?)
```

Timestamp streams are enabled only when schema inspection finds a leading index on the timestamp column. They use a row-value seek predicate rather than an `OR` predicate. A 100,000-row regression checks both one-row and empty results near the watermark using `SQLITE_STMTSTATUS_FULLSCAN_STEP` and `SQLITE_STMTSTATUS_VM_STEP`; each must stay below 100 full-scan steps and 5,000 VM steps. Otherwise the implementation uses rotating row-ID rechecks plus reconciliation.

Expected latency is therefore conditional:

- New indexed rows and indexed timestamp updates: filesystem debounce or fallback wake-up, plus any bounded backlog turns.
- Boolean-only, backdated, or unindexed updates: one bounded rotating recheck batch per fallback interval, or reconciliation.
- Evicted, expired, removed, or otherwise untracked relationships: reconciliation interval plus actual scan duration.
- A scan that exceeds five minutes delays the next scan; scans do not overlap or accumulate.

## Remaining limitations and uncertainty

- Filesystem notifications can be delayed, coalesced, or lost. Fallback checks and reconciliation are required for correctness.
- Compound watermarks prevent equal-timestamp skips but cannot detect values later written behind a watermark.
- Actual Messages schemas and index sets vary by macOS release. Indexed timestamp streams are selected from inspected schema state after each open.
- The Objective-C bridge prevents malformed legacy unarchives from terminating the process. `NSUnarchiver` is still not a secure decoder for arbitrary untrusted archives.
- Full reconciliation remains necessary for removed associations and other mutations without a reliable ordered signal.
- No public edit, deletion, or attachment-removal event was added.
- Observer diagnostics are internal and aggregate only. They do not log message text, recipients, or attachment paths.
- Send correlation remains explicitly uncertain when provider messages or attachment mappings are ambiguous; this work does not broaden the sending model.
- No indexes or other schema objects are created in Apple’s database.

Broader application-service redesign, public metrics, edit/delete event contracts, and changes to the relay-owned send-request store remain deferred.

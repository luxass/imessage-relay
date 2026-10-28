---
title: Feature support
description: Supported Messages operations, read-only metadata, and verification limits.
---

This page describes the API in this source version. Older release builds can
expose fewer operations. Support depends on permissions, the Messages version,
and available database fields.

## Read operations

| Feature | Support | Limit |
| --- | --- | --- |
| Conversations and history | Supported | Provider IDs remain stable. Cursors belong to one database and query. |
| Text search | Conversation and global search | Exact or contains matching ignores case and accents. No filename search or revision search. |
| Outgoing sender identity | Local identity when stored | `sender` is null when the account identity is unavailable. The recipient is not substituted as the outgoing sender. |
| Incoming sender identity | Stored correspondent identity | Contact names depend on available contact access. |
| Edited messages | Current attributed body and `edited_at` | An undecodable edited body returns null text, not the stale original. No revision archive. |
| Unsent messages | Stable identity and `unsent_at` | Former text, parts, and attachments are removed from the response. Attachments linked only to unsent messages cannot be downloaded. |
| Attachments | Metadata and safe downloads | Files must remain within the attachment root and pass file-safety checks. |
| Threads | Native thread root and provider relationship | The raw provider relationship is not a verified immediate reply parent. |
| URL previews | Preview metadata and folding of adjacent candidate runs | Runs never combine messages from different conversations. An unrelated candidate can end a run. |
| Polls | Basic creation/vote metadata | No question, option, vote-total, or revision decoder. |
| Voice messages | Audio metadata and available attachment bytes | No stored transcript decoder or transcription service. |
| Native Send Later | Read-only pending queue across conversations | Recognizes known markers only. Missing schedule/sent-state columns return `501`; unknown states are omitted. |
| Message counts | Sent/received direction counts per conversation and date range | No delivery totals, attachment-size reports, or persistent statistics cache. |

[Messages and sending](/guides/messages/) describes search, current mutation state,
the scheduled queue, and count intervals. [Uploads and downloads](/guides/media/)
describes attachment handling.

## Write operations

| Feature | Support | Required conditions and limits |
| --- | --- | --- |
| Direct text sends | Supported through Messages AppleScript | A configured local account and allowlisted destination are required. |
| Existing-conversation sends | Supported | Every participant must be allowlisted. The conversation determines its account. |
| New groups | Text sends with multiple participants | No general group administration. Participant sends do not accept media or native reply targets. |
| Native inline replies | Supported through Accessibility | Requires an existing conversation and an exact target message. |
| Media sends | Supported through Accessibility | Upload media first, then send its reference to an existing conversation. |
| Standard reactions | Set or clear six standard reactions | Uses the provider's default message part. UI controls vary with Messages versions. Custom reaction writes are not supported. |
| Mark read | Local state change with database confirmation | Does not prove that another device received a read receipt. |
| Typing | Refreshable five-second lease | The relay removes its own marker, not a user's draft. Active local state does not prove remote delivery. |
| Edit or unsend actions | Not provided | These are read-only states in this API. |
| Schedule, cancel, or reschedule | Not provided | The scheduled queue does not perform native Send Later actions. |
| Poll actions and group administration | Not provided | No poll voting, participant changes, group rename, or group-photo operations. |

An empty recipient allowlist denies all sends. An accepted request does not prove
delivery. Durable request state records send attempts; polling does not send
again. Do not repeat a native write after an uncertain result without reading
its current state. See [messages and sending](/guides/messages/).

## Live events and recovery

The event stream reports new messages, delivery/read changes, reactions, available
media, and observed edit/unsend changes. Fetch the current resource after a
change notice. Events do not contain former message bodies.

The relay compares exact mutation stamps through bounded periodic checks and
full reconciliation. Older-row changes can wait for reconciliation, which
defaults to a five-minute interval. Existing mutations at observer startup form
the baseline. Intermediate edits are not retained.

Replay uses a bounded event history in the current relay process. After a
restart or expired cursor, refetch the required REST resources. Durable
insertion catch-up and a complete historical change log are not provided.
See [live events](/guides/events/) for replay, overflow, and reset behavior.

## Permissions and platform boundaries

Reads use the Messages database in read-only mode. Relay-owned durable state
lives separately in `relay.db`. Text sends use Messages AppleScript. UI operations
use public Accessibility APIs. The relay does not inject code, use private send
frameworks, or require changes to System Integrity Protection.

Full Disk Access permits database reads. Automation permits AppleScript sends.
Accessibility permits UI operations. Status checks do not request permissions;
user actions handle permission requests. See [installation](/getting-started/).

Apple documents [Accessibility action discovery](https://developer.apple.com/documentation/applicationservices/1462053-axuielementcopyactionnames),
[action execution](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction),
and [trust assessment](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted).
These documents do not define Messages menu identifiers, database columns, or
private payload formats. Those details are observed behavior, not Apple API
contracts.

## Verification coverage

The deployment target is macOS 14 or newer on Apple silicon and Intel. That target
is not a claim that every Messages UI path was tested on every macOS release.

CI runs on macOS 26. Automated storage tests use synthetic databases, not a user's
Messages history. They cover cursor validation, current-body decoding, mutation
observation, search, scheduled filtering, counts, and failure paths.

Live evidence on macOS 27.0.1 includes a database-confirmed text send and a
standalone Accessibility reaction check. The reaction check did not exercise
the packaged relay and does not certify its reaction endpoint. Native replies,
media sends, read changes, and typing need operation-specific live validation.

The new scheduled-queue marker classification is fixture-tested only. It was
not verified against a live native Send Later queue. A reported capability or a
permission grant does not prove that a UI action succeeded.

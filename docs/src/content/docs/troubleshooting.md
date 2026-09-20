---
title: Troubleshooting and compatibility
description: Resolve database access and sending problems on macOS.
---

## The database is not ready

Check `GET /v1/status`. Grant **iMessage Relay**, or the terminal running the
standalone server, Full Disk Access in **System Settings > Privacy & Security**.
Reload the app configuration or restart the standalone process. If you set
`RELAY_CHAT_DB_PATH`, check that it points to the intended Messages database.

## Sending is denied

Sending is disabled until the app's `allowedRecipients` setting or the CLI's
`RELAY_ALLOWED_RECIPIENTS` variable contains recipients. An empty allowlist
denies every send. For an existing group chat, every participant must be allowed.

Set the app's `senderAccountID` or the CLI's `RELAY_SENDER_ACCOUNT_ID` for direct
sends. The value identifies your local iMessage account, not the recipient. A
conversation send uses the account context stored in `chat.db`.

The first send can prompt for **Automation > Messages** permission. Neither
`/v1/status` nor `/v1/sender` triggers this prompt. Both routes report the sender
capability as `permission_unknown` without probing Messages.

Attachment sends use Accessibility and require an existing conversation. Grant
Accessibility permission to the process that runs `relay-server`. Direct media
sends to `to` are unsupported.

See [send errors](/api/#retry-a-send-safely) before retrying. A `502` response
with `send_result_unknown` means that the outcome is uncertain. Do not retry with
a new idempotency key.

## A native reply is unavailable

The public Messages AppleScript dictionary does not expose native replies. The
relay uses Accessibility instead. Grant Accessibility permission to the relay
process and send through an existing `conversation_id`.

## A saved cursor stops working

Start again without the cursor after a `400` response. See [pagination](/pagination/) for query binding and database fingerprint rules.

## Some messages have empty text

Some messages have no text, such as attachment-only messages. For legacy
attributed bodies, the relay decodes the archived attributed string when
possible. Unknown or undecodable content remains `null`.

## macOS compatibility

The app and standalone binary require macOS 14 or newer. GitHub release artifacts
carry a Developer ID signature, and Apple notarizes both executables. The app also
carries a stapled notarization ticket. Local packages use ad hoc signing and are
not notarized.

The Messages database has a private schema that changes between macOS releases. The relay is tested on macOS 27. Other versions may require changes.

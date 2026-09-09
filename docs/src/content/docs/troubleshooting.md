---
title: Troubleshooting and compatibility
description: Resolve database access and sending problems on macOS.
---

## The database is not ready

Check `GET /status`. Grant the terminal or service running `relay-server` Full Disk Access in **System Settings > Privacy & Security**, then restart that process. If you set `RELAY_CHAT_DB_PATH`, check that it points to the intended Messages database.

## Sending is denied

Sending is disabled until `RELAY_ALLOWED_RECIPIENTS` is set. An empty allowlist denies every send. For an existing group chat, every participant must be allowed.

The first send prompts for **Automation > Messages** permission. `/status` does not trigger this prompt; its `automation_permission` value is `unknown`.

See [send errors](/api/#send-a-message) before retrying. A `500` response means the outcome is uncertain and must not be retried automatically.

## A saved cursor stops working

Start again without the cursor after a `400` response. See [pagination](/pagination/) for query binding and database fingerprint rules.

## Some messages have empty text

Some system messages store their content only in a binary blob. The relay does not decode that blob, so their `text` field is empty.

## macOS compatibility

The binary requires macOS 14 or newer. It is ad hoc signed and not notarized.

The Messages database has a private schema that changes between macOS releases. The relay is tested on macOS 27. Other versions may require changes.

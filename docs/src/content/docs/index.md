---
title: imessage-relay
description: Read and send Apple Messages through a local HTTP API on macOS.
---

Expose Apple Messages as a local HTTP API on macOS. Read chat history, search
messages within a chat, download attachments, and send texts from one native
Swift binary.

Reads go directly to `~/Library/Messages/chat.db`. Sends use Messages.app's AppleScript interface. The relay does not use private frameworks or process injection.

## Start here

[Install the relay and make your first request](/getting-started/). You need macOS 14 or newer and Full Disk Access for the process running the relay.

## Integrate with the API

- [API reference](/api/) covers endpoints, parameters, response details, and send errors.
- [Pagination](/pagination/) explains cursors, database fingerprints, and restarting traversal.
- [Configuration](/configuration/) covers listening addresses, authentication, and recipient permissions.
- [Troubleshooting](/troubleshooting/) covers macOS permissions and compatibility.

Source code and releases are available on [GitHub](https://github.com/luxass/imessage-relay).

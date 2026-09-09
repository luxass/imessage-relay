---
title: Getting started
description: Install the relay, grant macOS permissions, and make your first API request.
---

Download the universal binary for Apple silicon and Intel Macs:

```sh
curl -fsSL -o relay-server.tgz \
  https://github.com/luxass/imessage-relay/releases/latest/download/relay-server-macos-universal.tar.gz
tar xzf relay-server.tgz
./relay-server
```

The binary requires macOS 14 or newer. It is ad hoc signed and not notarized.

### Build from source

Building requires Swift 6.1 or a newer Swift 6 release.

```sh
git clone https://github.com/luxass/imessage-relay.git
cd imessage-relay
swift build
.build/debug/relay-server
```



## Usage

Grant the terminal or service that runs `relay-server` **Full Disk Access** in
**System Settings > Privacy & Security**, then restart that process.

Start the relay:

```sh
relay-server
```

From another terminal, check that the relay can read the Messages database:

```sh
curl -s localhost:8080/status | jq
curl -s 'localhost:8080/chats?limit=3' | jq '.items'
```

Use a chat `id` to read its messages:

```sh
curl -s 'localhost:8080/chats/42/messages?limit=10' | jq
```

Sending is disabled until you set `RELAY_ALLOWED_RECIPIENTS`. The first send
also prompts for **Automation > Messages** permission.

```sh
RELAY_ALLOWED_RECIPIENTS="+12025550123,mom@icloud.com" relay-server
```

From another terminal, send a message:

```sh
curl -s -X POST localhost:8080/send \
  -H 'Content-Type: application/json' \
  -d '{"to":"+12025550123","text":"hello"}'
```


See the [API reference](/api/) for all endpoints and response details.

---
title: Service status
description: Inspect sender capabilities, permissions, and database readiness.
---

Read the [status reference](/api/status/) for parameters and schemas.

## Read service status

```http
GET /v1/status
```

The response contains service health, database readiness and identity, and the
sender status. The route does not run AppleScript or trigger an Automation
permission prompt.

`GET /v1/sender` returns the same sender object. Each capability is `available`,
`unavailable`, `permission_unknown`, or `unsupported`. The macOS sender reports
text as `permission_unknown` when an account is configured because a status
request does not probe Messages. Media, native replies, and reaction writes are
`available` only when the relay process has Accessibility permission.
`group_creation` follows text because it uses AppleScript and the configured
account. Its permission remains `permission_unknown` until a send attempts the
operation.

The sender also reports permissions separately:

```json
{
  "permissions": {
    "automation": "unknown",
    "accessibility": "not_granted"
  }
}
```

Accessibility is `granted` or `not_granted`. The status routes use the
non-prompting macOS trust check, so they never open System Settings or request
access. Automation remains `unknown` because probing it would contact Messages.
Media, native replies, and reaction writes report `unavailable` until
Accessibility permission is granted.

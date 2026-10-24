---
title: Error responses
description: Interpret HTTP errors and uncertain native results.
---

Read [send retry behavior](/guides/messages/#retry-a-send-safely) before you retry an uncertain operation.

## Error responses

Every error uses one JSON shape:

```json
{
  "code": "invalid_destination",
  "message": "The destination is invalid.",
  "request_id": "f066b48a-7a7b-4073-9cdd-eb65b49bad9a",
  "field_details": [
    { "field": "to", "message": "The recipient handle is invalid." }
  ]
}
```

The API uses `400` for malformed input and cursor mismatches, `401` for
authentication, `403` for the allowlist, `404` for unknown resources, `409` for
an idempotency conflict, `413` for large media, `422` for validation, `501` for
unsupported operations, `502` for an uncertain send, reaction, read, or typing
action, and `503` for unavailable Messages access, database, sender, or request
store. A conflicting idempotency key or protected typing draft returns `409`.
An ambiguous exact-participant conversation lookup also returns `409`.

---
title: Uploads and downloads
description: Upload files and download Messages attachments.
---

Read the [media reference](/api/media/) for parameters and schemas.

## Upload and download media

Upload the raw request body:

```http
POST /v1/media
Content-Type: image/jpeg
X-Filename: photo.jpg

<file bytes>
```

The maximum size defaults to 25 MiB and cannot exceed 25 MiB. Filenames cannot
contain path separators, control characters, quotes, or semicolons. Allowed MIME
types include image, video, audio, text, PDF, and octet-stream. Image uploads
must decode as images and stay within bounded dimensions, frame count, and total
decoded pixels.

`GET /v1/media/{media_id}` returns metadata. Add `?download=true` to receive the
bytes. The endpoint never returns a stored filesystem path. Stored uploads and
Messages attachments are opened component by component without following
symlinks. Pipes, non-regular files, and files with extra hard links are rejected.
Downloads also stop if file identity, size, or timestamps change during a read.

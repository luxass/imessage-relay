import Foundation
import Hummingbird
import NIOCore
import RelayCore

struct MediaRoutes {
    let media: MediaService
    let maximumBytes: Int64

    func register(on router: Router<RelayRequestContext>) {
        router.post("/v1/media", use: upload)
        router.get("/v1/media/:media_id", use: get)
    }

    @Sendable private func upload(_ request: Request, context: RelayRequestContext) async throws -> Response {
        guard let filename = request.headers[.init("x-filename")!] else {
            throw RelayServiceError.unsafeMedia("Provide the original filename in X-Filename.")
        }
        guard let mimeType = request.headers[.contentType] else {
            throw RelayServiceError.unsafeMedia("Provide the media MIME type in Content-Type.")
        }
        let maximum = Int(exactly: maximumBytes) ?? Int.max - 1
        let buffer = try await request.body.collect(upTo: maximum + 1)
        let response = try await media.upload(
            filename: filename,
            mimeType: mimeType,
            data: Data(buffer.readableBytesView)
        )
        return try jsonResponse(response, status: .created, requestID: context.requestID)
    }

    @Sendable private func get(_ request: Request, context: RelayRequestContext) async throws -> Response {
        let raw = try pathValue("media_id", context: context)
        let id = try MediaID(validating: raw)
        let download = try V1Query.bool(request, "download")
        if !download {
            return try jsonResponse(try await media.reference(id: id), requestID: context.requestID)
        }
        let readable = try await media.readable(id: id)
        let contentLength = Int(exactly: readable.byteCount)
        let body = ResponseBody(contentLength: contentLength) { writer in
            var offset: Int64 = 0
            while offset < readable.byteCount {
                let data = try readable.readChunk(offset: offset)
                guard !data.isEmpty else { break }
                try await writer.write(ByteBuffer(bytes: data))
                offset += Int64(data.count)
            }
            try await writer.finish(nil)
        }
        let filename = safeDownloadFilename(
            readable.reference.filename ?? readable.reference.mediaID.rawValue
        )
        return Response(
            status: .ok,
            headers: [
                .contentType: readable.reference.mimeType ?? "application/octet-stream",
                .init("content-disposition")!: "attachment; filename=\"\(filename)\"",
                .init("x-request-id")!: context.requestID.rawValue,
            ],
            body: body
        )
    }
}

func safeDownloadFilename(_ value: String) -> String {
    let folded = value.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    let sanitized = folded.unicodeScalars.map { scalar -> Character in
        let isPrintableASCII = scalar.value >= 0x20 && scalar.value <= 0x7E
        let reserved = CharacterSet(charactersIn: "\"\\/:;").contains(scalar)
        return isPrintableASCII && !reserved ? Character(String(scalar)) : "_"
    }
    let limited = String(sanitized.prefix(180)).trimmingCharacters(in: .whitespaces)
    return limited.isEmpty ? "download" : limited
}

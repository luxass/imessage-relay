import Hummingbird
import HummingbirdRouter
import RelayCore

struct AttachmentsController: RouterController {
    typealias Context = RelayRequestContext

    let store: MessageStore

    var body: some RouterMiddleware<Context> {
        Get("attachments/:rowid", handler: download)
    }

    @Sendable private func download(
        _ request: Request,
        context: Context
    ) async throws -> Response {
        guard let rowid = context.parameters.get("rowid", as: Int64.self), rowid > 0 else {
            throw HTTPError(.badRequest, message: "path parameter :rowid must be a positive attachment rowid")
        }
        guard let resource = try await withStoreErrorMapping(logger: context.logger, {
            try await store.attachmentResource(rowid: rowid)
        }) else {
            throw HTTPError(.notFound, message: "attachment not found or backing file missing")
        }
        let body = try await Self.responseBody(for: resource, context: context)
        return Response(
            status: .ok,
            headers: [.contentType: resource.mimeType],
            body: body
        )
    }

    static func responseBody(
        for resource: MessageStore.AttachmentResource,
        context: some RequestContext
    ) async throws -> ResponseBody {
        let chunkLength = 128 * 1024
        return ResponseBody(contentLength: Int(exactly: resource.byteCount)) { writer in
            var offset: Int64 = 0
            while offset < resource.byteCount {
                let data = try await resource.readChunk(atOffset: offset, upToCount: chunkLength)
                guard !data.isEmpty else { break }
                try await writer.write(ByteBuffer(bytes: data))
                offset += Int64(data.count)
            }
            try await writer.finish(nil)
        }
    }
}

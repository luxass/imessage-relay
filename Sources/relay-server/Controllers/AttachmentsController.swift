import Hummingbird
import HummingbirdRouter
import NIOCore

struct AttachmentsController: RouterController {
    typealias Context = RelayRequestContext

    let store: StoreProvider

    var body: some RouterMiddleware<Context> {
        Get("attachments/:rowid", handler: download)
    }

    @Sendable private func download(
        _ request: Request,
        context: Context
    ) throws -> Response {
        guard let rowid = context.parameters.get("rowid", as: Int64.self), rowid > 0 else {
            throw HTTPError(.badRequest, message: "path parameter :rowid must be a positive attachment rowid")
        }
        guard let file = try withStoreErrorMapping({
            try store.withStore { try $0.attachmentData(rowid: rowid) }
        }) else {
            throw HTTPError(.notFound, message: "attachment not found or backing file missing")
        }
        return Response(
            status: .ok,
            headers: [.contentType: file.mimeType],
            body: .init(byteBuffer: ByteBuffer(bytes: file.data))
        )
    }
}

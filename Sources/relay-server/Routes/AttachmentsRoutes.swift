import Hummingbird
import NIOCore

/// GET /attachments/:rowid — streams attachment bytes from disk.
enum AttachmentsRoutes {
    static func register(_ router: Router<BasicRequestContext>, store: StoreProvider) {
        router.get("attachments/:rowid") { _, context in
            guard let rowid = context.parameters.get("rowid", as: Int64.self), rowid > 0 else {
                throw HTTPError(.badRequest, message: "path parameter :rowid must be a positive attachment rowid")
            }
            guard let file = try API.storeError({ try store.withStore({ try $0.attachmentData(rowid: rowid) }) }) else {
                throw HTTPError(.notFound, message: "attachment not found or backing file missing")
            }
            return Response(
                status: .ok,
                headers: [.contentType: file.mimeType],
                body: .init(byteBuffer: ByteBuffer(bytes: [UInt8](file.data)))
            )
        }
    }
}

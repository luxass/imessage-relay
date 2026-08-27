import Foundation
import Testing

@testable import RelayCore

@Test
func messageAttachmentsExposeDownloadRowID() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO attachment
            (ROWID, filename, transfer_name, mime_type, uti, total_bytes, is_sticker)
        VALUES
            (700, '/missing/photo.jpg', 'photo.jpg', 'image/jpeg', 'public.jpeg', 123, 0);
        INSERT INTO message_attachment_join (message_id, attachment_id)
        VALUES (100, 700);
        """)

    let messages = try await fixture.makeStore().messages(chatID: 1, includeAttachments: true)
    let attachment = try #require(messages.items.first?.attachments.first)

    #expect(attachment.id == 700)
    #expect(attachment.transferName == "photo.jpg")
    #expect(attachment.mimeType == "image/jpeg")
    #expect(attachment.missing)
}

@Test
func attachmentResourcesReportExactSizeAndMimeFallback() async throws {
    let fixture = try MessageDatabaseFixture()
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-attachment-\(UUID().uuidString)")
    let bytes = Data([0x00, 0x01, 0x7F, 0xFF])
    try bytes.write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try fixture.execute("""
        INSERT INTO attachment (ROWID, filename, mime_type, total_bytes)
        VALUES (701, '\(fileURL.path)', '', 999),
               (702, '/synthetic/missing/file', 'text/plain', 12);
        """)

    let store = fixture.makeStore()
    let resource = try #require(try await store.attachmentResource(rowid: 701))
    #expect(resource.fileURL == fileURL)
    #expect(resource.mimeType == "application/octet-stream")
    #expect(resource.byteCount == Int64(bytes.count))
    #expect(try await store.attachmentResource(rowid: 702) == nil)
}

@Test
func attachmentResourcesRejectDirectoriesAndSymlinks() async throws {
    let fixture = try MessageDatabaseFixture()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-attachment-directory-\(UUID().uuidString)")
    let file = directory.appendingPathComponent("file.txt")
    let symlink = directory.appendingPathComponent("link.txt")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("safe".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
    try fixture.execute("""
        INSERT INTO attachment (ROWID, filename) VALUES
            (703, '\(directory.path)'),
            (704, '\(symlink.path)');
        """)

    let store = fixture.makeStore()
    #expect(try await store.attachmentResource(rowid: 703) == nil)
    #expect(try await store.attachmentResource(rowid: 704) == nil)
}

@Test
func attachmentResourcesKeepStableDescriptorAndBoundChunks() async throws {
    let fixture = try MessageDatabaseFixture()
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-attachment-stable-\(UUID().uuidString)")
    let original = Data(repeating: 0x41, count: 128 * 1024 + 17)
    try original.write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try fixture.execute("""
        INSERT INTO attachment (ROWID, filename, mime_type)
        VALUES (705, '\(fileURL.path)', 'application/octet-stream');
        """)

    let store = fixture.makeStore()
    let resource = try #require(try await store.attachmentResource(rowid: 705))
    try Data(repeating: 0x42, count: original.count).write(to: fileURL, options: .atomic)

    let firstChunk = try await resource.readChunk(atOffset: 0, upToCount: original.count)
    let finalChunk = try await resource.readChunk(atOffset: Int64(firstChunk.count), upToCount: original.count)
    #expect(firstChunk == original.prefix(128 * 1024))
    #expect(finalChunk == original.suffix(17))
}

@Test
func attachmentReadsRejectAfterOwningStoreShutdown() async throws {
    let fixture = try MessageDatabaseFixture()
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-attachment-shutdown-\(UUID().uuidString)")
    try Data("content".utf8).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try fixture.execute("""
        INSERT INTO attachment (ROWID, filename) VALUES (706, '\(fileURL.path)');
        """)

    let store = fixture.makeStore()
    let resource = try #require(try await store.attachmentResource(rowid: 706))
    try await store.shutdown()

    await #expect(throws: (any Error).self) {
        try await resource.readChunk(atOffset: 0, upToCount: 128 * 1024)
    }
}

@Test
func redactedAttachmentEncodingCanBeDecoded() async throws {
    let attachment = Attachment(
        id: 1,
        filename: "/private/source",
        transferName: "photo.jpg",
        mimeType: "image/jpeg",
        uti: "public.jpeg",
        totalBytes: 10,
        isSticker: false,
        originalPath: "/private/source",
        missing: false
    )

    let decoded = try JSONDecoder().decode(Attachment.self, from: JSONEncoder().encode(attachment))
    #expect(decoded.id == attachment.id)
    #expect(decoded.filename.isEmpty)
    #expect(decoded.originalPath == nil)
    #expect(decoded.transferName == attachment.transferName)
}

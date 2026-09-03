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
    let fileURL = try attachmentURL(for: fixture, name: "size-and-mime.bin")
    let bytes = Data([0x00, 0x01, 0x7F, 0xFF])
    try bytes.write(to: fileURL)
    try fixture.execute("""
        INSERT INTO attachment (ROWID, filename, mime_type, total_bytes)
        VALUES (701, '\(fileURL.path)', '', 999),
               (702, '/synthetic/missing/file', 'text/plain', 12);
        INSERT INTO message_attachment_join (message_id, attachment_id)
        VALUES (100, 701), (100, 702);
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
    let directory = try attachmentDirectory(for: fixture)
    let file = directory.appendingPathComponent("file.txt")
    let symlink = directory.appendingPathComponent("link.txt")
    try Data("safe".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
    try fixture.execute("""
        INSERT INTO attachment (ROWID, filename) VALUES
            (703, '\(directory.path)'),
            (704, '\(symlink.path)');
        INSERT INTO message_attachment_join (message_id, attachment_id)
        VALUES (100, 703), (100, 704);
        """)

    let store = fixture.makeStore()
    #expect(try await store.attachmentResource(rowid: 703) == nil)
    #expect(try await store.attachmentResource(rowid: 704) == nil)
}

@Test
func attachmentResourcesRequireMessageLinkAndAttachmentDirectory() async throws {
    let fixture = try MessageDatabaseFixture()
    let databaseDirectory = URL(fileURLWithPath: fixture.path).deletingLastPathComponent()
    let attachmentDirectory = databaseDirectory.appendingPathComponent("Attachments")
    let orphan = attachmentDirectory.appendingPathComponent("orphan.txt")
    let dangling = attachmentDirectory.appendingPathComponent("dangling.txt")
    let linked = attachmentDirectory.appendingPathComponent("linked.txt")
    let outsideDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-attachment-outside-\(UUID().uuidString)")
    let outside = outsideDirectory.appendingPathComponent("outside.txt")
    let escapedDirectory = attachmentDirectory.appendingPathComponent("escaped")
    let escaped = escapedDirectory.appendingPathComponent("outside.txt")
    try FileManager.default.createDirectory(
        at: attachmentDirectory,
        withIntermediateDirectories: true
    )
    try Data("orphan".utf8).write(to: orphan)
    try Data("dangling".utf8).write(to: dangling)
    try Data("linked".utf8).write(to: linked)
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: escapedDirectory,
        withDestinationURL: outsideDirectory
    )
    defer { try? FileManager.default.removeItem(at: outsideDirectory) }
    try fixture.execute("""
        INSERT INTO attachment (ROWID, filename) VALUES
            (707, '\(orphan.path)'),
            (708, '\(dangling.path)'),
            (709, '\(outside.path)'),
            (710, '\(linked.path)'),
            (711, '\(escaped.path)');
        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES
            (9999, 708),
            (100, 709),
            (100, 710),
            (100, 711);
        """)

    let store = fixture.makeStore()
    #expect(try await store.attachmentResource(rowid: 707) == nil)
    #expect(try await store.attachmentResource(rowid: 708) == nil)
    #expect(try await store.attachmentResource(rowid: 709) == nil)
    #expect(try await store.attachmentResource(rowid: 710) != nil)
    #expect(try await store.attachmentResource(rowid: 711) == nil)
}

@Test
func attachmentResourcesKeepStableDescriptorAndBoundChunks() async throws {
    let fixture = try MessageDatabaseFixture()
    let fileURL = try attachmentURL(for: fixture, name: "stable.bin")
    let original = Data(repeating: 0x41, count: 128 * 1024 + 17)
    try original.write(to: fileURL)
    try fixture.execute("""
        INSERT INTO attachment (ROWID, filename, mime_type)
        VALUES (705, '\(fileURL.path)', 'application/octet-stream');
        INSERT INTO message_attachment_join (message_id, attachment_id)
        VALUES (100, 705);
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
    let fileURL = try attachmentURL(for: fixture, name: "shutdown.txt")
    try Data("content".utf8).write(to: fileURL)
    try fixture.execute("""
        INSERT INTO attachment (ROWID, filename) VALUES (706, '\(fileURL.path)');
        INSERT INTO message_attachment_join (message_id, attachment_id)
        VALUES (100, 706);
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

private func attachmentDirectory(for fixture: MessageDatabaseFixture) throws -> URL {
    let directory = URL(fileURLWithPath: fixture.path)
        .deletingLastPathComponent()
        .appendingPathComponent("Attachments")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func attachmentURL(for fixture: MessageDatabaseFixture, name: String) throws -> URL {
    try attachmentDirectory(for: fixture).appendingPathComponent(name)
}

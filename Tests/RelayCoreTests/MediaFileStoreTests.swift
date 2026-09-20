import Darwin
import Foundation
import Testing

@testable import RelayCore

@Test
func mediaFileStoreRejectsChangedHardLinkedPipedAndSymlinkedFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-media-path-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MediaFileStore(directory: root)
    let changed = try await store.save(MediaUpload(
        filename: "changed.txt",
        mimeType: "text/plain",
        data: Data("fixture".utf8)
    ))
    let readable = try #require(try await store.readable(id: changed.mediaID))
    let changedURL = root
        .appendingPathComponent(changed.mediaID.rawValue)
        .appendingPathComponent("changed.txt")
    let handle = try FileHandle(forWritingTo: changedURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("changed".utf8))
    try handle.close()
    #expect(throws: SQLiteStorageError.self) { try readable.readChunk(offset: 0) }

    let linked = try await store.save(MediaUpload(
        filename: "linked.txt",
        mimeType: "text/plain",
        data: Data("fixture".utf8)
    ))
    let linkedURL = root
        .appendingPathComponent(linked.mediaID.rawValue)
        .appendingPathComponent("linked.txt")
    try FileManager.default.linkItem(at: linkedURL, to: root.appendingPathComponent("extra-link"))
    #expect(try await store.outbound(id: linked.mediaID) == nil)

    let piped = try await store.save(MediaUpload(
        filename: "piped.txt",
        mimeType: "text/plain",
        data: Data("fixture".utf8)
    ))
    let pipedURL = root
        .appendingPathComponent(piped.mediaID.rawValue)
        .appendingPathComponent("piped.txt")
    try FileManager.default.removeItem(at: pipedURL)
    #expect(mkfifo(pipedURL.path, 0o600) == 0)
    #expect(try await store.outbound(id: piped.mediaID) == nil)

    let realRoot = root.appendingPathComponent("real", isDirectory: true)
    let linkedRoot = root.appendingPathComponent("linked-root", isDirectory: true)
    try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
    let linkedStore = MediaFileStore(directory: linkedRoot)
    await #expect(throws: (any Error).self) {
        try await linkedStore.save(MediaUpload(
            filename: "blocked.txt",
            mimeType: "text/plain",
            data: Data("fixture".utf8)
        ))
    }
}

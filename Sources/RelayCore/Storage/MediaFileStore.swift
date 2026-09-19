import Foundation

public struct MediaUpload: Sendable {
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public protocol UploadedMediaStoring: Sendable {
    func save(_ upload: MediaUpload) async throws -> MediaReference
    func reference(id: MediaID) async throws -> MediaReference?
    func readable(id: MediaID) async throws -> ReadableMedia?
    func outbound(id: MediaID) async throws -> OutboundMedia?
}

public final class MediaFileStore: UploadedMediaStoring, @unchecked Sendable {
    private struct Metadata: Codable {
        let id: MediaID
        let filename: String
        let mimeType: String
        let byteSize: Int64

        var reference: MediaReference {
            MediaReference(
                mediaID: id,
                filename: filename,
                mimeType: mimeType,
                byteSize: byteSize,
                source: .upload
            )
        }
    }

    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    public func save(_ upload: MediaUpload) async throws -> MediaReference {
        let directory = directory
        return try lock.withLock {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let id = try MediaID(validating: "upload_\(UUID().uuidString.lowercased())")
            let metadata = Metadata(
                id: id,
                filename: upload.filename,
                mimeType: upload.mimeType,
                byteSize: Int64(upload.data.count)
            )
            let itemDirectory = itemDirectoryURL(id)
            try FileManager.default.createDirectory(
                at: itemDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try upload.data.write(
                to: dataURL(id, filename: upload.filename),
                options: [.atomic, .completeFileProtection]
            )
            do {
                try RelayJSON.encoder.encode(metadata).write(to: metadataURL(id), options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: itemDirectory)
                throw error
            }
            return metadata.reference
        }
    }

    public func reference(id: MediaID) async throws -> MediaReference? {
        try lock.withLock { try load(id)?.reference }
    }

    public func readable(id: MediaID) async throws -> ReadableMedia? {
        try lock.withLock {
            guard let metadata = try load(id),
                  let opened = openRegularFile(
                      path: dataURL(id, filename: metadata.filename).path,
                      within: itemDirectoryURL(id)
                  ),
                  opened.byteCount == metadata.byteSize else { return nil }
            return ReadableMedia(
                reference: metadata.reference,
                descriptor: opened.descriptor,
                byteCount: opened.byteCount
            )
        }
    }

    public func outbound(id: MediaID) async throws -> OutboundMedia? {
        try lock.withLock {
            guard let metadata = try load(id) else { return nil }
            let url = dataURL(id, filename: metadata.filename)
            guard isRegularFile(url: url, within: itemDirectoryURL(id), byteSize: metadata.byteSize) else {
                return nil
            }
            return OutboundMedia(reference: metadata.reference, fileURL: url)
        }
    }

    private func load(_ id: MediaID) throws -> Metadata? {
        guard Self.isStoredUploadID(id) else { return nil }
        let url = metadataURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let metadata = try RelayJSON.decoder.decode(Metadata.self, from: Data(contentsOf: url))
        guard metadata.id == id else { return nil }
        return metadata
    }

    private func itemDirectoryURL(_ id: MediaID) -> URL {
        directory.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    private func dataURL(_ id: MediaID, filename: String) -> URL {
        itemDirectoryURL(id).appendingPathComponent(filename, isDirectory: false)
    }

    private func metadataURL(_ id: MediaID) -> URL {
        itemDirectoryURL(id).appendingPathComponent("metadata.json", isDirectory: false)
    }

    private func isRegularFile(url: URL, within parent: URL, byteSize: Int64) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL else {
            return false
        }
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0,
              (statBuffer.st_mode & S_IFMT) == S_IFREG,
              statBuffer.st_size == byteSize else { return false }
        return true
    }

    private static func isStoredUploadID(_ id: MediaID) -> Bool {
        let prefix = "upload_"
        guard id.rawValue.hasPrefix(prefix) else { return false }
        let suffix = String(id.rawValue.dropFirst(prefix.count))
        return UUID(uuidString: suffix) != nil
    }
}

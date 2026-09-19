import Foundation

public struct MediaPolicy: Equatable, Sendable {
    public let maximumBytes: Int64
    public let maximumFilenameBytes: Int

    public init(maximumBytes: Int64 = 25 * 1024 * 1024, maximumFilenameBytes: Int = 255) {
        self.maximumBytes = maximumBytes
        self.maximumFilenameBytes = maximumFilenameBytes
    }
}

public struct MediaService: Sendable {
    private let uploads: any UploadedMediaStoring
    private let messagesMedia: any MessageMediaStoring
    private let policy: MediaPolicy

    public init(
        uploads: any UploadedMediaStoring,
        messagesMedia: any MessageMediaStoring,
        policy: MediaPolicy = MediaPolicy()
    ) {
        self.uploads = uploads
        self.messagesMedia = messagesMedia
        self.policy = policy
    }

    public func upload(filename: String, mimeType: String, data: Data) async throws -> UploadMediaResponse {
        guard !data.isEmpty else {
            throw RelayServiceError.unsafeMedia("The media file is empty.")
        }
        guard Int64(data.count) <= policy.maximumBytes else {
            throw RelayServiceError.mediaTooLarge(maximumBytes: policy.maximumBytes)
        }
        let safeFilename = try validateFilename(filename)
        let safeMIME = try validateMIME(mimeType)
        let reference = try await uploads.save(
            MediaUpload(filename: safeFilename, mimeType: safeMIME, data: data)
        )
        return UploadMediaResponse(
            media: reference,
            downloadURL: "/v1/media/\(reference.mediaID.rawValue)?download=true"
        )
    }

    public func reference(id: MediaID) async throws -> MediaReference {
        if let uploaded = try await uploads.reference(id: id) { return uploaded }
        if let provider = try await messagesMedia.media(id: id)?.reference { return provider }
        throw RelayServiceError.unknownMedia
    }

    public func outbound(id: MediaID) async throws -> OutboundMedia {
        guard let uploaded = try await uploads.outbound(id: id) else {
            throw RelayServiceError.unknownMedia
        }
        return uploaded
    }

    public func readable(id: MediaID) async throws -> ReadableMedia {
        if let uploaded = try await uploads.readable(id: id) { return uploaded }
        if let provider = try await messagesMedia.media(id: id) { return provider }
        throw RelayServiceError.unknownMedia
    }

    private func validateFilename(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              trimmed.utf8.count <= policy.maximumFilenameBytes,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\""),
              !trimmed.contains(";"),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RelayServiceError.unsafeMedia("The filename is unsafe.")
        }
        return trimmed
    }

    private func validateMIME(_ value: String) throws -> String {
        let mime = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              mime.utf8.count <= 127,
              mime.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$&^_.+-/")).contains($0)
              }) else {
            throw RelayServiceError.unsafeMedia("The MIME type is invalid.")
        }
        let allowedTopLevels = Set(["image", "video", "audio", "text"])
        let allowedApplications = Set(["application/pdf", "application/octet-stream"])
        guard allowedTopLevels.contains(String(parts[0])) || allowedApplications.contains(mime) else {
            throw RelayServiceError.unsafeMedia("The MIME type is not allowed.")
        }
        return mime
    }
}

public enum MediaSource: String, Codable, Equatable, Sendable {
    case messages
    case upload
}

public struct MediaReference: Codable, Equatable, Sendable {
    public let mediaID: MediaID
    public let filename: String?
    public let mimeType: String?
    public let byteSize: Int64?
    public let source: MediaSource

    private enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case filename
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case source
    }

    public init(
        mediaID: MediaID,
        filename: String?,
        mimeType: String?,
        byteSize: Int64?,
        source: MediaSource
    ) {
        self.mediaID = mediaID
        self.filename = filename
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.source = source
    }
}

public struct UploadMediaResponse: Codable, Equatable, Sendable {
    public let media: MediaReference
    public let downloadURL: String

    private enum CodingKeys: String, CodingKey {
        case media
        case downloadURL = "download_url"
    }

    public init(media: MediaReference, downloadURL: String) {
        self.media = media
        self.downloadURL = downloadURL
    }
}

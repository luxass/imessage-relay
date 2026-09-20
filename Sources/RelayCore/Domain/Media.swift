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
    public let isSticker: Bool

    private enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case filename
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case source
        case isSticker = "is_sticker"
    }

    public init(
        mediaID: MediaID,
        filename: String?,
        mimeType: String?,
        byteSize: Int64?,
        source: MediaSource,
        isSticker: Bool = false
    ) {
        self.mediaID = mediaID
        self.filename = filename
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.source = source
        self.isSticker = isSticker
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mediaID: try container.decode(MediaID.self, forKey: .mediaID),
            filename: try container.decodeIfPresent(String.self, forKey: .filename),
            mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType),
            byteSize: try container.decodeIfPresent(Int64.self, forKey: .byteSize),
            source: try container.decode(MediaSource.self, forKey: .source),
            isSticker: try container.decodeIfPresent(Bool.self, forKey: .isSticker) ?? false
        )
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

public struct Attachment: Codable, Sendable {
    /// Path on disk as recorded by Messages (may be missing from disk).
    public var filename: String
    public var transferName: String
    public var mimeType: String
    public var uti: String
    public var totalBytes: Int64
    public var isSticker: Bool
    public var originalPath: String?
    /// True when the backing file no longer exists on disk.
    public var missing: Bool

    enum CodingKeys: String, CodingKey {
        case filename
        case transferName = "transfer_name"
        case mimeType = "mime_type"
        case uti
        case totalBytes = "total_bytes"
        case isSticker = "is_sticker"
        case originalPath = "original_path"
        case missing
    }

    public init(
        filename: String,
        transferName: String,
        mimeType: String,
        uti: String,
        totalBytes: Int64,
        isSticker: Bool,
        originalPath: String?,
        missing: Bool
    ) {
        self.filename = filename
        self.transferName = transferName
        self.mimeType = mimeType
        self.uti = uti
        self.totalBytes = totalBytes
        self.isSticker = isSticker
        self.originalPath = originalPath
        self.missing = missing
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(filename, forKey: .filename)
        try c.encode(transferName, forKey: .transferName)
        try c.encode(mimeType, forKey: .mimeType)
        try c.encode(uti, forKey: .uti)
        try c.encode(totalBytes, forKey: .totalBytes)
        try c.encode(isSticker, forKey: .isSticker)
        if let originalPath {
            try c.encode(originalPath, forKey: .originalPath)
        }
        try c.encode(missing, forKey: .missing)
    }
}

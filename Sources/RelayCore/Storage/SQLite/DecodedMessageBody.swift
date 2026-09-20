import AttributedBodyBridge
import Foundation

struct DecodedMessageBody: Sendable {
    struct Part: Sendable {
        let index: Int
        var text: String?
        var attachmentGUID: String?
    }

    let text: String?
    let parts: [Part]

    init?(_ data: Data?) {
        guard let data,
              let attributed = RelayDecodeLegacyAttributedBody(data) else { return nil }
        let plainText = attributed.string
            .replacingOccurrences(of: "\u{fffc}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = plainText.isEmpty ? nil : plainText

        let partKey = NSAttributedString.Key("__kIMMessagePartAttributeName")
        let transferKey = NSAttributedString.Key("__kIMFileTransferGUIDAttributeName")
        var decodedParts: [Int: Part] = [:]
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, range, _ in
            guard let index = Self.partIndex(attributes[partKey]), index >= 0 else { return }
            let raw = (attributed.string as NSString).substring(with: range)
            let partText = raw.replacingOccurrences(of: "\u{fffc}", with: "")
            let transferGUID = attributes[transferKey] as? String
            var part = decodedParts[index] ?? Part(
                index: index,
                text: nil,
                attachmentGUID: nil
            )
            if !partText.isEmpty { part.text = (part.text ?? "") + partText }
            if let transferGUID, !transferGUID.isEmpty { part.attachmentGUID = transferGUID }
            decodedParts[index] = part
        }
        parts = decodedParts.keys.sorted().compactMap { decodedParts[$0] }
    }

    private static func partIndex(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

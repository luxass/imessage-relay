import Foundation

enum MessagesAccessibilityDeepLink {
    static func conversation(guid: String) throws -> URL {
        let components = guid.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3 else {
            throw AccessibilityDriverFailure("The conversation GUID has an unsupported format.")
        }
        switch components[1] {
        case "-": return try url(queryName: "address", value: String(components[2]))
        case "+": return try url(queryName: "groupid", value: String(components[2]))
        default: throw AccessibilityDriverFailure("The conversation GUID has an unsupported chat type.")
        }
    }

    static func reply(messageGUID: String, useOverlay: Bool) throws -> URL {
        guard !messageGUID.isEmpty, !messageGUID.contains("_") else {
            throw AccessibilityDriverFailure("The reply message GUID is invalid.")
        }
        return try url(
            queryName: "message-guid",
            value: messageGUID,
            additionalItems: useOverlay
                ? [URLQueryItem(name: "overlay", value: "1")]
                : []
        )
    }

    private static func url(
        queryName: String,
        value: String,
        additionalItems: [URLQueryItem] = []
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "imessage"
        components.path = "open"
        components.queryItems = [URLQueryItem(name: queryName, value: value)] + additionalItems
        guard let url = components.url else {
            throw AccessibilityDriverFailure("Could not build the Messages deep link.")
        }
        return url
    }
}

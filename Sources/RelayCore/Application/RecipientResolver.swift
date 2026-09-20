public enum RecipientResolutionError: Error, Equatable, Sendable {
    case ambiguous(String)
    case contactsUnavailable
    case notFound(String)
}

public protocol RecipientResolving: Sendable {
    func resolve(_ candidate: RecipientHandle) async throws -> RecipientHandle
}

public struct DirectRecipientResolver: RecipientResolving {
    public init() {}

    public func resolve(_ candidate: RecipientHandle) async throws -> RecipientHandle {
        guard candidate.type != .other else {
            throw RecipientResolutionError.notFound(candidate.value)
        }
        return candidate
    }
}

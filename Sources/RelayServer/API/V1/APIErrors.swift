import Hummingbird
import NIOCore
import RelayCore

struct APIHTTPError: Error, Sendable {
    let status: HTTPResponse.Status
    let code: APIErrorCode
    let message: String
    let fieldDetails: [APIFieldError]?

    init(
        status: HTTPResponse.Status,
        code: APIErrorCode,
        message: String,
        fieldDetails: [APIFieldError]? = nil
    ) {
        self.status = status
        self.code = code
        self.message = message
        self.fieldDetails = fieldDetails
    }
}

struct APIErrorMiddleware: RouterMiddleware {
    func handle(
        _ request: Request,
        context: RelayRequestContext,
        next: (Request, RelayRequestContext) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch {
            return try response(for: error, context: context)
        }
    }

    private func response(for error: Error, context: RelayRequestContext) throws -> Response {
        let mapped: APIHTTPError
        if let error = error as? APIHTTPError {
            mapped = error
        } else if let error = error as? RelayServiceError {
            mapped = map(error)
        } else if let error = error as? SQLiteStorageError {
            mapped = map(error, context: context)
        } else if error is RecipientHandle.ValidationError {
            mapped = APIHTTPError(
                status: .unprocessableContent,
                code: .invalidDestination,
                message: "The recipient handle is invalid."
            )
        } else if error is IdentifierValidationError {
            mapped = APIHTTPError(
                status: .badRequest,
                code: .invalidRequest,
                message: "The resource identifier is invalid."
            )
        } else if error is SendMessageRequest.ValidationError || error is DecodingError {
            mapped = APIHTTPError(
                status: .badRequest,
                code: .malformedJSON,
                message: "The JSON request is invalid."
            )
        } else if error is NIOTooManyBytesError {
            mapped = APIHTTPError(
                status: .contentTooLarge,
                code: .mediaTooLarge,
                message: "The media file is too large."
            )
        } else if let error = error as? HTTPError {
            let code: APIErrorCode = error.status == .notFound ? .notFound : .invalidRequest
            mapped = APIHTTPError(
                status: error.status,
                code: code,
                message: error.body ?? error.status.reasonPhrase
            )
        } else {
            context.logger.error("Unhandled API error", metadata: ["error": "\(error)"])
            mapped = APIHTTPError(
                status: .internalServerError,
                code: .internalError,
                message: "The request failed."
            )
        }
        return try errorResponse(mapped, context: context)
    }

    private func map(_ error: SQLiteStorageError, context: RelayRequestContext) -> APIHTTPError {
        switch error {
        case .invalidCursor:
            APIHTTPError(status: .badRequest, code: .invalidCursor, message: error.description)
        case .cannotOpen, .incompatibleSchema, .shutDown:
            APIHTTPError(status: .serviceUnavailable, code: .databaseUnavailable, message: error.description)
        case .queryFailed, .corruptValue:
            APIHTTPError(
                status: .serviceUnavailable,
                code: .databaseUnavailable,
                message: "The Messages database request failed."
            )
        }
    }

    private func errorResponse(
        _ error: APIHTTPError,
        context: RelayRequestContext
    ) throws -> Response {
        try jsonResponse(
            APIError(
                code: error.code,
                message: error.message,
                requestID: context.requestID,
                fieldDetails: error.fieldDetails
            ),
            status: error.status,
            requestID: context.requestID
        )
    }

    // An exhaustive transport mapping is clearer than scattering status codes across services.
    // swiftlint:disable:next cyclomatic_complexity
    private func map(_ error: RelayServiceError) -> APIHTTPError {
        switch error {
        case .invalidDestination(let fields):
            APIHTTPError(
                status: .unprocessableContent,
                code: .invalidDestination,
                message: "The destination is invalid.",
                fieldDetails: fields
            )
        case .ambiguousDestination:
            APIHTTPError(status: .badRequest, code: .ambiguousDestination, message: "Provide exactly one destination.")
        case .ambiguousConversation:
            APIHTTPError(
                status: .conflict,
                code: .ambiguousConversation,
                message: "More than one conversation has exactly these participants. Use conversation_id."
            )
        case .disallowedRecipient:
            APIHTTPError(status: .forbidden, code: .disallowedRecipient, message: "One or more recipients are not allowlisted.")
        case .unknownConversation:
            APIHTTPError(status: .notFound, code: .unknownConversation, message: "The conversation was not found.")
        case .unknownMessage:
            APIHTTPError(status: .notFound, code: .unknownMessage, message: "The message was not found.")
        case .unknownMedia:
            APIHTTPError(status: .notFound, code: .unknownMedia, message: "The media item was not found.")
        case .unknownRequest:
            APIHTTPError(status: .notFound, code: .unknownRequest, message: "The send request was not found.")
        case .unsupportedCapability(let detail):
            APIHTTPError(status: .notImplemented, code: .unsupportedCapability, message: detail)
        case .senderUnavailable(let detail):
            APIHTTPError(status: .serviceUnavailable, code: .senderUnavailable, message: detail)
        case .databaseUnavailable(let detail):
            APIHTTPError(status: .serviceUnavailable, code: .databaseUnavailable, message: detail)
        case .invalidCursor:
            APIHTTPError(status: .badRequest, code: .invalidCursor, message: "The cursor is invalid or does not match this request.")
        case .unsafeMedia(let detail):
            APIHTTPError(status: .unprocessableContent, code: .unsafeMedia, message: detail)
        case .mediaTooLarge(let maximumBytes):
            APIHTTPError(status: .contentTooLarge, code: .mediaTooLarge, message: "Media must not exceed \(maximumBytes) bytes.")
        case .duplicateRequest(let requestID):
            APIHTTPError(
                status: .conflict,
                code: .duplicateRequest,
                message: "This idempotency key belongs to request \(requestID.rawValue)."
            )
        case .invalidRequest(let fields):
            APIHTTPError(
                status: .unprocessableContent,
                code: .invalidRequest,
                message: "The request is invalid.",
                fieldDetails: fields
            )
        case .uncertainSend(let detail):
            APIHTTPError(status: .badGateway, code: .sendResultUnknown, message: detail)
        case .uncertainReaction(let detail):
            APIHTTPError(status: .badGateway, code: .reactionResultUnknown, message: detail)
        case .uncertainRead(let detail):
            APIHTTPError(status: .badGateway, code: .readResultUnknown, message: detail)
        case .messagesUnavailable(let detail):
            APIHTTPError(status: .serviceUnavailable, code: .messagesUnavailable, message: detail)
        case .typingConflict(let detail):
            APIHTTPError(status: .conflict, code: .typingConflict, message: detail)
        case .uncertainTyping(let detail):
            APIHTTPError(status: .badGateway, code: .typingResultUnknown, message: detail)
        case .requestTrackingUnavailable(let detail):
            APIHTTPError(status: .serviceUnavailable, code: .requestTrackingUnavailable, message: detail)
        }
    }
}

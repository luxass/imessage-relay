import Foundation
import Hummingbird
import HummingbirdOpenAPI
import RelayCore

struct MessageRoutes {
    let messages: MessageService
    let reactions: ReactionService

    static let idempotencyKey = StringHeader(
        "Idempotency-Key", description: "Reuse this key for the same logical send. See the retry rules in the API reference."
    )

    func register(on router: Router<RelayRequestContext>, jsonRoutes: JSONRoutes<RelayRequestContext>) {
        router.get("/v1/messages/:message_id", use: get)
        router.get("/v1/requests/:request_id", use: getRequest)
        Self.registerSend(on: jsonRoutes, use: send)
        router.put("/v1/messages/:message_id/reaction", use: setReaction)
        router.delete("/v1/messages/:message_id/reaction", use: clearReaction)
    }

    static func registerSend(
        on routes: JSONRoutes<RelayRequestContext>,
        use handler: @escaping @Sendable (MessageSubmission, Request, RelayRequestContext) async throws -> SendReceiptPayload
    ) {
        routes.post(
            "/v1/messages",
            info: .init(
                operationID: "sendMessage", summary: "Send a message", tag: "Messages",
                anchor: "send-a-message", headers: [idempotencyKey]
            ),
            status: .accepted,
            maximumBodyBytes: { $0.maxUploadSize },
            use: handler
        )
    }

    @Sendable private func setReaction(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> Response {
        let messageID = try MessageID(validating: pathValue("message_id", context: context))
        let body = try await request.body.collect(upTo: context.maxUploadSize)
        let payload: SetReactionRequest
        do {
            payload = try RelayJSON.decoder.decode(
                SetReactionRequest.self,
                from: Data(body.readableBytesView)
            )
        } catch SetReactionRequest.ValidationError.invalidReaction {
            throw RelayServiceError.invalidRequest([
                APIFieldError(
                    field: "reaction",
                    message: "Use love, like, dislike, laugh, emphasis, or question."
                )
            ])
        }
        return try jsonResponse(
            try await reactions.set(
                messageID: messageID,
                request: payload,
                requestID: context.requestID
            ),
            requestID: context.requestID
        )
    }

    @Sendable private func clearReaction(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> Response {
        let messageID = try MessageID(validating: pathValue("message_id", context: context))
        return try jsonResponse(
            try await reactions.clear(messageID: messageID, requestID: context.requestID),
            requestID: context.requestID
        )
    }

    @Sendable private func getRequest(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> Response {
        let raw = try pathValue("request_id", context: context)
        let id = try RequestID(validating: raw)
        return try jsonResponse(try await messages.request(id: id), requestID: context.requestID)
    }

    @Sendable private func get(_ request: Request, context: RelayRequestContext) async throws -> Response {
        let raw = try pathValue("message_id", context: context)
        let id = try MessageID(validating: raw)
        return try jsonResponse(try await messages.get(id: id), requestID: context.requestID)
    }

    @Sendable private func send(
        _ submission: MessageSubmission,
        request: Request,
        context: RelayRequestContext
    ) async throws -> SendReceiptPayload {
        let payload: SendMessageRequest
        do {
            payload = try submission.validated()
        } catch SendMessageRequest.ValidationError.ambiguousDestination {
            throw RelayServiceError.ambiguousDestination
        } catch SendMessageRequest.ValidationError.missingDestination {
            throw RelayServiceError.invalidDestination([
                APIFieldError(field: "destination", message: "Provide conversation_id, to, or participants.")
            ])
        } catch SendMessageRequest.ValidationError.invalidParticipantCount {
            throw RelayServiceError.invalidDestination([
                APIFieldError(field: "participants", message: "Provide at least two participants.")
            ])
        } catch SendMessageRequest.ValidationError.duplicateParticipant(let index) {
            throw RelayServiceError.invalidDestination([
                APIFieldError(
                    field: "participants[\(index)]",
                    message: "Each normalized participant must be unique."
                )
            ])
        } catch SendMessageRequest.ValidationError.unsupportedFields(let fields) {
            throw RelayServiceError.invalidRequest(fields.map {
                APIFieldError(field: $0, message: "This field is not supported.")
            })
        }
        let result = try await messages.send(
            payload,
            requestID: context.requestID,
            idempotencyKey: Self.idempotencyKey.value(in: request)
        )
        return SendReceiptPayload(result)
    }
}

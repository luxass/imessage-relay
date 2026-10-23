import Foundation
import Hummingbird
import HummingbirdOpenAPI
import RelayCore

struct MessageRoutes {
    let messages: MessageService
    let reactions: ReactionService

    func register(on router: Router<RelayRequestContext>) {
        Self.getEndpoint.register(on: router, use: get)
        Self.requestEndpoint.register(on: router, use: getRequest)
        Self.sendEndpoint.register(on: router, use: send)
        Self.setReactionEndpoint.register(on: router, use: setReaction)
        Self.clearReactionEndpoint.register(on: router, use: clearReaction)
    }

    @Sendable private func setReaction(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> JSONResponse<ReactionWriteResponse> {
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
        return relayJSONResponse(
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
    ) async throws -> JSONResponse<ReactionWriteResponse> {
        let messageID = try MessageID(validating: pathValue("message_id", context: context))
        return relayJSONResponse(
            try await reactions.clear(messageID: messageID, requestID: context.requestID),
            requestID: context.requestID
        )
    }

    @Sendable private func getRequest(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> JSONResponse<SendMessageResponse> {
        let raw = try pathValue("request_id", context: context)
        let id = try RequestID(validating: raw)
        return relayJSONResponse(try await messages.request(id: id), requestID: context.requestID)
    }

    @Sendable private func get(_ request: Request, context: RelayRequestContext) async throws -> JSONResponse<Message> {
        let raw = try pathValue("message_id", context: context)
        let id = try MessageID(validating: raw)
        return relayJSONResponse(try await messages.get(id: id), requestID: context.requestID)
    }

    @Sendable private func send(_ request: Request, context: RelayRequestContext) async throws -> JSONResponse<SendMessageResponse> {
        let body = try await request.body.collect(upTo: context.maxUploadSize)
        let payload: SendMessageRequest
        do {
            payload = try RelayJSON.decoder.decode(
                SendMessageRequest.self,
                from: Data(body.readableBytesView)
            )
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
            idempotencyKey: request.headers[.init("idempotency-key")!]
        )
        return relayJSONResponse(result, status: .accepted, requestID: context.requestID)
    }
}

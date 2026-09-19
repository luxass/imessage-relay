import Foundation
import Hummingbird
import NIOCore
import RelayCore

struct EventRoutes {
    let database: any DatabaseStatusProviding
    let events: EventService
    let heartbeatInterval: Duration

    init(
        database: any DatabaseStatusProviding,
        events: EventService,
        heartbeatInterval: Duration = .seconds(15)
    ) {
        self.database = database
        self.events = events
        self.heartbeatInterval = heartbeatInterval
    }

    func register(on router: Router<RelayRequestContext>) {
        router.get("/v1/events", use: stream)
    }

    @Sendable private func stream(_ request: Request, context: RelayRequestContext) async throws -> Response {
        if request.headers[.init("last-event-id")!] != nil {
            throw APIHTTPError(
                status: .badRequest,
                code: .invalidRequest,
                message: "Event replay is not supported. Reconnect without Last-Event-ID and refetch REST resources."
            )
        }
        let databaseStatus = await database.databaseStatus()
        guard databaseStatus.ready else {
            throw RelayServiceError.databaseUnavailable(
                databaseStatus.error ?? "The Messages database is unavailable."
            )
        }
        let eventStream = await events.events()
        let heartbeatInterval = heartbeatInterval
        let body = ResponseBody { writer in
            try await writer.write(ByteBuffer(string: "retry: 3000\n\n"))
            let coordinator = SSEWriteCoordinator()
            let eventTask = Task {
                for await event in eventStream {
                    await coordinator.send(.event(event))
                }
                await coordinator.finish()
            }
            let heartbeatTask = Task {
                do {
                    while !Task.isCancelled {
                        try await ContinuousClock().sleep(for: heartbeatInterval)
                        await coordinator.offerHeartbeat()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await coordinator.finish()
                }
            }

            do {
                while let item = await coordinator.next() {
                    switch item {
                    case .event(let event):
                        try await writer.write(ByteBuffer(string: try serverSentEventFrame(event)))
                    case .heartbeat:
                        try await writer.write(ByteBuffer(string: ": keep-alive\n\n"))
                    }
                }
                eventTask.cancel()
                heartbeatTask.cancel()
                await coordinator.cancel()
                try await writer.finish(nil)
            } catch {
                eventTask.cancel()
                heartbeatTask.cancel()
                await coordinator.cancel()
                throw error
            }
        }
        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream; charset=utf-8",
                .init("cache-control")!: "no-cache",
                .init("x-accel-buffering")!: "no",
                .init("x-request-id")!: context.requestID.rawValue,
            ],
            body: body
        )
    }
}

func serverSentEventFrame(_ event: RelayEvent) throws -> String {
    let data = try RelayJSON.encoder.encode(event.payload)
    guard let json = String(data: data, encoding: .utf8) else {
        throw EncodingError.invalidValue(
            event,
            EncodingError.Context(codingPath: [], debugDescription: "The event payload is not UTF-8 JSON.")
        )
    }
    return "event: \(event.type.rawValue)\ndata: \(json)\n\n"
}

private actor SSEWriteCoordinator {
    enum Item: Sendable {
        case event(RelayEvent)
        case heartbeat
    }

    private var waitingConsumer: CheckedContinuation<Item?, Never>?
    private var pending: (Item, CheckedContinuation<Void, Never>)?
    private var isFinished = false

    func send(_ item: Item) async {
        await withCheckedContinuation { continuation in
            guard !isFinished else {
                continuation.resume()
                return
            }
            if let consumer = waitingConsumer {
                waitingConsumer = nil
                consumer.resume(returning: item)
                continuation.resume()
            } else {
                precondition(pending == nil, "The SSE event producer must send serially.")
                pending = (item, continuation)
            }
        }
    }

    func offerHeartbeat() {
        guard !isFinished, pending == nil, let consumer = waitingConsumer else { return }
        waitingConsumer = nil
        consumer.resume(returning: .heartbeat)
    }

    func next() async -> Item? {
        if let pending {
            self.pending = nil
            pending.1.resume()
            return pending.0
        }
        guard !isFinished else { return nil }
        return await withCheckedContinuation { waitingConsumer = $0 }
    }

    func finish() {
        isFinished = true
        guard pending == nil, let consumer = waitingConsumer else { return }
        waitingConsumer = nil
        consumer.resume(returning: nil)
    }

    func cancel() {
        isFinished = true
        if let pending {
            self.pending = nil
            pending.1.resume()
        }
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            consumer.resume(returning: nil)
        }
    }
}

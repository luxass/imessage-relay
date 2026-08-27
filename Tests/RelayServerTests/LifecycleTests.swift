import Foundation
import RelayCore
import XCTest

@testable import relay_server

final class LifecycleTests: XCTestCase {
    func testCancellationBeforeLaunchDoesNotCreateProcess() async {
        let state = FakeProcessState()
        let runner = FoundationSendProcessRunner { _, _ in
            state.markCreated()
            return FakeProcess(state: state)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(
                executablePath: "/never/launched",
                arguments: [],
                timeout: .seconds(1),
                terminationGrace: .milliseconds(10)
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(state.created)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationTerminatesThenEscalatesFakeProcess() async throws {
        let state = FakeProcessState()
        let runner = FoundationSendProcessRunner { _, _ in FakeProcess(state: state) }
        let task = Task {
            try await runner.run(
                executablePath: "/fake/process",
                arguments: [],
                timeout: .seconds(10),
                terminationGrace: .milliseconds(10)
            )
        }
        while !state.launched { await Task.yield() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(state.events, ["run", "terminate", "kill"])
        }
    }

    func testMessageStoreServiceShutsDownWhenCancelled() async {
        let store = MessageStore(path: "/synthetic/unavailable/chat.db")
        let task = Task { try await MessageStoreService(store: store).run() }
        await Task.yield()
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            do {
                _ = try await store.chats()
                XCTFail("Expected the store executor to be shut down")
            } catch {
                // A shut down NIO thread pool rejects the operation.
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPreCancelledMessageStoreServiceStillShutsDown() async {
        let store = MessageStore(path: "/synthetic/unavailable/chat.db")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MessageStoreService(store: store).run()
        }

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            do {
                _ = try await store.chats()
                XCTFail("Expected the store executor to be shut down")
            } catch is MessageStore.StoreError {
                // The cancelled service awaited detached cleanup before returning.
            } catch {
                XCTFail("Unexpected operation error: \(error)")
            }
        } catch {
            XCTFail("Unexpected service error: \(error)")
        }
    }
}

private final class FakeProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []
    private var storedCreated = false
    private var running = false

    var events: [String] { lock.withLock { storedEvents } }
    var created: Bool { lock.withLock { storedCreated } }
    var launched: Bool { lock.withLock { storedEvents.contains("run") } }
    var isRunning: Bool { lock.withLock { running } }

    func markCreated() { lock.withLock { storedCreated = true } }
    func run() { lock.withLock { storedEvents.append("run"); running = true } }
    func terminate() { lock.withLock { storedEvents.append("terminate") } }
    func kill() { lock.withLock { storedEvents.append("kill"); running = false } }
}

private struct FakeProcess: SendProcess {
    let state: FakeProcessState

    var isRunning: Bool { state.isRunning }
    var terminationStatus: Int32 { 0 }
    func run() throws { state.run() }
    func terminate() { state.terminate() }
    func forceKill() { state.kill() }
}

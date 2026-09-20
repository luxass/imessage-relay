import Foundation
import NIOPosix

final class SQLiteExecutor: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var database: SQLiteDatabase?
        var shutdownTask: Task<Void, Error>?
    }

    let path: String
    private let pool: NIOThreadPool
    private let state = State()

    init(path: String) {
        self.path = path
        pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
    }

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable (SQLiteDatabase) throws -> Value
    ) async throws -> Value {
        let capturedState = state
        try capturedState.lock.withLock {
            if capturedState.shutdownTask != nil { throw SQLiteStorageError.shutDown }
        }
        let capturedPath = path
        return try await pool.runIfActive {
            let database: SQLiteDatabase
            if let existing = capturedState.database {
                database = existing
            } else {
                database = try SQLiteDatabase(path: capturedPath)
                capturedState.database = database
            }
            return try operation(database)
        }
    }

    func resetDatabase() async throws {
        let capturedState = state
        try capturedState.lock.withLock {
            if capturedState.shutdownTask != nil { throw SQLiteStorageError.shutDown }
        }
        try await pool.runIfActive {
            capturedState.database = nil
        }
    }

    func shutdown() async throws {
        let task = state.lock.withLock { () -> Task<Void, Error> in
            if let existing = state.shutdownTask { return existing }
            let capturedPool = pool
            let capturedState = state
            let task = Task.detached {
                try await capturedPool.runIfActive { capturedState.database = nil }
                try await capturedPool.shutdownGracefully()
            }
            capturedState.shutdownTask = task
            return task
        }
        try await task.value
    }
}

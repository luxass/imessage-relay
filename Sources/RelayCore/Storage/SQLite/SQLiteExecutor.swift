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
        try state.lock.withLock {
            if state.shutdownTask != nil { throw SQLiteStorageError.shutDown }
        }
        let path = path
        let state = state
        return try await pool.runIfActive {
            let database: SQLiteDatabase
            if let existing = state.database {
                database = existing
            } else {
                database = try SQLiteDatabase(path: path)
                state.database = database
            }
            return try operation(database)
        }
    }

    func shutdown() async throws {
        let task = state.lock.withLock { () -> Task<Void, Error> in
            if let existing = state.shutdownTask { return existing }
            let pool = pool
            let state = state
            let task = Task.detached {
                try await pool.runIfActive { state.database = nil }
                try await pool.shutdownGracefully()
            }
            state.shutdownTask = task
            return task
        }
        try await task.value
    }
}

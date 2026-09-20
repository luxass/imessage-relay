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
            var postOperationRetries = 0
            while true {
                let database: SQLiteDatabase
                if let existing = capturedState.database {
                    do {
                        if try existing.isCurrentGeneration() {
                            database = existing
                        } else {
                            capturedState.database = nil
                            let reopened = try SQLiteDatabase(path: capturedPath)
                            capturedState.database = reopened
                            database = reopened
                        }
                    } catch {
                        capturedState.database = nil
                        throw error
                    }
                } else {
                    let opened = try SQLiteDatabase(path: capturedPath)
                    capturedState.database = opened
                    database = opened
                }

                let result: Result<Value, Error>
                do {
                    result = .success(try operation(database))
                } catch {
                    result = .failure(error)
                }

                let generation: Result<Bool, Error>
                do {
                    generation = .success(try database.isCurrentGeneration())
                } catch {
                    generation = .failure(error)
                }
                switch generation {
                case .success(true):
                    return try result.get()
                case .success(false):
                    capturedState.database = nil
                    guard postOperationRetries == 0 else {
                        throw SQLiteStorageError.cannotOpen(
                            "Database changed repeatedly during one logical read."
                        )
                    }
                    postOperationRetries += 1
                case .failure(let error):
                    capturedState.database = nil
                    guard postOperationRetries == 0 else { throw error }
                    postOperationRetries += 1
                }
            }
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

import Foundation
import RelayCore

/// Opens the Messages database lazily and retries while unavailable, so the
/// server boots even without Full Disk Access and recovers once permission is
/// granted mid-flight. `/status` reports the failure; other routes get a
/// thrown error which the route layer maps to 503.
final class StoreProvider: @unchecked Sendable {
    let path: String

    private let lock = NSLock()
    private var store: MessageStore?

    init(path: String) {
        self.path = path
    }

    func withStore<T>(_ body: (MessageStore) throws -> T) throws -> T {
        try body(resolvedStore())
    }

    private func resolvedStore() throws -> MessageStore {
        lock.lock()
        defer { lock.unlock() }
        if let store {
            return store
        }
        let opened = try MessageStore(path: path)
        store = opened
        return opened
    }

    func status() -> DatabaseStatus {
        do {
            return try resolvedStore().status()
        } catch {
            return .init(
                ready: false,
                path: path,
                fingerprint: "",
                error: "\(error). Grant Full Disk Access to the process running this server."
            )
        }
    }
}

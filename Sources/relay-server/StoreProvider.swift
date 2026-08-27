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
        lock.lock()
        defer { lock.unlock() }
        if store == nil {
            store = try MessageStore(path: path)
        }
        return try body(store!)
    }

    func status() -> DatabaseStatus {
        do {
            _ = try withStore { try $0.status() }
            return store!.status()
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

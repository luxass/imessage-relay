public final class AccessibilityOperationQueue: Sendable {
    private let gate = AccessibilityOperationGate()

    public init(label _: String = "imessage-relay.accessibility-operation") {}

    public func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        await gate.acquire()
        do {
            let result = try await operation()
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }
}

private actor AccessibilityOperationGate {
    private var available = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available {
            available = false
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available = true
        } else {
            waiters.removeFirst().resume()
        }
    }
}

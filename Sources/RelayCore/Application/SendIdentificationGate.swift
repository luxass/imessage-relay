public final class SendIdentificationGate: Sendable {
    private let state = SendIdentificationGateState()

    public init() {}

    public func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        await state.acquire()
        do {
            let value = try await operation()
            await state.release()
            return value
        } catch {
            await state.release()
            throw error
        }
    }
}

private actor SendIdentificationGateState {
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

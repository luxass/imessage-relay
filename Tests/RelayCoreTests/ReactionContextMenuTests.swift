import Testing

@testable import RelayCore

enum ReactionMenuTestFailure: Error, Equatable, Sendable {
    case open
    case missingTapback
    case lookup
    case timeout
}

@Test
@MainActor
func reactionContextMenuDismissesAfterSuccessfulOperation() async throws {
    var steps: [String] = []
    try await MacOSAccessibilityMessagesDriver.withReactionContextMenu(
        open: { steps.append("open") },
        dismiss: { steps.append("dismiss") },
        operation: {
            steps.append("lookup")
            steps.append("press")
        }
    )
    #expect(steps == ["open", "lookup", "press", "dismiss"])
}

@Test(arguments: [ReactionMenuTestFailure.missingTapback, .lookup, .timeout])
@MainActor
func reactionContextMenuDismissesAndPreservesLookupFailures(failure: ReactionMenuTestFailure) async {
    var steps: [String] = []
    await #expect(throws: failure) {
        try await MacOSAccessibilityMessagesDriver.withReactionContextMenu(
            open: { steps.append("open") },
            dismiss: { steps.append("dismiss") },
            operation: {
                steps.append("lookup")
                throw failure
            }
        )
    }
    #expect(steps == ["open", "lookup", "dismiss"])
}

@Test
@MainActor
func reactionContextMenuDoesNotDismissWhenOpeningFails() async {
    var steps: [String] = []
    await #expect(throws: ReactionMenuTestFailure.open) {
        try await MacOSAccessibilityMessagesDriver.withReactionContextMenu(
            open: {
                steps.append("open")
                throw ReactionMenuTestFailure.open
            },
            dismiss: { steps.append("dismiss") },
            operation: {
                steps.append("lookup")
            }
        )
    }
    #expect(steps == ["open"])
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func reactionContextMenuDismissesDuringTaskCancellation() async throws {
    var steps: [String] = []
    var cleanupObservedCancellation = false
    let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let operation = Task { @MainActor in
        defer { signal.continuation.finish() }
        try await MacOSAccessibilityMessagesDriver.withReactionContextMenu(
            open: { steps.append("open") },
            dismiss: {
                steps.append("dismiss")
                cleanupObservedCancellation = Task.isCancelled
            },
            operation: {
                steps.append("lookup")
                signal.continuation.yield(())
                try await Task.sleep(for: .seconds(10))
                steps.append("press")
            }
        )
    }
    defer { operation.cancel() }
    var readiness = signal.stream.makeAsyncIterator()
    _ = try #require(await readiness.next())
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(steps == ["open", "lookup", "dismiss"])
    #expect(cleanupObservedCancellation)
}

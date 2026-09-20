import Foundation
import Testing

@testable import RelayCore

@Test
func accessibilityDeepLinksUseStableConversationAndMessageIdentifiers() throws {
    let direct = try MessagesAccessibilityDeepLink.conversation(
        guid: "any;-;friend+relay@example.com"
    )
    let group = try MessagesAccessibilityDeepLink.conversation(
        guid: "iMessage;+;chat123456789"
    )
    let reply = try MessagesAccessibilityDeepLink.reply(
        messageGUID: "MESSAGE-GUID",
        useOverlay: false
    )

    #expect(queryItems(direct) == ["address": "friend+relay@example.com"])
    #expect(queryItems(group) == ["groupid": "chat123456789"])
    #expect(queryItems(reply) == ["message-guid": "MESSAGE-GUID"])
    #expect(direct.scheme == "imessage")
    #expect(direct.path == "open")
    #expect(direct.host == nil)
}

@Test
func accessibilityDeepLinksRejectUnknownChatShapesAndDerivedMessageIDs() {
    #expect(throws: (any Error).self) {
        try MessagesAccessibilityDeepLink.conversation(guid: "not-a-chat-guid")
    }
    #expect(throws: (any Error).self) {
        try MessagesAccessibilityDeepLink.conversation(guid: "iMessage;?;chat")
    }
    #expect(throws: (any Error).self) {
        try MessagesAccessibilityDeepLink.reply(messageGUID: "part_derived_guid", useOverlay: true)
    }
}

@Test
func replyTranscriptDetectionIgnoresLocalizedDescriptions() {
    let normalPlaceholders: Set<String> = ["iMessage", "Text Message"]
    let english = MessagesTranscriptSnapshot(
        transcriptIdentifier: "TranscriptCollectionView",
        transcriptDescription: "Reply transcript",
        composerIdentifier: "messageBodyField",
        composerPlaceholder: "Reply",
        composerIsFocused: true
    )
    let danish = MessagesTranscriptSnapshot(
        transcriptIdentifier: "TranscriptCollectionView",
        transcriptDescription: "Transskription af svar",
        composerIdentifier: "messageBodyField",
        composerPlaceholder: "Svar",
        composerIsFocused: true
    )

    #expect(isReplyTranscript(english, normalComposerPlaceholders: normalPlaceholders))
    #expect(isReplyTranscript(danish, normalComposerPlaceholders: normalPlaceholders))
}

@Test
func replyTranscriptDetectionRequiresFocusedReplyComposer() {
    let normalPlaceholders: Set<String> = ["iMessage", "Text Message"]
    let normalTranscript = MessagesTranscriptSnapshot(
        transcriptIdentifier: "TranscriptCollectionView",
        transcriptDescription: "Messages",
        composerIdentifier: "messageBodyField",
        composerPlaceholder: "iMessage",
        composerIsFocused: true
    )
    let unfocusedReply = MessagesTranscriptSnapshot(
        transcriptIdentifier: "TranscriptCollectionView",
        transcriptDescription: "Reply transcript",
        composerIdentifier: "messageBodyField",
        composerPlaceholder: "Reply",
        composerIsFocused: false
    )
    let wrongTranscript = MessagesTranscriptSnapshot(
        transcriptIdentifier: "ConversationList",
        transcriptDescription: "Reply transcript",
        composerIdentifier: "messageBodyField",
        composerPlaceholder: "Reply",
        composerIsFocused: true
    )

    #expect(!isReplyTranscript(normalTranscript, normalComposerPlaceholders: normalPlaceholders))
    #expect(!isReplyTranscript(unfocusedReply, normalComposerPlaceholders: normalPlaceholders))
    #expect(!isReplyTranscript(wrongTranscript, normalComposerPlaceholders: normalPlaceholders))
}

@Test
func accessibilityActionMatchingAcceptsLocalizedTitlesExactly() {
    let actions = [
        "AXPress",
        "Name:Svar…\nTarget:0x0\nSelector:(null)",
        "Name:Tapback\nTarget:0x0\nSelector:(null)",
    ]

    #expect(accessibilityAction(namedOneOf: ["Reply", "Svar"], in: actions) == actions[1])
    #expect(accessibilityAction(namedOneOf: ["React", "Tapback"], in: actions) == actions[2])
    #expect(accessibilityAction(namedOneOf: ["Svar senere"], in: actions) == nil)
}

@Test
func rootRepliesUseTheDeepLinkOverlayWithoutInvokingReplyAgain() {
    let rootReply = AccessibilitySendRequest(
        conversationGUID: "any;-;friend@example.com",
        text: "First reply",
        mediaURLs: [],
        replyMessageGUID: "ROOT-GUID",
        replyThreadOriginatorGUID: nil
    )
    let nestedReply = AccessibilitySendRequest(
        conversationGUID: "any;-;friend@example.com",
        text: "Nested reply",
        mediaURLs: [],
        replyMessageGUID: "CHILD-GUID",
        replyThreadOriginatorGUID: "ROOT-GUID"
    )
    let attachment = AccessibilitySendRequest(
        conversationGUID: "any;-;friend@example.com",
        conversationAnchorMessageGUID: "LATEST-GUID",
        text: "caption",
        mediaURLs: [URL(fileURLWithPath: "/synthetic/photo.jpg")],
        replyMessageGUID: nil,
        replyThreadOriginatorGUID: nil
    )

    #expect(rootReply.opensReplyOverlay)
    #expect(!rootReply.requiresReplyAction)
    #expect(!rootReply.requiresConversationAnchorSelection)
    #expect(!rootReply.resetsReplyTranscriptBeforeOpening)
    #expect(!nestedReply.opensReplyOverlay)
    #expect(nestedReply.requiresReplyAction)
    #expect(!nestedReply.requiresConversationAnchorSelection)
    #expect(nestedReply.resetsReplyTranscriptBeforeOpening)
    #expect(attachment.requiresConversationAnchorSelection)
    #expect(attachment.resetsReplyTranscriptBeforeOpening)
}

private func queryItems(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .compactMap { item in item.value.map { (item.name, $0) } })
}

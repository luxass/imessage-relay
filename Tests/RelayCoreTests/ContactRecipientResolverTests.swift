import Foundation
import Testing

@testable import RelayCore

@Test
func contactResolverNormalizesRegionalPhoneNumbersWithoutLoadingContacts() async throws {
    let resolver = ContactRecipientResolver(region: "US")
    let candidate = try RecipientHandle(type: .phone, value: "(415) 555-0100")

    let resolved = try await resolver.resolve(candidate)

    #expect(resolved.type == .phone)
    #expect(resolved.value == "+14155550100")
    #expect(resolved.displayValue == "(415) 555-0100")

    let appURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-resource-test-\(UUID().uuidString).app", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: appURL) }
    let metadataURL = appURL.appendingPathComponent(
        "Contents/Resources/PhoneNumberKit_PhoneNumberKit.bundle/PhoneNumberMetadata.json"
    )
    try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let metadata = Data("{}".utf8)
    try metadata.write(to: metadataURL)
    let appBundle = try #require(Bundle(url: appURL))

    #expect(try ContactRecipientResolver.loadPhoneNumberMetadata(in: appBundle) == metadata)

    try FileManager.default.removeItem(at: metadataURL)
    #expect(throws: (any Error).self) {
        _ = try ContactRecipientResolver.loadPhoneNumberMetadata(in: appBundle)
    }
}

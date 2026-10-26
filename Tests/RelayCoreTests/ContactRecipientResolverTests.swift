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
}

@Suite
final class PhoneNumberMetadataTests {
    private static let metadata = Data("{}".utf8)

    private let appURL: URL
    private let metadataURL: URL
    private let appBundle: Bundle

    init() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-test-\(UUID().uuidString).app")
        let metadataURL = appURL.appendingPathComponent(
            "Contents/Resources/PhoneNumberKit_PhoneNumberKit.bundle/PhoneNumberMetadata.json"
        )

        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.metadata.write(to: metadataURL)

        self.appURL = appURL
        self.metadataURL = metadataURL
        self.appBundle = try #require(Bundle(url: appURL))
    }

    deinit {
        try? FileManager.default.removeItem(at: appURL)
    }

    @Test
    func loadsMetadataFromAppResources() throws {
        let data = try ContactRecipientResolver.loadPhoneNumberMetadata(in: appBundle)

        #expect(data == Self.metadata)
    }

    @Test
    func missingMetadataThrows() throws {
        try FileManager.default.removeItem(at: metadataURL)

        #expect(throws: (any Error).self) {
            _ = try ContactRecipientResolver.loadPhoneNumberMetadata(in: appBundle)
        }
    }
}

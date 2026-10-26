import Foundation
import PhoneNumberKit
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
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    let resourceURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        .appendingPathComponent("PhoneNumberKit_PhoneNumberKit.bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: resourceURL, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
        fromPropertyList: [
            "CFBundleIdentifier": "dev.example.relay-resource-test",
            "CFBundlePackageType": "APPL",
        ],
        format: .xml,
        options: 0
    )
    try plist.write(to: contentsURL.appendingPathComponent("Info.plist"))
    let metadata = try #require(try ContactRecipientResolver.loadPhoneNumberMetadata())
    let metadataURL = resourceURL.appendingPathComponent("PhoneNumberMetadata.json")
    try metadata.write(to: metadataURL)
    let appBundle = try #require(Bundle(url: appURL))

    let appMetadata = try #require(try ContactRecipientResolver.loadPhoneNumberMetadata(in: appBundle))
    let appUtility = PhoneNumberUtility(metadataCallback: { appMetadata })
    let appNumber = try appUtility.parse(candidate.value, withRegion: "US")
    #expect(appUtility.format(appNumber, toType: .e164) == "+14155550100")

    try FileManager.default.removeItem(at: metadataURL)
    #expect(throws: (any Error).self) {
        _ = try ContactRecipientResolver.loadPhoneNumberMetadata(in: appBundle)
    }
}

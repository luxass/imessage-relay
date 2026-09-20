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

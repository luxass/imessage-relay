import Foundation
import PhoneNumberKit
@preconcurrency import Contacts

public actor ContactRecipientResolver: RecipientResolving {
    private struct Contact: Sendable {
        let name: String
        let handles: [RecipientHandle]
    }

    private let region: String
    private let refreshInterval: TimeInterval
    private let phoneNumberUtility = PhoneNumberUtility()
    private var contacts: [Contact] = []
    private var loadedAt: Date?

    public init(region: String = "US", refreshInterval: TimeInterval = 30) {
        let normalizedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.region = normalizedRegion.isEmpty ? "US" : normalizedRegion
        self.refreshInterval = max(0, refreshInterval)
    }

    public func resolve(_ candidate: RecipientHandle) async throws -> RecipientHandle {
        switch candidate.type {
        case .phone:
            return try normalizedPhone(candidate)
        case .email:
            return candidate
        case .other:
            return try await resolveContact(named: candidate.value)
        }
    }

    private func normalizedPhone(_ candidate: RecipientHandle) throws -> RecipientHandle {
        let input = candidate.displayValue ?? candidate.value
        do {
            let number = try phoneNumberUtility.parse(input, withRegion: region, ignoreType: true)
            let normalized = phoneNumberUtility.format(number, toType: .e164)
            return try RecipientHandle(
                type: .phone,
                value: normalized,
                displayValue: candidate.displayValue ?? input
            )
        } catch {
            return candidate
        }
    }

    private func resolveContact(named name: String) async throws -> RecipientHandle {
        try await refreshIfNeeded()
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = contacts.filter { $0.name.compare(query, options: .caseInsensitive) == .orderedSame }
        let candidates = exact.isEmpty
            ? contacts.filter { $0.name.localizedCaseInsensitiveContains(query) }
            : exact
        let handles: [RecipientHandle] = candidates.compactMap { contact in
            guard let handle = contact.handles.first else { return nil }
            return try? RecipientHandle(
                type: handle.type,
                value: handle.value,
                displayValue: contact.name
            )
        }
        let unique = Dictionary(grouping: handles, by: { "\($0.type.rawValue)\u{0}\($0.value)" })
            .values
            .compactMap(\.first)
        switch unique.count {
        case 0:
            throw RecipientResolutionError.notFound(name)
        case 1:
            return unique[0]
        default:
            throw RecipientResolutionError.ambiguous(name)
        }
    }

    private func refreshIfNeeded() async throws {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < refreshInterval { return }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        let authorized: Bool
        if status == .notDetermined {
            authorized = await requestAccess()
        } else {
            authorized = status == .authorized
        }
        guard authorized else { throw RecipientResolutionError.contactsUnavailable }

        do {
            contacts = try await Self.loadContacts(region: region)
            loadedAt = Date()
        } catch {
            throw RecipientResolutionError.contactsUnavailable
        }
    }

    private func requestAccess() async -> Bool {
        let store = CNContactStore()
        return await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func loadContacts(region: String) async throws -> [Contact] {
        try await Task.detached(priority: .utility) {
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactNicknameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            let phoneNumberUtility = PhoneNumberUtility()
            var contacts: [Contact] = []
            try store.enumerateContacts(with: request) { contact, _ in
                let fullName = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let name = contact.nickname.isEmpty ? fullName : contact.nickname
                guard !name.isEmpty else { return }
                let phones = contact.phoneNumbers.compactMap { labeledValue -> RecipientHandle? in
                    let raw = labeledValue.value.stringValue
                    guard let parsed = try? phoneNumberUtility.parse(
                        raw,
                        withRegion: region,
                        ignoreType: true
                    ) else { return nil }
                    let value = phoneNumberUtility.format(parsed, toType: .e164)
                    return try? RecipientHandle(type: .phone, value: value)
                }
                let emails = contact.emailAddresses.compactMap {
                    try? RecipientHandle(type: .email, value: String($0.value))
                }
                let handles = phones + emails
                if !handles.isEmpty { contacts.append(Contact(name: name, handles: handles)) }
            }
            return contacts
        }.value
    }
}

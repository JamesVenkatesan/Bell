import Foundation
import Security

/// A schedule that keeps itself up to date.
///
/// The URL is the sensitive part: a UniTime calendar link carries an
/// authentication token, so anyone holding it can read your schedule. It goes
/// in the Keychain rather than defaults, which are plain-text inside the
/// container and end up in unencrypted backups.
///
/// Refreshes are advisory, not automatic-and-silent. A subscription that
/// rewrote your schedule in the background would eventually rewrite it wrongly
/// while you weren't looking, so a fetch produces a diff like any other
/// import — it just doesn't need you to find a file first.
enum Subscription {

    private static let account = "schedule.subscription.url"
    private static let lastFetchKey = "subscription.lastFetch"

    // MARK: - The URL

    static var url: URL? {
        get {
            guard let string = Keychain.read(account: account) else { return nil }
            return URL(string: string)
        }
        set {
            if let newValue {
                Keychain.write(newValue.absoluteString, account: account)
            } else {
                Keychain.delete(account: account)
                AppGroup.defaults?.removeObject(forKey: lastFetchKey)
            }
        }
    }

    static var isActive: Bool { url != nil }

    static var lastFetched: Date? {
        get { AppGroup.defaults?.object(forKey: lastFetchKey) as? Date }
        set { AppGroup.defaults?.set(newValue, forKey: lastFetchKey) }
    }

    /// A name for the feed that doesn't leak the token — the host only.
    static var displayName: String? {
        url?.host()
    }

    // MARK: - Fetching

    static func fetch() async throws -> Timetable {
        guard let url else { throw ICSImporter.ICSError.notCalendarData }
        let timetable = try await ICSImporter.fetch(from: url)
        lastFetched = .now
        return timetable
    }

    /// True when it's worth checking again. Schedules change on the order of
    /// days, so hourly polling would spend battery to learn nothing.
    static var isDue: Bool {
        guard isActive else { return false }
        guard let last = lastFetched else { return true }
        return Date.now.timeIntervalSince(last) > 6 * 3600
    }
}

// MARK: - Keychain
//
// Small and deliberately minimal: one string, one account, no sharing group.
// Only the app reads this — the widget never fetches — so no entitlement
// beyond the default keychain is needed.

enum Keychain {

    private static let service = "com.yourteam.bell"

    static func write(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Delete-then-add rather than update: fewer branches, and the failure
        // mode of a stale value is worse than that of a brief absence.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // Needs to survive a reboot before first unlock? No — a fetch only
        // happens with the app in use, so the stricter class is free.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

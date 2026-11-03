import BackgroundTasks
import Foundation

/// What Bell remembers about the connected database. Not secret, so it lives
/// in defaults; the token is the one secret and lives in the Keychain.
struct NotionConfig: Codable, Equatable {
    var source: NotionSource
    var title: String
    var schema: [NotionProperty]
    var mapping: NotionMapping
    var otherSources: [String] = []
}

/// The Notion connection: token, mapping, syncing, and asking iOS for a
/// morning refresh. Everything with a side effect lives here.
///
/// Read-only and additive, by design. Bell never writes to Notion, and a
/// sync only ever touches the tasks it created from Notion; a task you added
/// in Bell is invisible to it.
@MainActor
@Observable
final class NotionAccount {

    static let shared = NotionAccount()

    static let tokenKey = "notion.token"
    static let configKey = "notion.config"
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let refreshTaskID = "com.yourteam.bell.notion-refresh"

    private(set) var config: NotionConfig?
    private(set) var hasToken: Bool
    private(set) var lastError: String?
    private(set) var isWorking = false
    private(set) var lastResult: Result?

    /// The network, replaceable in tests.
    @ObservationIgnored var transport: NotionTransport = URLSessionNotionTransport()

    struct Result: Equatable {
        var applied: BellStore.NotionApplied
        var total: Int
        var unlinked: Int
        var skipped: Int
    }

    var isConnected: Bool { hasToken && config != nil }
    var lastSynced: Date? { Preferences.notionSyncedAt }

    init() {
        hasToken = Keychain.read(account: Self.tokenKey) != nil
        config = Preferences.store?.data(forKey: Self.configKey)
            .flatMap { try? JSONDecoder().decode(NotionConfig.self, from: $0) }
    }

    private func save(_ config: NotionConfig?) {
        self.config = config
        if let config, let data = try? JSONEncoder().encode(config) {
            Preferences.store?.set(data, forKey: Self.configKey)
        } else {
            Preferences.store?.removeObject(forKey: Self.configKey)
        }
        Preferences.notionConnected = isConnected
    }

    private func client(token: String) -> NotionClient { NotionClient(token: token, transport: transport) }

    // MARK: Connecting

    /// Checks the token and link against Notion before keeping either, so a
    /// typo fails here, with a reason, rather than at 5am in the background.
    @discardableResult
    func connect(token rawToken: String, link: String, store: BellStore) async -> Bool {
        lastError = nil
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("ntn_") || token.hasPrefix("secret_") else { return fail(NotionError.badToken) }
        guard let databaseID = NotionDatabaseID.parse(link) else { return fail(NotionError.badLink) }

        isWorking = true
        defer { isWorking = false }
        do {
            let found = try await client(token: token).discover(databaseID: databaseID)
            // Reconnecting the same database keeps the mapping the user
            // already corrected, minus anything that no longer exists.
            let mapping = config.flatMap { $0.source.databaseID == databaseID ? $0.mapping.pruned(to: found.schema) : nil }
                ?? NotionMapping.suggest(for: found.schema)
            Keychain.write(token, account: Self.tokenKey, availableInBackground: true)
            hasToken = true
            save(NotionConfig(source: found.source, title: found.title, schema: found.schema,
                              mapping: mapping, otherSources: found.otherSources))
            if mapping.isUsable { await sync(store: store, force: true) }
            Self.scheduleRefresh()
            return true
        } catch {
            return fail(error)
        }
    }

    func disconnect(store: BellStore) {
        Keychain.delete(account: Self.tokenKey)
        hasToken = false
        save(nil)
        Preferences.notionSyncedAt = nil
        Preferences.notionRefreshRequested = nil
        lastResult = nil
        lastError = nil
        store.removeNotionTasks()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
    }

    func setMapping(_ mapping: NotionMapping, store: BellStore) async {
        guard var config else { return }
        config.mapping = mapping
        save(config)
        if mapping.isUsable { await sync(store: store, force: true) }
    }

    // MARK: Syncing

    /// Reads every row, then makes Bell's Notion tasks match. All or
    /// nothing: if any request fails, nothing in Bell changes, because
    /// applying a partial read would delete whatever wasn't reached.
    @discardableResult
    func sync(store: BellStore, force: Bool = false) async -> Bool {
        guard !isWorking, var config, config.mapping.isUsable,
              let token = Keychain.read(account: Self.tokenKey) else { return false }
        if !force, !NotionFreshness.isStale(lastSynced, now: .now, maxAge: NotionFreshness.foregroundMaxAge),
           Preferences.notionRefreshRequested == nil { return false }

        isWorking = true
        defer { isWorking = false }
        let client = client(token: token)
        do {
            let pages: [[String: Any]]
            do {
                pages = try await client.allPages(from: config.source)
                if let schema = try? await client.schema(for: config.source), !schema.isEmpty {
                    config.schema = schema
                    config.mapping = config.mapping.pruned(to: schema)
                }
            } catch let error as NotionError where error.mightBeVersionProblem && error != .notShared {
                // The database worked before and doesn't now: most likely it
                // gained a second data source and the classic query stopped
                // answering. Probe again once and carry on with what works.
                let found = try await client.discover(databaseID: config.source.databaseID)
                config.source = found.source
                config.schema = found.schema
                config.mapping = config.mapping.pruned(to: found.schema)
                config.otherSources = found.otherSources
                pages = try await client.allPages(from: found.source)
            }
            save(config)
            guard config.mapping.isUsable else { return fail(nil, message: "The title or due date column is gone. Choose it again below.") }

            var items = pages.compactMap { NotionItem.make(page: $0, mapping: config.mapping, schema: config.schema) }
            let titles = await relationTitles(for: items, client: client, version: config.source.version)
            let courses = store.timetable.courses
            for index in items.indices {
                let related = items[index].courseRelations.compactMap { titles[$0] }
                let text = ([items[index].courseText].compactMap { $0 } + related).joined(separator: " ")
                items[index].course = NotionCourse.match(courseText: text.isEmpty ? nil : text,
                                                         title: items[index].title, courses: courses)
            }

            let applied = store.applyNotion(items)
            Preferences.notionSyncedAt = .now
            Preferences.notionRefreshRequested = nil
            lastResult = Result(applied: applied, total: items.count,
                                unlinked: items.filter { $0.course == nil }.count,
                                skipped: pages.count - items.count)
            lastError = nil
            return true
        } catch {
            return fail(error)
        }
    }

    /// For the app coming to the foreground: syncs when the data is older
    /// than an hour, or a widget has noticed it's stale.
    func syncIfNeeded(store: BellStore) async {
        guard isConnected else { return }
        await sync(store: store)
    }

    /// Titles of the pages a course relation points at, each fetched once.
    /// Capped: a relation column pointing at hundreds of pages isn't a
    /// course column, and Notion allows about three requests a second.
    private func relationTitles(for items: [NotionItem], client: NotionClient, version: String) async -> [String: String] {
        let ids = Array(Set(items.flatMap(\.courseRelations))).sorted().prefix(30)
        var titles: [String: String] = [:]
        for id in ids {
            if let title = await client.pageTitle(id, version: version) { titles[id] = title }
        }
        return titles
    }

    @discardableResult
    private func fail(_ error: Error?, message: String? = nil) -> Bool {
        lastError = message ?? (error as? NotionError)?.errorDescription ?? error?.localizedDescription
        return false
    }

    // MARK: Background refresh

    /// Asks iOS to run Bell early tomorrow morning (or soon, if a widget has
    /// flagged stale data). A request, not a schedule: iOS decides whether
    /// and when, from battery, network and how often the app is used.
    /// Resubmitting replaces the previous request, so this is safe to call
    /// whenever the app goes to the background.
    static func scheduleRefresh(now: Date = .now) {
        guard Preferences.notionConnected else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Preferences.notionRefreshRequested != nil
            ? now.addingTimeInterval(15 * 60)
            : NotionFreshness.nextMorning(after: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The background refresh itself. Books the next one first, so a sync
    /// that's cut short by iOS still leaves tomorrow's request in place.
    static func runBackgroundRefresh() async {
        scheduleRefresh()
        await shared.sync(store: .shared, force: true)
    }
}

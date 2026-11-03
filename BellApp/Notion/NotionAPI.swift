import Foundation

// Talking to Notion. Read-only: every request here is a GET or a query;
// nothing creates, edits or deletes anything in the user's workspace.
//
// The Notion-Version header is pinned, never floating. Notion's 2025-09-03
// release moved database queries to "data sources" (a database can now hold
// several), and versions before it fail on a database that has more than one.
// So Bell tries the classic path at a fixed old version first, and falls back
// to the data-source path at a fixed new version, and remembers which one the
// user's database answered to.

enum NotionAPI {
    static let base = URL(string: "https://api.notion.com/v1/")!

    /// The classic database endpoints: GET /databases/{id} carries the
    /// schema, POST /databases/{id}/query the rows.
    static let classicVersion = "2022-06-28"
    /// Data sources: the database lists its sources, each source carries the
    /// schema and is queried at POST /data_sources/{id}/query.
    static let dataSourceVersion = "2025-09-03"

    /// The most rows one sync reads. A term's homework tracker is a few
    /// hundred at most; this bounds a runaway database, not a real one.
    static let maxPages = 20
}

/// Which endpoint family the user's database works with. Remembered, so
/// each sync goes straight to it instead of probing again.
enum NotionSource: Codable, Equatable {
    case classic(databaseID: String)
    case dataSource(id: String, databaseID: String)

    var version: String {
        switch self {
        case .classic: NotionAPI.classicVersion
        case .dataSource: NotionAPI.dataSourceVersion
        }
    }

    var queryPath: String {
        switch self {
        case .classic(let id): "databases/\(id)/query"
        case .dataSource(let id, _): "data_sources/\(id)/query"
        }
    }

    var databaseID: String {
        switch self {
        case .classic(let id), .dataSource(_, let id): id
        }
    }

    var summary: String {
        switch self {
        case .classic: "Database query, Notion API \(NotionAPI.classicVersion)"
        case .dataSource: "Data source query, Notion API \(NotionAPI.dataSourceVersion)"
        }
    }
}

enum NotionError: LocalizedError, Equatable {
    case badLink
    case badToken
    case unauthorized
    case notShared
    case rateLimited
    case noDataSource
    case api(status: Int, code: String, message: String)
    case offline(String)

    var errorDescription: String? {
        switch self {
        case .badLink:
            "That doesn't look like a Notion database link. Open the database, then Share > Copy link."
        case .badToken:
            "That doesn't look like an integration secret. It starts with ntn_ (or secret_ for older integrations)."
        case .unauthorized:
            "Notion rejected the token. Copy the Internal Integration Secret again from notion.so/my-integrations."
        case .notShared:
            "Notion can't find that database for this integration. Open the database, tap ••• > Connections, and add your integration."
        case .rateLimited:
            "Notion asked Bell to slow down. It'll try again on the next sync."
        case .noDataSource:
            "The database has no data sources Bell can read."
        case .api(let status, let code, let message):
            "Notion said (\(status) \(code)): \(message)"
        case .offline(let reason):
            "Couldn't reach Notion: \(reason)"
        }
    }

    /// Worth trying the other endpoint family. A rejected token isn't: it
    /// would fail the same way and only hide the real problem.
    var mightBeVersionProblem: Bool {
        switch self {
        case .unauthorized, .badToken, .badLink, .offline, .rateLimited: false
        default: true
        }
    }
}

/// The network, behind a seam so tests can play Notion's side.
protocol NotionTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionNotionTransport: NotionTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct NotionClient {
    /// Held only for the length of a sync. Never logged, never put in an
    /// error, never written anywhere but the request's Authorization header.
    let token: String
    var transport: NotionTransport = URLSessionNotionTransport()

    struct Discovery {
        var source: NotionSource
        var title: String
        var schema: [NotionProperty]
        /// Data sources in the database, when there's more than one, so
        /// settings can say which one Bell is reading.
        var otherSources: [String] = []
    }

    /// Finds how to read the database: the classic query at the old pinned
    /// version, and if that fails for any reason but a bad token, the data
    /// source path at the new pinned version.
    func discover(databaseID: String) async throws -> Discovery {
        let classicError: NotionError
        do {
            let database = try await call("GET", "databases/\(databaseID)", version: NotionAPI.classicVersion)
            // The query is what matters, not the schema: a multi-source
            // database can describe itself and still refuse the old query.
            _ = try await call("POST", "databases/\(databaseID)/query", version: NotionAPI.classicVersion,
                               body: ["page_size": 1])
            return Discovery(source: .classic(databaseID: databaseID),
                             title: NotionProperty.title(from: database),
                             schema: NotionProperty.schema(from: database))
        } catch let error as NotionError where error.mightBeVersionProblem {
            classicError = error
        }

        do {
            let database = try await call("GET", "databases/\(databaseID)", version: NotionAPI.dataSourceVersion)
            let sources = (database["data_sources"] as? [[String: Any]]) ?? []
            guard let first = sources.first, let sourceID = first["id"] as? String else { throw NotionError.noDataSource }
            let source = try await call("GET", "data_sources/\(sourceID)", version: NotionAPI.dataSourceVersion)
            _ = try await call("POST", "data_sources/\(sourceID)/query", version: NotionAPI.dataSourceVersion,
                               body: ["page_size": 1])
            return Discovery(source: .dataSource(id: sourceID, databaseID: databaseID),
                             title: NotionProperty.title(from: database),
                             schema: NotionProperty.schema(from: source),
                             otherSources: sources.dropFirst().compactMap { $0["name"] as? String })
        } catch let error as NotionError {
            // Both failed. "Not shared" from either is the likeliest truth
            // and the one the user can fix, so it wins.
            if error == .notShared || classicError == .notShared { throw NotionError.notShared }
            throw error
        }
    }

    /// The current schema for a known source, so a column added or renamed
    /// in Notion shows up in settings on the next sync.
    func schema(for source: NotionSource) async throws -> [NotionProperty] {
        switch source {
        case .classic(let id):
            NotionProperty.schema(from: try await call("GET", "databases/\(id)", version: source.version))
        case .dataSource(let id, _):
            NotionProperty.schema(from: try await call("GET", "data_sources/\(id)", version: source.version))
        }
    }

    /// Every row, following Notion's cursor to the end. Throws rather than
    /// returning what it got so far: a partial list would make the sync
    /// delete everything it didn't reach.
    func allPages(from source: NotionSource) async throws -> [[String: Any]] {
        var pages: [[String: Any]] = []
        var cursor: String?
        for _ in 0 ..< NotionAPI.maxPages {
            var body: [String: Any] = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let response = try await call("POST", source.queryPath, version: source.version, body: body)
            pages += (response["results"] as? [[String: Any]]) ?? []
            guard response["has_more"] as? Bool == true, let next = response["next_cursor"] as? String else { return pages }
            cursor = next
        }
        return pages
    }

    /// A related page's title, for a course column that's a relation to a
    /// Courses database. Nil when that database isn't shared with the
    /// integration, which is common and not an error worth stopping for.
    func pageTitle(_ id: String, version: String) async -> String? {
        guard let page = try? await call("GET", "pages/\(id)", version: version),
              let properties = page["properties"] as? [String: Any] else { return nil }
        for case let body as [String: Any] in properties.values where body["type"] as? String == "title" {
            return NotionValue.plainText(body["title"])
        }
        return nil
    }

    func request(_ method: String, _ path: String, version: String, body: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: NotionAPI.base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func call(_ method: String, _ path: String, version: String,
                      body: [String: Any]? = nil) async throws -> [String: Any] {
        let data: Data, status: Int
        do {
            (data, status) = try await transport.send(request(method, path, version: version, body: body))
        } catch {
            throw NotionError.offline(error.localizedDescription)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200 ..< 300).contains(status) { return json }
        let code = json["code"] as? String ?? ""
        switch (status, code) {
        case (401, _): throw NotionError.unauthorized
        case (404, _), (_, "object_not_found"): throw NotionError.notShared
        case (429, _): throw NotionError.rateLimited
        default: throw NotionError.api(status: status, code: code, message: json["message"] as? String ?? "HTTP \(status)")
        }
    }
}

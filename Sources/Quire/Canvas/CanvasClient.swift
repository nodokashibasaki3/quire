import Foundation

struct CanvasClient: Sendable {
    let credentials: CanvasCredentials
    let session: URLSession

    init(credentials: CanvasCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    /// Hits /api/v1/users/self. Returns the authenticated user's name. Throws on bad token / wrong host.
    func testConnection() async throws -> String {
        let request = buildRequest(path: "/api/v1/users/self")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        struct Resp: Decodable { let name: String }
        let user = try JSONDecoder().decode(Resp.self, from: data)
        return user.name
    }

    /// Fetches upcoming planner items between today and `daysAhead` from now.
    /// Filters to assignments / quizzes / discussion topics — the actionable items.
    func fetchUpcomingItems(daysAhead: Int = 60) async throws -> [CanvasItem] {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = .current

        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: start) ?? start

        let request = buildRequest(
            path: "/api/v1/planner/items",
            queryItems: [
                URLQueryItem(name: "start_date", value: dayFormatter.string(from: start)),
                URLQueryItem(name: "end_date", value: dayFormatter.string(from: end)),
                URLQueryItem(name: "per_page", value: "100"),
            ]
        )

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterFallback = ISO8601DateFormatter()
        isoFormatterFallback.formatOptions = [.withInternetDateTime]

        let raw = try JSONDecoder().decode([PlannerItem].self, from: data)
        let host = credentials.host

        return raw.compactMap { item in
            guard let typeStr = item.plannable_type,
                  ["assignment", "quiz", "discussion_topic"].contains(typeStr),
                  let plannable = item.plannable,
                  let plannableID = plannable.id,
                  let title = plannable.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else { return nil }

            let dueAt: Date? = item.plannable_date.flatMap {
                isoFormatter.date(from: $0) ?? isoFormatterFallback.date(from: $0)
            }

            let htmlURL: URL? = item.html_url.flatMap {
                URL(string: "https://\(host)\($0)")
            }

            return CanvasItem(
                id: String(plannableID),
                title: title,
                courseName: (item.context_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                dueAt: dueAt,
                htmlURL: htmlURL
            )
        }
    }

    // MARK: - Helpers

    private func buildRequest(path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = credentials.host
        components.path = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CanvasError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw CanvasError.unauthorized
        case 403: throw CanvasError.forbidden
        case 404: throw CanvasError.notFound
        default: throw CanvasError.httpStatus(http.statusCode)
        }
    }

    private struct PlannerItem: Decodable {
        let plannable_type: String?
        let plannable_date: String?
        let context_name: String?
        let html_url: String?
        let plannable: Plannable?

        struct Plannable: Decodable {
            let id: Int?
            let title: String?
        }
    }
}

enum CanvasError: LocalizedError {
    case notConfigured
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Canvas isn't configured. Add a host and token in Settings."
        case .invalidResponse: return "Unexpected response from Canvas."
        case .unauthorized: return "Canvas rejected the token. Check Settings."
        case .forbidden: return "Canvas refused the request (403)."
        case .notFound: return "Canvas endpoint not found — check the host."
        case .httpStatus(let code): return "Canvas returned HTTP \(code)."
        }
    }
}

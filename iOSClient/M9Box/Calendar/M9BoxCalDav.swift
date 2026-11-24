//
//  M9 Box - Nextcloud client branded for M9 Box
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  CalDAV transport over URLSession + a namespace-aware SAX multistatus parser
//  (iOS has no XMLDocument, so we build a tiny tree from XMLParser). Implements
//  time-range REPORT, sync-collection (RFC 6578) and ETag/If-Match writes —
//  the correctness the reference RN client lacked.
//

import Foundation

struct M9BoxCalDavError: Error { let code: Int; let op: String }

final class M9BoxCalDavClient {
    private let session: URLSession
    private let baseURL: URL
    private let authHeader: String
    private let userId: String

    /// - Parameters:
    ///   - baseURL: Nextcloud server root (e.g. https://box.example.com).
    ///   - authHeader: value for the Authorization header.
    ///   - userId: DAV user id (account username).
    init(baseURL: URL, authHeader: String, userId: String, session: URLSession = .shared) {
        self.session = session
        self.baseURL = baseURL
        self.authHeader = authHeader
        self.userId = userId
    }

    private var davBase: String { baseURL.absoluteString.trimmedTrailingSlash + "/remote.php/dav" }
    private var calendarHome: String { "\(davBase)/calendars/\(userId)/" }

    private func url(_ href: String) -> URL {
        if href.hasPrefix("http"), let u = URL(string: href) { return u }
        // Resolve an absolute path against the origin.
        if let u = URL(string: href, relativeTo: baseURL) { return u.absoluteURL }
        return baseURL
    }

    private func request(_ href: String, method: String, body: String?, depth: String?) -> URLRequest {
        var req = URLRequest(url: url(href))
        req.httpMethod = method
        // A cached GET would hand back a stale ETag, and the If-Match that follows
        // would then fail with 412 on an object nobody else touched.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let depth = depth { req.setValue(depth, forHTTPHeaderField: "Depth") }
        if let body = body {
            req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data(using: .utf8)
        }
        return req
    }

    private func send(_ req: URLRequest, op: String, expected: Set<Int>) async throws -> (Int, Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw M9BoxCalDavError(code: -1, op: op) }
        if !expected.contains(http.statusCode) { throw M9BoxCalDavError(code: http.statusCode, op: op) }
        return (http.statusCode, data, http)
    }

    func discoverCalendars() async throws -> [M9BoxCalendarCollection] {
        let req = request(calendarHome, method: "PROPFIND", body: M9BoxCalDavBodies.propfindCalendars, depth: "1")
        let (_, data, _) = try await send(req, op: "discoverCalendars", expected: [207])
        return M9BoxMultiStatus.parseCalendars(data, ownHref: calendarHome)
    }

    /// Collections that accept VTODO (NC Tasks lists, or calendars with both).
    func discoverTaskLists() async throws -> [M9BoxCalendarCollection] {
        let req = request(calendarHome, method: "PROPFIND", body: M9BoxCalDavBodies.propfindCalendars, depth: "1")
        let (_, data, _) = try await send(req, op: "discoverTaskLists", expected: [207])
        return M9BoxMultiStatus.parseCalendars(data, ownHref: calendarHome, component: "VTODO")
    }

    func listTodos(calendarHref: String) async throws -> [M9BoxRemoteResource] {
        let req = request(calendarHref, method: "REPORT", body: M9BoxCalDavBodies.todoQuery, depth: "1")
        let (_, data, _) = try await send(req, op: "listTodos", expected: [207])
        return M9BoxMultiStatus.parseResources(data)
    }

    /// MKCALENDAR a VTODO-only list (same shape the Nextcloud Tasks app creates).
    func createTaskList(name: String) async throws {
        let slug = "tarefas-" + UUID().uuidString.prefix(8).lowercased()
        let req = request("\(calendarHome)\(slug)/", method: "MKCALENDAR", body: M9BoxCalDavBodies.mkcalendarTasks(name: name), depth: nil)
        _ = try await send(req, op: "createTaskList", expected: [201])
    }

    func listEvents(calendarHref: String, start: Date, end: Date) async throws -> [M9BoxRemoteResource] {
        let body = M9BoxCalDavBodies.calendarQuery(start: start, end: end)
        let req = request(calendarHref, method: "REPORT", body: body, depth: "1")
        let (_, data, _) = try await send(req, op: "listEvents", expected: [207])
        return M9BoxMultiStatus.parseResources(data)
    }

    func syncCollection(calendarHref: String, syncToken: String?) async throws -> M9BoxSyncResult {
        let body = M9BoxCalDavBodies.syncCollection(syncToken: syncToken)
        let req = request(calendarHref, method: "REPORT", body: body, depth: "1")
        let (_, data, _) = try await send(req, op: "syncCollection", expected: [207])
        return M9BoxMultiStatus.parseSyncCollection(data)
    }

    func getResource(href: String) async throws -> M9BoxRemoteResource {
        let req = request(href, method: "GET", body: nil, depth: nil)
        let (_, data, http) = try await send(req, op: "getResource", expected: [200])
        let etag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return M9BoxRemoteResource(href: href, etag: etag, ics: String(data: data, encoding: .utf8) ?? "")
    }

    /// PUT an object. Pass `ifMatch` for updates, or set `isNew` for create.
    @discardableResult
    func putResource(href: String, ics: String, ifMatch: String?, isNew: Bool) async throws -> String? {
        var req = request(href, method: "PUT", body: nil, depth: nil)
        req.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = ics.data(using: .utf8)
        if isNew { req.setValue("*", forHTTPHeaderField: "If-None-Match") }
        else if let ifMatch = ifMatch { req.setValue("\"\(ifMatch)\"", forHTTPHeaderField: "If-Match") }
        let (_, _, http) = try await send(req, op: "putResource", expected: [200, 201, 204])
        return http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    func deleteResource(href: String, ifMatch: String?) async throws {
        var req = request(href, method: "DELETE", body: nil, depth: nil)
        if let ifMatch = ifMatch { req.setValue("\"\(ifMatch)\"", forHTTPHeaderField: "If-Match") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw M9BoxCalDavError(code: -1, op: "deleteResource") }
        _ = data
        // 404 tolerated: already gone.
        if ![200, 204, 404].contains(http.statusCode) { throw M9BoxCalDavError(code: http.statusCode, op: "deleteResource") }
    }
}

struct M9BoxSyncResult { var changed: [String]; var removed: [String]; var syncToken: String? }

private extension String {
    var trimmedTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

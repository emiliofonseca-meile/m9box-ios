//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Minimal CardDAV client — the CalDAV counterpart the calendar module already
//  has, written for the native Contacts sync. Discovers the user's address books
//  and pulls their vCards (href + etag + card data) in one addressbook-query
//  REPORT per book. Read-only for now (server -> device); writes back are a
//  follow-up, mirroring how the calendar sync was staged.
//

import Foundation

struct MeileAddressBook: Hashable {
    var href: String
    var displayName: String
}

struct MeileRemoteVCard: Hashable {
    var href: String
    var etag: String?
    var vcard: String
}

struct MeileCardDavError: Error { let code: Int; let op: String }

final class MeileCardDavClient {
    private let baseURL: URL
    private let authHeader: String
    private let userId: String
    private let session: URLSession

    init(baseURL: URL, authHeader: String, userId: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.authHeader = authHeader
        self.userId = userId
        self.session = session
    }

    private var davBase: String {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s + "/remote.php/dav"
    }
    private var addressBookHome: String { "\(davBase)/addressbooks/\(userId)/" }

    private func url(_ href: String) -> URL {
        if href.hasPrefix("http"), let u = URL(string: href) { return u }
        if let u = URL(string: href, relativeTo: baseURL) { return u.absoluteURL }
        return baseURL
    }

    private func request(_ href: String, method: String, body: String?, depth: String?) -> URLRequest {
        var req = URLRequest(url: url(href))
        req.httpMethod = method
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let depth { req.setValue(depth, forHTTPHeaderField: "Depth") }
        if let body {
            req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data(using: .utf8)
        }
        return req
    }

    private func send(_ req: URLRequest, op: String) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MeileCardDavError(code: -1, op: op) }
        guard http.statusCode == 207 else { throw MeileCardDavError(code: http.statusCode, op: op) }
        return data
    }

    func discoverAddressBooks() async throws -> [MeileAddressBook] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
          <d:prop><d:resourcetype/><d:displayname/></d:prop>
        </d:propfind>
        """
        let data = try await send(request(addressBookHome, method: "PROPFIND", body: body, depth: "1"), op: "discoverAddressBooks")
        return MeileCardDavParser.parseAddressBooks(data, home: addressBookHome)
    }

    func listContacts(addressBookHref: String) async throws -> [MeileRemoteVCard] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
          <d:prop><d:getetag/><card:address-data/></d:prop>
        </card:addressbook-query>
        """
        let data = try await send(request(addressBookHref, method: "REPORT", body: body, depth: "1"), op: "listContacts")
        return MeileCardDavParser.parseVCards(data)
    }
}

// MARK: - SAX parser (iOS has no XMLDocument; never scrape XML with regex)

private let NS_DAV = "DAV:"
private let NS_CARD = "urn:ietf:params:xml:ns:carddav"

private final class CardNode {
    let name: String
    let ns: String
    var text = ""
    var children: [CardNode] = []
    weak var parent: CardNode?
    init(_ name: String, _ ns: String, parent: CardNode?) { self.name = name; self.ns = ns; self.parent = parent }
    func child(_ ns: String, _ name: String) -> CardNode? { children.first { $0.name == name && $0.ns == ns } }
    func firstText(_ ns: String, _ name: String) -> String? { child(ns, name)?.text }
    /// Depth-first search (address-data sits under propstat/prop).
    func find(_ ns: String, _ name: String) -> CardNode? {
        if self.ns == ns && self.name == name { return self }
        for c in children { if let hit = c.find(ns, name) { return hit } }
        return nil
    }
}

private final class CardTreeBuilder: NSObject, XMLParserDelegate {
    let root = CardNode("root", "", parent: nil)
    private var current: CardNode
    override init() { current = root; super.init() }

    func parse(_ data: Data) -> CardNode {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = CardNode(elementName, namespaceURI ?? "", parent: current)
        current.children.append(node)
        current = node
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { current.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        current.text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        current = current.parent ?? root
    }
}

private enum MeileCardDavParser {

    private static func responses(_ data: Data) -> [CardNode] {
        CardTreeBuilder().parse(data).child(NS_DAV, "multistatus")?.children.filter { $0.name == "response" && $0.ns == NS_DAV } ?? []
    }

    static func parseAddressBooks(_ data: Data, home: String) -> [MeileAddressBook] {
        var out = [MeileAddressBook]()
        for resp in responses(data) {
            guard let href = resp.firstText(NS_DAV, "href") else { continue }
            // Skip the home collection itself.
            if href.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == home.trimmingCharacters(in: CharacterSet(charactersIn: "/")) { continue }
            // Only collections that declare carddav:addressbook resourcetype.
            let isAddressBook = resp.find(NS_DAV, "resourcetype")?.child(NS_CARD, "addressbook") != nil
            guard isAddressBook else { continue }
            let name = resp.find(NS_DAV, "displayname")?.text
            out.append(MeileAddressBook(href: href, displayName: (name?.isEmpty == false ? name! : "Contatos")))
        }
        return out
    }

    static func parseVCards(_ data: Data) -> [MeileRemoteVCard] {
        var out = [MeileRemoteVCard]()
        for resp in responses(data) {
            guard let href = resp.firstText(NS_DAV, "href") else { continue }
            let card = resp.find(NS_CARD, "address-data")?.text ?? ""
            guard !card.isEmpty else { continue }
            let etag = resp.find(NS_DAV, "getetag")?.text.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            out.append(MeileRemoteVCard(href: href, etag: etag, vcard: card))
        }
        return out
    }
}

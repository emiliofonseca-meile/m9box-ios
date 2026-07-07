//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Namespace-aware SAX multistatus parser: builds a tiny element tree from
//  Foundation's XMLParser (iOS lacks XMLDocument), then queries it like the
//  Android DOM parser. Never scrapes XML with regex.
//

import Foundation

private let NS_DAV = "DAV:"
private let NS_CALDAV = "urn:ietf:params:xml:ns:caldav"
private let NS_CS = "http://calendarserver.org/ns/"
private let NS_ICAL = "http://apple.com/ns/ical/"

private final class MeileXMLNode {
    let localName: String
    let namespace: String
    var attributes: [String: String]
    var text: String = ""
    var children: [MeileXMLNode] = []
    weak var parent: MeileXMLNode?
    init(_ localName: String, _ namespace: String, attributes: [String: String] = [:], parent: MeileXMLNode?) {
        self.localName = localName; self.namespace = namespace; self.attributes = attributes; self.parent = parent
    }
    func child(_ ns: String, _ name: String) -> MeileXMLNode? { children.first { $0.localName == name && $0.namespace == ns } }
    func childrenOf(_ ns: String, _ name: String) -> [MeileXMLNode] { children.filter { $0.localName == name && $0.namespace == ns } }
    func firstText(_ ns: String, _ name: String) -> String? { child(ns, name)?.text }
    func attribute(_ key: String) -> String? { attributes[key] }
}

private final class MeileTreeBuilder: NSObject, XMLParserDelegate {
    let root = MeileXMLNode("root", "", parent: nil)
    private var current: MeileXMLNode
    override init() { current = root; super.init() }

    func parse(_ data: Data) -> MeileXMLNode {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = MeileXMLNode(elementName, namespaceURI ?? "", attributes: attributeDict, parent: current)
        current.children.append(node)
        current = node
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        current.text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        current = current.parent ?? root
    }
}

enum MeileMultiStatus {

    private static func multistatus(_ data: Data) -> MeileXMLNode? {
        MeileTreeBuilder().parse(data).child(NS_DAV, "multistatus")
    }

    private static func responses(_ data: Data) -> [MeileXMLNode] {
        multistatus(data)?.childrenOf(NS_DAV, "response") ?? []
    }

    /// The <prop> of the first propstat whose status is 200 OK.
    private static func okProp(_ response: MeileXMLNode) -> MeileXMLNode? {
        for propstat in response.childrenOf(NS_DAV, "propstat") {
            let status = propstat.firstText(NS_DAV, "status") ?? ""
            if status.contains("200") { return propstat.child(NS_DAV, "prop") }
        }
        return response.child(NS_DAV, "propstat")?.child(NS_DAV, "prop")
    }

    static func parseCalendars(_ data: Data, ownHref: String) -> [MeileCalendarCollection] {
        var result = [MeileCalendarCollection]()
        for response in responses(data) {
            guard let href = response.firstText(NS_DAV, "href")?.trimmingCharacters(in: .whitespaces) else { continue }
            if href.trimTrailingSlash == ownHref.trimTrailingSlash { continue }
            guard let prop = okProp(response) else { continue }

            let isCalendar = prop.child(NS_DAV, "resourcetype")?.child(NS_CALDAV, "calendar") != nil
            if !isCalendar { continue }

            if let compSet = prop.child(NS_CALDAV, "supported-calendar-component-set") {
                let supportsVEvent = compSet.childrenOf(NS_CALDAV, "comp").isEmpty ||
                    compSet.childrenOf(NS_CALDAV, "comp").contains { $0.attribute("name")?.uppercased() == "VEVENT" }
                if !supportsVEvent { continue }
            }

            var readOnly = false
            if let privileges = prop.child(NS_DAV, "current-user-privilege-set") {
                let canWrite = privileges.childrenOf(NS_DAV, "privilege").contains {
                    $0.child(NS_DAV, "write") != nil || $0.child(NS_DAV, "write-content") != nil
                }
                readOnly = !canWrite
            }

            result.append(MeileCalendarCollection(
                href: href,
                displayName: prop.firstText(NS_DAV, "displayname").flatMap { $0.isEmpty ? nil : $0 }
                    ?? href.trimTrailingSlash.components(separatedBy: "/").last ?? href,
                color: prop.firstText(NS_ICAL, "calendar-color").map { normalizeColor($0) },
                ctag: prop.firstText(NS_CS, "getctag"),
                syncToken: prop.firstText(NS_DAV, "sync-token"),
                readOnly: readOnly
            ))
        }
        return result
    }

    static func parseResources(_ data: Data) -> [MeileRemoteResource] {
        var result = [MeileRemoteResource]()
        for response in responses(data) {
            guard let href = response.firstText(NS_DAV, "href")?.trimmingCharacters(in: .whitespaces),
                  let prop = okProp(response),
                  let ics = prop.firstText(NS_CALDAV, "calendar-data"), !ics.isEmpty else { continue }
            result.append(MeileRemoteResource(
                href: href,
                etag: prop.firstText(NS_DAV, "getetag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")),
                ics: ics
            ))
        }
        return result
    }

    static func parseSyncCollection(_ data: Data) -> MeileSyncResult {
        var changed = [String](), removed = [String]()
        for response in responses(data) {
            guard let href = response.firstText(NS_DAV, "href")?.trimmingCharacters(in: .whitespaces) else { continue }
            let status = response.firstText(NS_DAV, "status") ?? ""
            if status.contains("404") { removed.append(href) } else { changed.append(href) }
        }
        let token = multistatus(data)?.firstText(NS_DAV, "sync-token")
        return MeileSyncResult(changed: changed, removed: removed, syncToken: token)
    }

    private static func normalizeColor(_ raw: String) -> String {
        let hex = raw.trimmingCharacters(in: .whitespaces)
        return hex.hasPrefix("#") ? String(hex.prefix(7)) : "#" + String(hex.prefix(6))
    }
}

enum MeileCalDavBodies {
    static let propfindCalendars = """
    <?xml version="1.0" encoding="utf-8" ?>
    <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:ic="http://apple.com/ns/ical/">
      <d:prop>
        <d:resourcetype/><d:displayname/><d:current-user-privilege-set/>
        <cs:getctag/><d:sync-token/><ic:calendar-color/><c:supported-calendar-component-set/>
      </d:prop>
    </d:propfind>
    """

    static func calendarQuery(start: Date, end: Date) -> String {
        """
        <?xml version="1.0" encoding="utf-8" ?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop><d:getetag/><c:calendar-data/></d:prop>
          <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
            <c:time-range start="\(utcStamp(start))" end="\(utcStamp(end))"/>
          </c:comp-filter></c:comp-filter></c:filter>
        </c:calendar-query>
        """
    }

    static func syncCollection(syncToken: String?) -> String {
        """
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:sync-token>\(syncToken ?? "")</d:sync-token>
          <d:sync-level>1</d:sync-level>
          <d:prop><d:getetag/><c:calendar-data/></d:prop>
        </d:sync-collection>
        """
    }

    private static func utcStamp(_ date: Date) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return df.string(from: date)
    }
}

private extension String {
    var trimTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

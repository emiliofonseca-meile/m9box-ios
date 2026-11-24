//
//  M9 Box - Nextcloud client branded for M9 Box
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Native calendar/contacts sync — the iOS counterpart of the Android sync
//  adapter. Instead of an installed .mobileconfig, the app itself pulls the Box
//  CalDAV/CardDAV data and writes it into the phone's own Calendar (EventKit) and
//  Contacts (Contacts framework), after a one-tap permission prompt. Same trade
//  the Android client makes: freshness comes from opening the app (foreground
//  sync) rather than a system push, in exchange for zero setup friction.
//
//  Scope v1 = server -> device. Writing device edits back is a follow-up, exactly
//  as the calendar/contacts sync was staged on Android. The CalDAV transport and
//  iCal mapping are reused from the in-app calendar module; only the EventKit/
//  Contacts writing layer and the CardDAV/vCard readers are new.
//

import Contacts
import EventKit
import Foundation
import UIKit

/// Outcome of a sync pass, surfaced in the UI so problems are visible without a
/// device log.
struct M9BoxSyncSummary {
    var events = 0
    var contacts = 0
    var addressBooks = 0
    var pushedEvents = 0
    var pushedContacts = 0
    var contactContainer: String?
    var error: String?
}

final class M9BoxNativeSync {

    static let shared = M9BoxNativeSync()
    private init() {}

    private let enabledKey = "m9box_native_sync_enabled"
    private let contactMapKeyPrefix = "m9box_native_sync_contactmap_"
    private let calendarTitle = "M9 Box"
    private let groupName = "M9 Box"

    /// -1 month .. +12 months, matching the Android sync window.
    private let pastWindow: TimeInterval = 30 * 24 * 3600
    private let futureWindow: TimeInterval = 365 * 24 * 3600

    private var isRunning = false

    // MARK: enable / status

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Ask for Calendar + Contacts permission, and on grant mark enabled and run
    /// the first sync. Returns whether at least one side was granted.
    @discardableResult
    func enable(account: String) async -> Bool {
        let cal = await requestCalendarAccess()
        let con = await requestContactsAccess()
        guard cal || con else { return false }
        UserDefaults.standard.set(true, forKey: enabledKey)
        await sync(account: account)
        return true
    }

    /// Foreground trigger: sync only if the user already opted in. Safe to call
    /// from any screen's appear; it no-ops when disabled or already running.
    func syncIfEnabled(account: String) {
        guard isEnabled, !account.isEmpty else { return }
        Task { _ = await sync(account: account) }
    }

    // MARK: permissions

    private func requestCalendarAccess() async -> Bool {
        let store = EKEventStore()
        if #available(iOS 17.0, *) {
            return (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            return await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { granted, _ in cont.resume(returning: granted) }
            }
        }
    }

    private func requestContactsAccess() async -> Bool {
        await withCheckedContinuation { cont in
            CNContactStore().requestAccess(for: .contacts) { granted, _ in cont.resume(returning: granted) }
        }
    }

    private func calendarAuthorized() -> Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) { return s == .fullAccess }
        return s == .authorized
    }

    private func contactsAuthorized() -> Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    // MARK: sync

    @discardableResult
    func sync(account: String) async -> M9BoxSyncSummary {
        var summary = M9BoxSyncSummary()
        guard !isRunning else { return summary }
        isRunning = true
        defer { isRunning = false }
        guard let creds = M9BoxSyncCredentials(account: account) else {
            summary.error = "Sem credenciais da conta."
            return summary
        }
        NSLog("M9BoxSync: start cal=\(calendarAuthorized()) con=\(contactsAuthorized())")
        // Push local creations FIRST so the pull that follows sees the server
        // already carrying them (and never deletes a just-created local item).
        if calendarAuthorized() {
            await pushCalendar(creds, summary: &summary)
            await syncCalendar(creds, summary: &summary)
        } else { summary.error = appendError(summary.error, "Sem acesso à Agenda.") }
        if contactsAuthorized() {
            // A contact map lost to the key rename (1.0.0 -> m9box_* keys) must not
            // turn the mirrors in the group into "new" contacts to push.
            if !healLostContactMap(account: account) {
                await pushContacts(account: account, creds: creds, summary: &summary)
            }
            await syncContacts(account: account, creds: creds, summary: &summary)
        } else { summary.error = appendError(summary.error, "Sem acesso aos Contatos.") }
        NSLog("M9BoxSync: done events=\(summary.events) contacts=\(summary.contacts)")
        return summary
    }

    private func appendError(_ existing: String?, _ msg: String) -> String {
        [existing, msg].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: - Push (device -> server), CREATE only for v1

    /// Push events the user created in the M9 Box calendar (no server marker yet)
    /// up to the first writable Box calendar. Edits/deletes are a follow-up: iOS
    /// exposes no per-item dirty flag, so those need change snapshotting.
    private func pushCalendar(_ creds: M9BoxSyncCredentials, summary: inout M9BoxSyncSummary) async {
        let store = EKEventStore()
        guard let calendar = ensureCalendar(store) else { return }
        let client = M9BoxCalDavClient(baseURL: creds.baseURL, authHeader: creds.authHeader, userId: creds.userId)
        guard let collections = try? await M9BoxCalendarRepository(client: client).loadCalendars(),
              let target = collections.first(where: { !$0.readOnly }) ?? collections.first else { return }

        let start = Date().addingTimeInterval(-pastWindow)
        let end = Date().addingTimeInterval(futureWindow)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        var pushed = 0
        for ev in store.events(matching: predicate) where !(ev.url?.absoluteString.hasPrefix("m9box://") ?? false) {
            let uid = UUID().uuidString + "@m9box"
            let href = target.href.trimmedSlash + "/" + UUID().uuidString + ".ics"
            do {
                try await client.putResource(href: href, ics: buildEventICS(ev, uid: uid), ifMatch: nil, isNew: true)
                // Mark it so the pull recognises it as ours and never duplicates it.
                let marker = "m9box://" + Data("\(href)#\(ev.startDate.timeIntervalSince1970)".utf8).base64EncodedString()
                ev.url = URL(string: marker)
                try? store.save(ev, span: .thisEvent, commit: true)
                pushed += 1
            } catch {
                NSLog("M9BoxSync: push event failed: \(error)")
            }
        }
        summary.pushedEvents = pushed
    }

    /// Self-heal for a lost contact map. 1.0.0 stored the map under the old key
    /// name; after the rename an upgraded user has an EMPTY map but the group
    /// still holds the server mirrors. Pushing them would duplicate the whole
    /// address book on the server and the pull would duplicate it on the phone.
    /// So, once per account, on the first contact step: if the map is empty and
    /// the group has contacts, delete them (they are mirrors; the group is only
    /// created by the app on first enable) and skip the push of this run. The
    /// pull then re-creates them with a fresh map. The once-per-account marker
    /// keeps a later failed push from ever deleting contacts the user created.
    /// Returns true when the push must be skipped.
    private func healLostContactMap(account: String) -> Bool {
        let doneKey = contactMapKeyPrefix + "healed_" + account
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return false }
        UserDefaults.standard.set(true, forKey: doneKey)
        guard loadContactMap(account: account).isEmpty else { return false }
        let store = CNContactStore()
        guard let group = try? store.groups(matching: nil).first(where: { $0.name == groupName }),
              let contacts = try? store.unifiedContacts(
                matching: CNContact.predicateForContactsInGroup(withIdentifier: group.identifier),
                keysToFetch: [CNContactVCardSerialization.descriptorForRequiredKeys()]),
              !contacts.isEmpty else { return false }
        let save = CNSaveRequest()
        contacts.forEach { save.delete($0.mutableCopy() as! CNMutableContact) }
        try? store.execute(save)
        NSLog("M9BoxSync: contact map lost, removed \(contacts.count) mirrored contacts")
        return true
    }

    /// Push contacts the user created in the M9 Box group (not yet mapped to a
    /// server href) up to the first Box address book.
    private func pushContacts(account: String, creds: M9BoxSyncCredentials, summary: inout M9BoxSyncSummary) async {
        let store = CNContactStore()
        guard let group = ensureGroup(store) else { return }
        let client = M9BoxCardDavClient(baseURL: creds.baseURL, authHeader: creds.authHeader, userId: creds.userId)
        guard let books = try? await client.discoverAddressBooks(), let book = books.first else { return }

        var map = loadContactMap(account: account)
        let known = Set(map.values)
        let keys = [CNContactVCardSerialization.descriptorForRequiredKeys()]
        let predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else { return }

        var pushed = 0
        for c in contacts where !known.contains(c.identifier) {
            guard let data = try? CNContactVCardSerialization.data(with: [c]),
                  let vcard = String(data: data, encoding: .utf8) else { continue }
            let href = book.href.trimmedSlash + "/" + UUID().uuidString + ".vcf"
            do {
                try await client.putVCard(href: href, vcard: vcard, ifMatch: nil, isNew: true)
                map[href] = c.identifier
                pushed += 1
            } catch {
                NSLog("M9BoxSync: push contact failed: \(error)")
            }
        }
        saveContactMap(map, account: account)
        summary.pushedContacts = pushed
    }

    private func buildEventICS(_ ev: EKEvent, uid: String) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//M9 Network//M9 Box//EN", "BEGIN:VEVENT",
                     "UID:\(uid)", "DTSTAMP:\(utcStamp(Date()))"]
        if ev.isAllDay {
            lines.append("DTSTART;VALUE=DATE:\(dateStamp(ev.startDate))")
            lines.append("DTEND;VALUE=DATE:\(dateStamp(ev.endDate))")
        } else {
            lines.append("DTSTART:\(utcStamp(ev.startDate))")
            lines.append("DTEND:\(utcStamp(ev.endDate))")
        }
        lines.append("SUMMARY:\(icsEscape(ev.title ?? ""))")
        if let loc = ev.location, !loc.isEmpty { lines.append("LOCATION:\(icsEscape(loc))") }
        if let notes = ev.notes, !notes.isEmpty { lines.append("DESCRIPTION:\(icsEscape(notes))") }
        lines.append(contentsOf: ["END:VEVENT", "END:VCALENDAR"])
        return lines.joined(separator: "\r\n")
    }

    private func utcStamp(_ date: Date) -> String { stamp(date, "yyyyMMdd'T'HHmmss'Z'", utc: true) }
    private func dateStamp(_ date: Date) -> String { stamp(date, "yyyyMMdd", utc: false) }
    private func stamp(_ date: Date, _ format: String, utc: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        if utc { f.timeZone = TimeZone(identifier: "UTC") }
        return f.string(from: date)
    }
    private func icsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Calendar (EventKit)

    private func syncCalendar(_ creds: M9BoxSyncCredentials, summary: inout M9BoxSyncSummary) async {
        let store = EKEventStore()
        guard let calendar = ensureCalendar(store) else {
            summary.error = appendError(summary.error, "Não foi possível criar o calendário.")
            return
        }

        let client = M9BoxCalDavClient(baseURL: creds.baseURL, authHeader: creds.authHeader, userId: creds.userId)
        let repository = M9BoxCalendarRepository(client: client)
        let start = Date().addingTimeInterval(-pastWindow)
        let end = Date().addingTimeInterval(futureWindow)

        guard let collections = try? await repository.loadCalendars() else {
            summary.error = appendError(summary.error, "Falha ao buscar agendas.")
            return
        }
        let events = await repository.loadEvents(calendars: collections, start: start, end: end)
        summary.events = events.count
        NSLog("M9BoxSync: calendars=\(collections.count) events=\(events.count)")

        // Existing M9 Box events in the window, keyed by the marker we store in .url.
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        var existing = [String: EKEvent]()
        for ev in store.events(matching: predicate) {
            if let key = ev.url?.absoluteString { existing[key] = ev }
        }

        var seen = Set<String>()
        for event in events {
            let key = "m9box://" + Data("\(event.resourceHref)#\(event.recurrenceId?.timeIntervalSince1970 ?? event.start.timeIntervalSince1970)".utf8).base64EncodedString()
            seen.insert(key)
            let ekEvent = existing[key] ?? EKEvent(eventStore: store)
            ekEvent.calendar = calendar
            ekEvent.title = event.summary
            ekEvent.location = event.location
            ekEvent.notes = event.eventDescription
            ekEvent.startDate = event.start
            ekEvent.endDate = max(event.end, event.start.addingTimeInterval(event.allDay ? 0 : 60))
            ekEvent.isAllDay = event.allDay
            ekEvent.url = URL(string: key)
            try? store.save(ekEvent, span: .thisEvent, commit: false)
        }
        // Drop events that vanished from the server.
        for (key, ev) in existing where !seen.contains(key) {
            try? store.remove(ev, span: .thisEvent, commit: false)
        }
        try? store.commit()
    }

    /// Find or create the dedicated "M9 Box" calendar in a writable local source
    /// (never iCloud, so we don't push a mirror into the user's cloud).
    private func ensureCalendar(_ store: EKEventStore) -> EKCalendar? {
        if let existing = store.calendars(for: .event).first(where: { $0.title == calendarTitle }) {
            return existing
        }
        let source = store.sources.first(where: { $0.sourceType == .local })
            ?? store.defaultCalendarForNewEvents?.source
            ?? store.sources.first
        guard let source else { return nil }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = calendarTitle
        calendar.source = source
        calendar.cgColor = UIColor(red: 0.07, green: 0.43, blue: 0.94, alpha: 1).cgColor
        try? store.saveCalendar(calendar, commit: true)
        return calendar
    }

    // MARK: - Contacts (Contacts framework)

    private func syncContacts(account: String, creds: M9BoxSyncCredentials, summary: inout M9BoxSyncSummary) async {
        let store = CNContactStore()
        guard let group = ensureGroup(store) else {
            summary.error = appendError(summary.error, "Não foi possível criar o grupo de contatos.")
            return
        }
        summary.contactContainer = containerLabel(store, groupId: group.identifier)

        let client = M9BoxCardDavClient(baseURL: creds.baseURL, authHeader: creds.authHeader, userId: creds.userId)
        let books: [M9BoxAddressBook]
        do {
            books = try await client.discoverAddressBooks()
        } catch {
            summary.error = appendError(summary.error, "Falha ao buscar catálogos (\((error as? M9BoxCardDavError)?.code ?? -1)).")
            NSLog("M9BoxSync: carddav discover failed: \(error)")
            return
        }
        summary.addressBooks = books.count
        var remote = [M9BoxRemoteVCard]()
        for book in books {
            do {
                let cards = try await client.listContacts(addressBookHref: book.href)
                remote.append(contentsOf: cards)
            } catch {
                NSLog("M9BoxSync: carddav list \(book.href) failed: \(error)")
            }
        }
        NSLog("M9BoxSync: addressBooks=\(books.count) vcards=\(remote.count)")

        var map = loadContactMap(account: account)   // href -> saved contact identifier
        let serverHrefs = Set(remote.map { $0.href })

        // Wholesale replace per href (simplest correct upsert, like the Android store).
        var saved = 0
        for card in remote {
            guard let contact = M9BoxVCard.parse(card.vcard) else { continue }
            let save = CNSaveRequest()
            if let oldId = map[card.href], let existing = try? fetchContact(store, identifier: oldId) {
                save.delete(existing.mutableCopy() as! CNMutableContact)
            }
            save.add(contact, toContainerWithIdentifier: nil)
            save.addMember(contact, to: group)
            do {
                try store.execute(save)
                map[card.href] = contact.identifier
                saved += 1
            } catch {
                NSLog("M9BoxSync: contact save failed \(card.href): \(error)")
            }
        }
        summary.contacts = saved
        NSLog("M9BoxSync: contacts saved=\(saved)")
        // Remove contacts whose href is gone from the server.
        for (href, id) in map where !serverHrefs.contains(href) {
            if let existing = try? fetchContact(store, identifier: id) {
                let save = CNSaveRequest()
                save.delete(existing.mutableCopy() as! CNMutableContact)
                try? store.execute(save)
            }
            map.removeValue(forKey: href)
        }
        saveContactMap(map, account: account)
    }

    /// Human-readable name+type of the container the group lives in, so we can
    /// tell from the UI whether contacts landed in iCloud (syncs to Mac) or a
    /// device-local container (iPhone only).
    private func containerLabel(_ store: CNContactStore, groupId: String) -> String {
        guard let container = try? store.containers(matching:
            CNContainer.predicateForContainerOfGroup(withIdentifier: groupId)).first else { return "?" }
        let type: String
        switch container.type {
        case .local: type = "local"
        case .cardDAV: type = "iCloud/CardDAV"
        case .exchange: type = "Exchange"
        default: type = "outro"
        }
        let name = container.name.isEmpty ? "-" : container.name
        return "\(name) [\(type)]"
    }

    private func ensureGroup(_ store: CNContactStore) -> CNGroup? {
        if let existing = try? store.groups(matching: nil).first(where: { $0.name == groupName }) {
            return existing
        }
        let group = CNMutableGroup()
        group.name = groupName
        let save = CNSaveRequest()
        save.add(group, toContainerWithIdentifier: nil)
        guard (try? store.execute(save)) != nil else { return nil }
        return group
    }

    private func fetchContact(_ store: CNContactStore, identifier: String) throws -> CNContact {
        try store.unifiedContact(withIdentifier: identifier, keysToFetch: [CNContactVCardSerialization.descriptorForRequiredKeys()])
    }

    private func loadContactMap(account: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: contactMapKeyPrefix + account),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    private func saveContactMap(_ map: [String: String], account: String) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: contactMapKeyPrefix + account)
        }
    }
}

/// Credentials + endpoints for one account, built the same way the calendar tab
/// does: NCSession for urlBase/user/userId, the keychain for the password.
struct M9BoxSyncCredentials {
    let baseURL: URL
    let authHeader: String
    let userId: String

    init?(account: String) {
        let session = NCSession.shared.getSession(account: account)
        let password = NCPreferences().getPassword(account: account)
        guard !session.urlBase.isEmpty, !session.user.isEmpty, !password.isEmpty,
              let baseURL = URL(string: session.urlBase),
              let token = "\(session.user):\(password)".data(using: .utf8)?.base64EncodedString() else {
            return nil
        }
        self.baseURL = baseURL
        self.authHeader = "Basic \(token)"
        self.userId = session.userId.isEmpty ? session.user : session.userId
    }
}

private extension String {
    var trimmedSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

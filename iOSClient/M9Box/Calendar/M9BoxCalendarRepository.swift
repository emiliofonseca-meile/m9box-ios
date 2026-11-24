//
//  M9 Box - Nextcloud client branded for M9 Box
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Orchestrates CalDAV transport + iCal mapping into calendar/event operations.
//  Mirrors the Android CalendarRepository: writes always re-fetch the resource
//  first and PUT with If-Match so a concurrent edit from another client is never
//  silently lost.
//

import Foundation

final class M9BoxCalendarRepository {
    private let client: M9BoxCalDavClient

    init(client: M9BoxCalDavClient) {
        self.client = client
    }

    func loadCalendars() async throws -> [M9BoxCalendarCollection] {
        try await client.discoverCalendars()
    }

    /// Expand every visible calendar's events overlapping [start, end).
    func loadEvents(calendars: [M9BoxCalendarCollection], start: Date, end: Date) async -> [M9BoxCalEvent] {
        var out = [M9BoxCalEvent]()
        for calendar in calendars {
            let resources = (try? await client.listEvents(calendarHref: calendar.href, start: start, end: end)) ?? []
            for resource in resources {
                out.append(contentsOf: M9BoxICal.expand(collection: calendar, resource: resource, windowStart: start, windowEnd: end))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    func createEvent(_ draft: M9BoxEventDraft) async throws {
        let fileId = UUID().uuidString
        var prepared = draft
        prepared.uid = "\(fileId)@m9box"
        let ics = M9BoxICal.buildICS(prepared, uid: prepared.uid!)
        let href = draft.calendarHref.trimTrailingSlash + "/" + fileId + ".ics"
        try await client.putResource(href: href, ics: ics, ifMatch: nil, isNew: true)
    }

    func updateEvent(_ event: M9BoxCalEvent, draft: M9BoxEventDraft, scope: M9BoxRecurrenceScope) async throws {
        let existing = try await client.getResource(href: event.resourceHref)
        let slot = event.recurrenceId ?? event.start
        let write = M9BoxICal.applyScopedEdit(existingICS: existing.ics, draft: draft, scope: scope, occurrence: slot)
        try await client.putResource(href: event.resourceHref, ics: write.updatedICS, ifMatch: existing.etag, isNew: false)
        if let forked = write.newResourceICS {
            let href = event.calendarHref.trimTrailingSlash + "/" + UUID().uuidString + ".ics"
            try await client.putResource(href: href, ics: forked, ifMatch: nil, isNew: true)
        }
    }

    func deleteEvent(_ event: M9BoxCalEvent, scope: M9BoxRecurrenceScope) async throws {
        let existing = try await client.getResource(href: event.resourceHref)
        let slot = event.recurrenceId ?? event.start
        let delete = M9BoxICal.applyScopedDelete(existingICS: existing.ics, scope: scope, occurrence: slot)
        if delete.deleteResource || delete.updatedICS == nil {
            try await client.deleteResource(href: event.resourceHref, ifMatch: existing.etag)
        } else {
            try await client.putResource(href: event.resourceHref, ics: delete.updatedICS!, ifMatch: existing.etag, isNew: false)
        }
    }
}

private extension String {
    var trimTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

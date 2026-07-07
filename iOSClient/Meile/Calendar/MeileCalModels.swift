//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Native calendar module (CalDAV). Isolated under iOSClient/Meile/Calendar so
//  it never collides with upstream files on rebase. Domain models shared across
//  the iCal, CalDAV and UI layers. Mirrors the Android module's contracts.
//

import Foundation

/// A CalDAV calendar collection discovered under the user's calendar-home.
struct MeileCalendarCollection: Identifiable, Hashable {
    var href: String
    var displayName: String
    var color: String?      // "#RRGGBB"
    var ctag: String?
    var syncToken: String?
    var readOnly: Bool
    var id: String { href }
}

/// A raw iCalendar object (one `.ics` resource) as stored on the server.
struct MeileRemoteResource {
    var href: String
    var etag: String?
    var ics: String
}

/// A single expanded occurrence ready for display.
struct MeileCalEvent: Identifiable, Hashable {
    var uid: String
    var calendarHref: String
    var resourceHref: String
    var etag: String?
    var summary: String
    var location: String?
    var eventDescription: String?
    var start: Date
    var end: Date
    var allDay: Bool
    var color: String?
    var recurring: Bool
    var recurrenceId: Date?
    var isException: Bool
    var id: String { "\(resourceHref)#\(recurrenceId?.timeIntervalSince1970 ?? start.timeIntervalSince1970)" }
}

/// Scope selected by the user when editing/deleting a recurring instance.
enum MeileRecurrenceScope { case this, thisAndFuture, all }

/// A DISPLAY VALARM expressed as "minutes before start".
struct MeileReminder: Hashable { var minutesBefore: Int }

/// Editor input for creating or updating an event.
struct MeileEventDraft {
    var uid: String?
    var calendarHref: String
    var resourceHref: String?
    var etag: String?
    var summary: String
    var location: String?
    var description: String?
    var start: Date
    var end: Date
    var allDay: Bool
    var timeZoneId: String
    var rrule: String?          // e.g. "FREQ=WEEKLY" (nil = non-recurring)
    var reminders: [MeileReminder]
    var attendees: [String]
}

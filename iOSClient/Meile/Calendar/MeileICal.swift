//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Hand-rolled iCalendar engine (no third-party lib in the iOS project). Mirrors
//  the Android ical4j-based module's *verified* semantics so both platforms agree:
//    - reading: RECURRENCE-ID overrides are related to their master and replace
//      the generated occurrence (the reference RN client dropped them);
//    - writing: "this occurrence" becomes an exception VEVENT in the SAME
//      resource; delete-one uses EXDATE; "this and future" truncates the master
//      RRULE with UNTIL and forks a new series.
//

import Foundation

// MARK: - Parsed model

struct MeileRRule {
    var freq: String
    var interval: Int = 1
    var count: Int?
    var until: Date?
    var byDay: [Int] = []   // 1=Sun ... 7=Sat (Foundation Calendar convention)
}

struct MeileICalEvent {
    var uid: String
    var start: Date
    var end: Date
    var allDay: Bool
    var timeZone: TimeZone
    var summary: String
    var location: String?
    var description: String?
    var rrule: MeileRRule?
    var exDates: [Date] = []
    var recurrenceId: Date?
    var cancelled: Bool = false
}

enum MeileICal {

    // MARK: Public API

    static func expand(
        collection: MeileCalendarCollection,
        resource: MeileRemoteResource,
        windowStart: Date,
        windowEnd: Date
    ) -> [MeileCalEvent] {
        let events = parse(ics: resource.ics)
        let masters = events.filter { $0.recurrenceId == nil }
        let overrides = events.filter { $0.recurrenceId != nil }
        var overrideByKey = [Int: MeileICalEvent]()
        for o in overrides { if let r = o.recurrenceId { overrideByKey[key(r)] = o } }

        var out = [MeileCalEvent]()
        var handled = Set<Int>()

        for master in masters {
            guard master.rrule != nil else {
                if master.start < windowEnd && master.end > windowStart {
                    out.append(makeEvent(collection, resource, master, master.start, master.end, nil, recurring: false, isException: false))
                }
                continue
            }
            let duration = master.end.timeIntervalSince(master.start)
            for slot in occurrences(of: master, windowStart: windowStart, windowEnd: windowEnd) {
                let k = key(slot)
                if let override = overrideByKey[k] {
                    handled.insert(k)
                    if override.cancelled { continue }
                    out.append(makeEvent(collection, resource, override, override.start, override.end, slot, recurring: true, isException: true))
                } else {
                    out.append(makeEvent(collection, resource, master, slot, slot.addingTimeInterval(duration), slot, recurring: true, isException: false))
                }
            }
        }

        // Detached overrides moved into the window from an out-of-range slot.
        for override in overrides {
            guard let recId = override.recurrenceId, !handled.contains(key(recId)), !override.cancelled else { continue }
            if override.start < windowEnd && override.end > windowStart {
                out.append(makeEvent(collection, resource, override, override.start, override.end, recId, recurring: true, isException: true))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Occurrence start dates for a recurring master within [windowStart, windowEnd).
    static func occurrences(of master: MeileICalEvent, windowStart: Date, windowEnd: Date) -> [Date] {
        guard let rule = master.rrule else {
            return (master.start < windowEnd) ? [master.start] : []
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = master.timeZone

        var result = [Date]()
        var periodStart = master.start
        var generated = 0
        var guardIterations = 0
        let maxIterations = 3000

        while guardIterations < maxIterations {
            guardIterations += 1
            if let count = rule.count, generated >= count { break }
            if let until = rule.until, periodStart > until { break }
            if periodStart >= windowEnd { break }

            let slots: [Date] = (rule.freq == "WEEKLY" && !rule.byDay.isEmpty)
                ? weekdaySlots(weekOf: periodStart, byDay: rule.byDay, calendar: calendar, notBefore: master.start)
                : [periodStart]

            for slot in slots {
                if let count = rule.count, generated >= count { break }
                if let until = rule.until, slot > until { continue }
                if slot < master.start { continue }
                generated += 1
                if slot >= windowStart && slot < windowEnd && !isExcluded(slot, master.exDates) {
                    result.append(slot)
                }
            }
            periodStart = step(periodStart, freq: rule.freq, interval: rule.interval, calendar: calendar)
        }
        return result
    }

    // MARK: Build / edit / delete

    static func buildICS(_ draft: MeileEventDraft, uid: String) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Meile//M9 Box Calendar//EN", "CALSCALE:GREGORIAN"]
        lines += veventLines(draft, uid: uid, recurrenceId: nil)
        lines.append("END:VCALENDAR")
        return fold(lines)
    }

    struct ScopedWrite { var updatedICS: String; var newResourceICS: String? }

    static func applyScopedEdit(existingICS: String, draft: MeileEventDraft, scope: MeileRecurrenceScope, occurrence: Date) -> ScopedWrite {
        let uid = firstUID(existingICS) ?? draft.uid ?? UUID().uuidString
        switch scope {
        case .all:
            // Rebuild the master from the draft but preserve its RRULE unless the
            // draft supplies a new one (never silently drop the series).
            let preservedRule = draft.rrule ?? firstRRuleValue(existingICS)
            var d = draft; d.rrule = preservedRule
            let master = rebuildMaster(existingICS: existingICS, draft: d, uid: uid)
            return ScopedWrite(updatedICS: master, newResourceICS: nil)
        case .this:
            let updated = insertException(existingICS: existingICS, draft: draft, uid: uid, occurrence: occurrence)
            return ScopedWrite(updatedICS: updated, newResourceICS: nil)
        case .thisAndFuture:
            let truncated = truncateMaster(existingICS: existingICS, until: occurrence.addingTimeInterval(-1))
            var forked = draft; forked.uid = nil; forked.resourceHref = nil; forked.etag = nil
            return ScopedWrite(updatedICS: truncated, newResourceICS: buildICS(forked, uid: UUID().uuidString))
        }
    }

    struct ScopedDelete { var updatedICS: String?; var deleteResource: Bool }

    static func applyScopedDelete(existingICS: String, scope: MeileRecurrenceScope, occurrence: Date) -> ScopedDelete {
        switch scope {
        case .all:
            return ScopedDelete(updatedICS: nil, deleteResource: true)
        case .this:
            return ScopedDelete(updatedICS: addExDate(existingICS: existingICS, date: occurrence), deleteResource: false)
        case .thisAndFuture:
            return ScopedDelete(updatedICS: truncateMaster(existingICS: existingICS, until: occurrence.addingTimeInterval(-1)), deleteResource: false)
        }
    }

    // MARK: - Parsing

    static func parse(ics: String) -> [MeileICalEvent] {
        let logicalLines = unfold(ics)
        var events = [MeileICalEvent]()
        var inEvent = false
        var inAlarm = false
        var props = [(name: String, params: [String: String], value: String)]()
        var cancelled = false

        for line in logicalLines {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" { inEvent = true; props = []; cancelled = false; continue }
            if upper == "END:VEVENT" {
                if let e = buildEvent(from: props, cancelled: cancelled) { events.append(e) }
                inEvent = false; continue
            }
            if upper == "BEGIN:VALARM" { inAlarm = true; continue }
            if upper == "END:VALARM" { inAlarm = false; continue }
            guard inEvent, !inAlarm else { continue }
            guard let parsed = parseProperty(line) else { continue }
            if parsed.name == "STATUS" && parsed.value.uppercased() == "CANCELLED" { cancelled = true }
            props.append(parsed)
        }
        return events
    }

    private static func buildEvent(from props: [(name: String, params: [String: String], value: String)], cancelled: Bool) -> MeileICalEvent? {
        var uid = ""
        var start: (date: Date, allDay: Bool, tz: TimeZone)?
        var end: Date?
        var summary = ""
        var location: String?
        var description: String?
        var rrule: MeileRRule?
        var exDates = [Date]()
        var recurrenceId: Date?

        for p in props {
            switch p.name {
            case "UID": uid = p.value
            case "SUMMARY": summary = unescape(p.value)
            case "LOCATION": location = unescape(p.value)
            case "DESCRIPTION": description = unescape(p.value)
            case "DTSTART": start = parseDate(p.value, params: p.params)
            case "DTEND": end = parseDate(p.value, params: p.params)?.date
            case "RRULE": rrule = parseRRule(p.value)
            case "RECURRENCE-ID": recurrenceId = parseDate(p.value, params: p.params)?.date
            case "EXDATE":
                for token in p.value.split(separator: ",") {
                    if let d = parseDate(String(token), params: p.params)?.date { exDates.append(d) }
                }
            default: break
            }
        }
        guard !uid.isEmpty, let s = start else { return nil }
        let duration: TimeInterval = s.allDay ? 86_400 : 3_600
        return MeileICalEvent(
            uid: uid,
            start: s.date,
            end: end ?? s.date.addingTimeInterval(duration),
            allDay: s.allDay,
            timeZone: s.tz,
            summary: summary,
            location: location,
            description: description,
            rrule: rrule,
            exDates: exDates,
            recurrenceId: recurrenceId,
            cancelled: cancelled
        )
    }

    static func parseProperty(_ line: String) -> (name: String, params: [String: String], value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let namePart = String(line[line.startIndex..<colon])
        let value = String(line[line.index(after: colon)...])
        let segments = namePart.split(separator: ";").map(String.init)
        guard let name = segments.first?.uppercased() else { return nil }
        var params = [String: String]()
        for seg in segments.dropFirst() {
            let kv = seg.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1] }
        }
        return (name, params, value)
    }

    static func parseDate(_ value: String, params: [String: String]) -> (date: Date, allDay: Bool, tz: TimeZone)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if params["VALUE"]?.uppercased() == "DATE" || v.count == 8 {
            let tz = TimeZone(identifier: params["TZID"] ?? "") ?? TimeZone.current
            let df = DateFormatter()
            df.calendar = Calendar(identifier: .gregorian)
            df.timeZone = tz
            df.dateFormat = "yyyyMMdd"
            guard let d = df.date(from: v) else { return nil }
            return (d, true, tz)
        }
        let isUtc = v.hasSuffix("Z")
        let core = isUtc ? String(v.dropLast()) : v
        let tz = isUtc ? TimeZone(identifier: "UTC")! : (TimeZone(identifier: params["TZID"] ?? "") ?? TimeZone.current)
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = tz
        df.dateFormat = "yyyyMMdd'T'HHmmss"
        guard let d = df.date(from: core) else { return nil }
        return (d, false, tz)
    }

    static func parseRRule(_ value: String) -> MeileRRule {
        var rule = MeileRRule(freq: "DAILY")
        for part in value.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key = kv[0].uppercased()
            let v = kv[1]
            switch key {
            case "FREQ": rule.freq = v.uppercased()
            case "INTERVAL": rule.interval = max(1, Int(v) ?? 1)
            case "COUNT": rule.count = Int(v)
            case "UNTIL": rule.until = parseDate(v, params: [:])?.date
            case "BYDAY": rule.byDay = v.split(separator: ",").compactMap { weekdayNumber(String($0)) }
            default: break
            }
        }
        return rule
    }

    // MARK: - Serialisation helpers

    private static func veventLines(_ draft: MeileEventDraft, uid: String, recurrenceId: Date?) -> [String] {
        var lines = ["BEGIN:VEVENT", "UID:\(uid)", "DTSTAMP:\(utcStamp(Date()))"]
        let tz = TimeZone(identifier: draft.timeZoneId) ?? TimeZone.current
        if draft.allDay {
            lines.append("DTSTART;VALUE=DATE:\(dateStamp(draft.start, tz: tz))")
            lines.append("DTEND;VALUE=DATE:\(dateStamp(draft.end, tz: tz))")
        } else {
            lines.append("DTSTART;TZID=\(tz.identifier):\(localStamp(draft.start, tz: tz))")
            lines.append("DTEND;TZID=\(tz.identifier):\(localStamp(draft.end, tz: tz))")
        }
        if let rid = recurrenceId {
            lines.append("RECURRENCE-ID;TZID=\(tz.identifier):\(localStamp(rid, tz: tz))")
        }
        lines.append("SUMMARY:\(escape(draft.summary))")
        if let loc = draft.location, !loc.isEmpty { lines.append("LOCATION:\(escape(loc))") }
        if let desc = draft.description, !desc.isEmpty { lines.append("DESCRIPTION:\(escape(desc))") }
        if let rrule = draft.rrule, !rrule.isEmpty, recurrenceId == nil { lines.append("RRULE:\(rrule)") }
        for email in draft.attendees {
            lines.append("ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(email)")
        }
        for reminder in draft.reminders {
            lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:\(escape(draft.summary))",
                      "TRIGGER:-PT\(reminder.minutesBefore)M", "END:VALARM"]
        }
        lines.append("END:VEVENT")
        return lines
    }

    private static func rebuildMaster(existingICS: String, draft: MeileEventDraft, uid: String) -> String {
        // Preserve override VEVENTs (RECURRENCE-ID) and EXDATE lines from the
        // original resource; replace only the master VEVENT.
        let preservedExDates = firstExDateLines(existingICS)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Meile//M9 Box Calendar//EN", "CALSCALE:GREGORIAN"]
        var master = veventLines(draft, uid: uid, recurrenceId: nil)
        if let endIndex = master.firstIndex(of: "END:VEVENT") {
            master.insert(contentsOf: preservedExDates, at: endIndex)
        }
        lines += master
        lines += overrideVEvents(existingICS)
        lines.append("END:VCALENDAR")
        return fold(lines)
    }

    private static func insertException(existingICS: String, draft: MeileEventDraft, uid: String, occurrence: Date) -> String {
        var logical = unfold(existingICS).filter { !$0.uppercased().hasPrefix("END:VCALENDAR") }
        // Drop any existing override for this slot.
        logical = removeOverride(logical, forRecurrenceId: occurrence)
        var exception = veventLines(draft, uid: uid, recurrenceId: occurrence)
        // The exception is a single instance: strip any RRULE.
        exception.removeAll { $0.uppercased().hasPrefix("RRULE:") }
        logical += exception
        logical.append("END:VCALENDAR")
        return fold(logical)
    }

    private static func addExDate(existingICS: String, date: Date) -> String {
        var logical = unfold(existingICS)
        guard let masterEnd = indexOfMasterEnd(logical) else { return existingICS }
        let tz = masterTimeZone(logical)
        logical.insert("EXDATE;TZID=\(tz.identifier):\(localStamp(date, tz: tz))", at: masterEnd)
        return fold(logical)
    }

    private static func truncateMaster(existingICS: String, until: Date) -> String {
        var logical = unfold(existingICS)
        for i in logical.indices where logical[i].uppercased().hasPrefix("RRULE:") {
            let value = String(logical[i].dropFirst("RRULE:".count))
            logical[i] = "RRULE:" + truncateRRuleValue(value, until: until)
            break
        }
        return fold(logical)
    }

    static func truncateRRuleValue(_ value: String, until: Date) -> String {
        let parts = value.split(separator: ";").map(String.init)
            .filter { !$0.uppercased().hasPrefix("UNTIL=") && !$0.uppercased().hasPrefix("COUNT=") }
        return (parts + ["UNTIL=\(utcStamp(until))"]).joined(separator: ";")
    }

    // MARK: - Low-level utilities

    private static func makeEvent(
        _ collection: MeileCalendarCollection,
        _ resource: MeileRemoteResource,
        _ source: MeileICalEvent,
        _ start: Date,
        _ end: Date,
        _ recurrenceId: Date?,
        recurring: Bool,
        isException: Bool
    ) -> MeileCalEvent {
        MeileCalEvent(
            uid: source.uid,
            calendarHref: collection.href,
            resourceHref: resource.href,
            etag: resource.etag,
            summary: source.summary,
            location: source.location,
            eventDescription: source.description,
            start: start,
            end: end,
            allDay: source.allDay,
            color: collection.color,
            recurring: recurring,
            recurrenceId: recurrenceId,
            isException: isException
        )
    }

    private static func step(_ date: Date, freq: String, interval: Int, calendar: Calendar) -> Date {
        var comp = DateComponents()
        switch freq {
        case "DAILY": comp.day = interval
        case "WEEKLY": comp.day = 7 * interval
        case "MONTHLY": comp.month = interval
        case "YEARLY": comp.year = interval
        default: comp.day = interval
        }
        return calendar.date(byAdding: comp, to: date) ?? date.addingTimeInterval(86_400)
    }

    private static func weekdaySlots(weekOf date: Date, byDay: [Int], calendar: Calendar, notBefore: Date) -> [Date] {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return [date] }
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        var slots = [Date]()
        for weekday in byDay.sorted() {
            var comp = DateComponents()
            comp.weekday = weekday
            comp.hour = time.hour; comp.minute = time.minute; comp.second = time.second
            if let day = calendar.nextDate(after: weekStart.addingTimeInterval(-1), matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime),
               let withTime = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day) {
                if withTime >= notBefore || calendar.isDate(withTime, inSameDayAs: notBefore) { slots.append(withTime) }
            }
        }
        return slots.isEmpty ? [date] : slots.sorted()
    }

    private static func isExcluded(_ date: Date, _ exDates: [Date]) -> Bool {
        exDates.contains { abs($0.timeIntervalSince(date)) < 1 }
    }

    private static func key(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded()) }

    // ICS line unfolding (RFC 5545): continuation lines start with space or tab.
    static func unfold(_ ics: String) -> [String] {
        var result = [String]()
        for raw in ics.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if (line.hasPrefix(" ") || line.hasPrefix("\t")) && !result.isEmpty {
                result[result.count - 1] += String(line.dropFirst())
            } else if !line.isEmpty {
                result.append(line)
            }
        }
        return result
    }

    private static func fold(_ lines: [String]) -> String {
        // Keep it simple and interoperable: emit CRLF, no 75-octet folding needed
        // for the short lines we generate.
        lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func firstUID(_ ics: String) -> String? {
        unfold(ics).first { $0.uppercased().hasPrefix("UID:") }.map { String($0.dropFirst(4)) }
    }

    private static func firstRRuleValue(_ ics: String) -> String? {
        unfold(ics).first { $0.uppercased().hasPrefix("RRULE:") }.map { String($0.dropFirst(6)) }
    }

    private static func firstExDateLines(_ ics: String) -> [String] {
        unfold(ics).filter { $0.uppercased().hasPrefix("EXDATE") }
    }

    private static func masterTimeZone(_ logical: [String]) -> TimeZone {
        for line in logical where line.uppercased().hasPrefix("DTSTART") {
            if let parsed = parseProperty(line) { return parseDate(parsed.value, params: parsed.params)?.tz ?? .current }
        }
        return .current
    }

    private static func indexOfMasterEnd(_ logical: [String]) -> Int? {
        // END:VEVENT of the master (first VEVENT without RECURRENCE-ID).
        var start: Int?
        var hasRecurrenceId = false
        for (i, line) in logical.enumerated() {
            let u = line.uppercased()
            if u == "BEGIN:VEVENT" { start = i; hasRecurrenceId = false }
            else if u.hasPrefix("RECURRENCE-ID") { hasRecurrenceId = true }
            else if u == "END:VEVENT" { if start != nil && !hasRecurrenceId { return i } }
        }
        return nil
    }

    private static func overrideVEvents(_ ics: String) -> [String] {
        collectVEvents(unfold(ics)) { $0.contains { $0.uppercased().hasPrefix("RECURRENCE-ID") } }
    }

    private static func removeOverride(_ logical: [String], forRecurrenceId occurrence: Date) -> [String] {
        var result = [String]()
        var buffer = [String]()
        var inEvent = false
        for line in logical {
            let u = line.uppercased()
            if u == "BEGIN:VEVENT" { inEvent = true; buffer = [line]; continue }
            if u == "END:VEVENT" {
                buffer.append(line)
                let recId = buffer.first { $0.uppercased().hasPrefix("RECURRENCE-ID") }
                    .flatMap { parseProperty($0) }
                    .flatMap { parseDate($0.value, params: $0.params)?.date }
                let matches = recId.map { abs($0.timeIntervalSince(occurrence)) < 1 } ?? false
                if !matches { result += buffer }
                inEvent = false; buffer = []; continue
            }
            if inEvent { buffer.append(line) } else { result.append(line) }
        }
        return result
    }

    private static func collectVEvents(_ logical: [String], where predicate: ([String]) -> Bool) -> [String] {
        var result = [String]()
        var buffer = [String]()
        var inEvent = false
        for line in logical {
            let u = line.uppercased()
            if u == "BEGIN:VEVENT" { inEvent = true; buffer = [line]; continue }
            if u == "END:VEVENT" { buffer.append(line); if predicate(buffer) { result += buffer }; inEvent = false; continue }
            if inEvent { buffer.append(line) }
        }
        return result
    }

    // MARK: date formatting

    private static func utcStamp(_ date: Date) -> String { stamp(date, format: "yyyyMMdd'T'HHmmss'Z'", tz: TimeZone(identifier: "UTC")!) }
    private static func localStamp(_ date: Date, tz: TimeZone) -> String { stamp(date, format: "yyyyMMdd'T'HHmmss", tz: tz) }
    private static func dateStamp(_ date: Date, tz: TimeZone) -> String { stamp(date, format: "yyyyMMdd", tz: tz) }

    private static func stamp(_ date: Date, format: String, tz: TimeZone) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        df.dateFormat = format
        return df.string(from: date)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func weekdayNumber(_ token: String) -> Int? {
        switch token.uppercased().suffix(2) {
        case "SU": return 1
        case "MO": return 2
        case "TU": return 3
        case "WE": return 4
        case "TH": return 5
        case "FR": return 6
        case "SA": return 7
        default: return nil
        }
    }
}

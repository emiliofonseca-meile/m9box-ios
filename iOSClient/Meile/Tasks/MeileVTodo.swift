//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  VTODO parsing/building for the Tasks module. Reuses MeileICal's line
//  unfolding, property and date parsing. Edits never rebuild a task from
//  scratch: they rewrite only the properties the app owns inside the existing
//  VTODO, so fields other clients set (categories, alarms, parent, ...) survive.
//

import Foundation

struct MeileTask: Identifiable, Hashable {
    var uid: String
    var listHref: String
    var resourceHref: String
    var etag: String?
    var title: String
    var notes: String?
    var due: Date?
    var dueAllDay: Bool
    var completed: Bool
    var priority: Int          // RFC 5545: 0 = none, 1 = highest ... 9 = lowest
    var recurring: Bool
    var parentUid: String?     // RELATED-TO (no RELTYPE or PARENT): Nextcloud Tasks subtasks and Deck cards
    var id: String { resourceHref }
}

/// Editor input for creating or updating a task.
struct MeileTaskDraft {
    var title: String
    var notes: String?
    var due: Date?
    var dueAllDay: Bool
    var completed: Bool
    var priority: Int
}

enum MeileVTodo {

    // MARK: Parse

    static func parse(list: MeileCalendarCollection, resource: MeileRemoteResource) -> [MeileTask] {
        var tasks = [MeileTask]()
        var inTodo = false
        var alarmDepth = 0
        var props = [(name: String, params: [String: String], value: String)]()
        for line in MeileICal.unfold(resource.ics) {
            let upper = line.uppercased()
            if upper == "BEGIN:VTODO" { inTodo = true; props = []; alarmDepth = 0; continue }
            if upper == "END:VTODO" {
                if let t = build(props, list: list, resource: resource) { tasks.append(t) }
                inTodo = false; continue
            }
            guard inTodo else { continue }
            if upper == "BEGIN:VALARM" { alarmDepth += 1; continue }
            if upper == "END:VALARM" { alarmDepth -= 1; continue }
            guard alarmDepth == 0, let p = MeileICal.parseProperty(line) else { continue }
            props.append(p)
        }
        return tasks
    }

    private static func build(_ props: [(name: String, params: [String: String], value: String)],
                              list: MeileCalendarCollection, resource: MeileRemoteResource) -> MeileTask? {
        var uid = "", title = "", status = ""
        var notes: String?
        var due: (date: Date, allDay: Bool, tz: TimeZone)?
        var priority = 0
        var hasCompletedStamp = false, recurring = false, isOverride = false
        var parentUid: String?, hasParent = false
        for p in props {
            switch p.name {
            case "UID": uid = p.value
            case "SUMMARY": title = MeileICal.unescape(p.value)
            case "DESCRIPTION": notes = MeileICal.unescape(p.value)
            case "DUE": due = MeileICal.parseDate(p.value, params: p.params)
            case "STATUS": status = p.value.uppercased()
            case "COMPLETED": hasCompletedStamp = true
            case "PRIORITY": priority = Int(p.value) ?? 0
            case "RRULE": recurring = true
            case "RECURRENCE-ID": isOverride = true
            case "RELATED-TO":
                // First PARENT link wins; RELTYPE=CHILD/SIBLING point elsewhere.
                let type = p.params["RELTYPE"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).uppercased()
                if !hasParent, type == nil || type == "PARENT" {
                    hasParent = true
                    let value = p.value.trimmingCharacters(in: .whitespaces)
                    parentUid = value.isEmpty ? nil : value
                }
            default: break
            }
        }
        // Overrides of a recurring task are not listed separately.
        guard !uid.isEmpty, !isOverride else { return nil }
        return MeileTask(uid: uid, listHref: list.href, resourceHref: resource.href, etag: resource.etag,
                         title: title, notes: notes, due: due?.date, dueAllDay: due?.allDay ?? false,
                         completed: status == "COMPLETED" || hasCompletedStamp, priority: priority,
                         recurring: recurring, parentUid: parentUid)
    }

    // MARK: Write

    static func buildICS(_ draft: MeileTaskDraft, uid: String, now: Date = Date()) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//M9 Box//Tasks//EN", "BEGIN:VTODO", "UID:\(uid)", "CREATED:\(utc(now))"]
        lines += managedLines(draft, now: now)
        lines += ["END:VTODO", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Rewrites the app-owned properties of the master VTODO in `existing`.
    static func applyEdit(existingICS: String, draft: MeileTaskDraft, now: Date = Date()) -> String {
        var out = [String]()
        var buffer: [String]?
        var masterDone = false
        for line in MeileICal.unfold(existingICS) {
            let upper = line.uppercased()
            if upper == "BEGIN:VTODO" { buffer = [line]; continue }
            guard var todo = buffer else { out.append(line); continue }
            todo.append(line)
            buffer = todo
            if upper == "END:VTODO" {
                let isOverride = todo.contains { $0.uppercased().hasPrefix("RECURRENCE-ID") }
                out += (masterDone || isOverride) ? todo : rewrite(todo, draft, now)
                masterDone = masterDone || !isOverride
                buffer = nil
            }
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    /// Drops the managed properties (outside VALARMs) and appends fresh ones.
    private static func rewrite(_ todo: [String], _ draft: MeileTaskDraft, _ now: Date) -> [String] {
        var kept = [String]()
        var alarmDepth = 0
        for line in todo.dropLast() {
            let upper = line.uppercased()
            if upper == "BEGIN:VALARM" { alarmDepth += 1 }
            if !(alarmDepth == 0 && managed.contains(propName(line))) { kept.append(line) }
            if upper == "END:VALARM" { alarmDepth -= 1 }
        }
        return kept + managedLines(draft, now: now) + [todo.last!]
    }

    // MARK: helpers

    private static let managed: Set<String> = ["SUMMARY", "DESCRIPTION", "DUE", "STATUS", "COMPLETED",
                                                "PERCENT-COMPLETE", "PRIORITY", "LAST-MODIFIED", "DTSTAMP"]

    private static func propName(_ line: String) -> String {
        let end = line.firstIndex(where: { $0 == ":" || $0 == ";" }) ?? line.endIndex
        return String(line[line.startIndex..<end]).uppercased()
    }

    private static func managedLines(_ d: MeileTaskDraft, now: Date) -> [String] {
        var l = ["DTSTAMP:\(utc(now))", "LAST-MODIFIED:\(utc(now))", "SUMMARY:\(MeileICal.escape(d.title))"]
        if let n = d.notes, !n.isEmpty { l.append("DESCRIPTION:\(MeileICal.escape(n))") }
        if let due = d.due {
            l.append(d.dueAllDay ? "DUE;VALUE=DATE:\(format(due, "yyyyMMdd", .current))" : "DUE:\(utc(due))")
        }
        if d.priority > 0 { l.append("PRIORITY:\(d.priority)") }
        if d.completed {
            l += ["STATUS:COMPLETED", "PERCENT-COMPLETE:100", "COMPLETED:\(utc(now))"]
        } else {
            l.append("STATUS:NEEDS-ACTION")
        }
        return l
    }

    private static func utc(_ date: Date) -> String { format(date, "yyyyMMdd'T'HHmmss'Z'", TimeZone(identifier: "UTC")!) }

    private static func format(_ date: Date, _ pattern: String, _ tz: TimeZone) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        df.dateFormat = pattern
        return df.string(from: date)
    }
}

/// One row of the tasks screen: a task and how deep it sits under its parents.
struct MeileTaskNode: Identifiable {
    let task: MeileTask
    let depth: Int
    var id: String { task.id }
}

enum MeileTaskTree {
    /// Depth-first rows for ONE section (open or done), already filtered and in display order.
    /// A parent is a task of the same section and list whose uid is `parentUid` (first in section
    /// order wins on duplicate uids); a child whose parent is in the other section is a root here.
    /// Cycle members are never reached from a root, so they are emitted afterwards as roots.
    static func flatten(_ tasks: [MeileTask]) -> [MeileTaskNode] {
        var byKey = [String: Int]()
        for (i, t) in tasks.enumerated() where byKey[t.listHref + "\n" + t.uid] == nil { byKey[t.listHref + "\n" + t.uid] = i }
        var children = [Int: [Int]]()
        var roots = [Int]()
        for (i, t) in tasks.enumerated() {
            if let uid = t.parentUid, let p = byKey[t.listHref + "\n" + uid], p != i { children[p, default: []].append(i) }
            else { roots.append(i) }
        }
        var out = [MeileTaskNode]()
        var visited = Set<Int>()
        func visit(_ i: Int, _ depth: Int) {
            guard visited.insert(i).inserted else { return }
            out.append(MeileTaskNode(task: tasks[i], depth: depth))
            for c in children[i] ?? [] { visit(c, depth + 1) }
        }
        for r in roots { visit(r, 0) }
        for i in tasks.indices { visit(i, 0) }
        return out
    }
}

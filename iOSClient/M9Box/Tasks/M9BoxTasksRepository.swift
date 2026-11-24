//
//  M9 Box - Nextcloud client branded for M9 Box
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Task lists and tasks over CalDAV. Writes send the ETag the screen loaded
//  (task.etag) as If-Match, so an edit made from another client (webmail,
//  Nextcloud Tasks) after the list was loaded is never silently overwritten: the
//  write comes back as HTTP 412 and the screen reloads. update() re-fetches the
//  ICS only as the base for applyEdit (keeps unknown properties and VALARMs).
//  setCompleted() rebuilds its draft from the loaded task, which is safe because
//  the same If-Match guarantees the server copy still equals that task.
//

import Foundation

final class M9BoxTasksRepository {
    private let client: M9BoxCalDavClient

    init(client: M9BoxCalDavClient) { self.client = client }

    func loadLists() async throws -> [M9BoxCalendarCollection] { try await client.discoverTaskLists() }

    func createList(name: String) async throws { try await client.createTaskList(name: name) }

    func loadTasks(list: M9BoxCalendarCollection) async throws -> [M9BoxTask] {
        let resources = try await client.listTodos(calendarHref: list.href)
        return resources.flatMap { M9BoxVTodo.parse(list: list, resource: $0) }
    }

    func create(_ draft: M9BoxTaskDraft, in list: M9BoxCalendarCollection) async throws {
        let fileId = UUID().uuidString
        let ics = M9BoxVTodo.buildICS(draft, uid: "\(fileId)@m9box")
        let href = (list.href.hasSuffix("/") ? String(list.href.dropLast()) : list.href) + "/" + fileId + ".ics"
        try await client.putResource(href: href, ics: ics, ifMatch: nil, isNew: true)
    }

    func update(_ task: M9BoxTask, draft: M9BoxTaskDraft) async throws {
        let existing = try await client.getResource(href: task.resourceHref)
        let ics = M9BoxVTodo.applyEdit(existingICS: existing.ics, draft: draft)
        try await client.putResource(href: task.resourceHref, ics: ics, ifMatch: task.etag, isNew: false)
    }

    func setCompleted(_ task: M9BoxTask, _ completed: Bool) async throws {
        try await update(task, draft: M9BoxTaskDraft(title: task.title, notes: task.notes, due: task.due,
                                                      dueAllDay: task.dueAllDay, completed: completed,
                                                      priority: task.priority))
    }

    func delete(_ task: M9BoxTask) async throws {
        try await client.deleteResource(href: task.resourceHref, ifMatch: task.etag)
    }
}

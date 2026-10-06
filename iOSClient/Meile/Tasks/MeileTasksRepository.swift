//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Task lists and tasks over CalDAV. Like the calendar repository, every write
//  re-fetches the resource first and PUTs with If-Match, so an edit made from
//  another client (webmail, Nextcloud Tasks) is never silently overwritten: a
//  stale write comes back as HTTP 412 and the screen reloads.
//

import Foundation

final class MeileTasksRepository {
    private let client: MeileCalDavClient

    init(client: MeileCalDavClient) { self.client = client }

    func loadLists() async throws -> [MeileCalendarCollection] { try await client.discoverTaskLists() }

    func createList(name: String) async throws { try await client.createTaskList(name: name) }

    func loadTasks(list: MeileCalendarCollection) async throws -> [MeileTask] {
        let resources = try await client.listTodos(calendarHref: list.href)
        return resources.flatMap { MeileVTodo.parse(list: list, resource: $0) }
    }

    func create(_ draft: MeileTaskDraft, in list: MeileCalendarCollection) async throws {
        let fileId = UUID().uuidString
        let ics = MeileVTodo.buildICS(draft, uid: "\(fileId)@m9box")
        let href = (list.href.hasSuffix("/") ? String(list.href.dropLast()) : list.href) + "/" + fileId + ".ics"
        try await client.putResource(href: href, ics: ics, ifMatch: nil, isNew: true)
    }

    func update(_ task: MeileTask, draft: MeileTaskDraft) async throws {
        let existing = try await client.getResource(href: task.resourceHref)
        let ics = MeileVTodo.applyEdit(existingICS: existing.ics, draft: draft)
        try await client.putResource(href: task.resourceHref, ics: ics, ifMatch: existing.etag, isNew: false)
    }

    func setCompleted(_ task: MeileTask, _ completed: Bool) async throws {
        try await update(task, draft: MeileTaskDraft(title: task.title, notes: task.notes, due: task.due,
                                                      dueAllDay: task.dueAllDay, completed: completed,
                                                      priority: task.priority))
    }

    func delete(_ task: MeileTask) async throws {
        let existing = try await client.getResource(href: task.resourceHref)
        try await client.deleteResource(href: task.resourceHref, ifMatch: existing.etag)
    }
}

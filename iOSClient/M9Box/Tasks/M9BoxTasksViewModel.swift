//
//  M9 Box - Nextcloud client branded for M9 Box
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Combine

@MainActor
final class M9BoxTasksViewModel: ObservableObject {
    @Published var loading = true
    @Published var error: String?
    @Published var lists: [M9BoxCalendarCollection] = []
    @Published var selected: M9BoxCalendarCollection?
    @Published private(set) var tasks: [M9BoxTask] = []
    @Published var showCompleted = false

    private let repository: M9BoxTasksRepository

    init(repository: M9BoxTasksRepository) { self.repository = repository }

    /// Open tasks first, then completed ones (when shown); each section is its own tree.
    var visibleTasks: [M9BoxTaskNode] {
        M9BoxTaskTree.flatten(sorted(tasks.filter { !$0.completed }))
            + (showCompleted ? M9BoxTaskTree.flatten(sorted(tasks.filter { $0.completed })) : [])
    }

    private func sorted(_ list: [M9BoxTask]) -> [M9BoxTask] {
        list.sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    func start() { reload(discover: true) }

    func select(_ list: M9BoxCalendarCollection) { selected = list; reload(discover: false) }

    func reload(discover: Bool = false) {
        loading = true
        Task {
            do {
                if discover || lists.isEmpty {
                    lists = try await repository.loadLists()
                    if selected == nil || !lists.contains(where: { $0.href == selected?.href }) {
                        selected = lists.first { !$0.readOnly } ?? lists.first
                    }
                }
                if let list = selected { tasks = try await repository.loadTasks(list: list) } else { tasks = [] }
            } catch { self.error = message(error) }
            loading = false
        }
    }

    func createList(name: String) {
        perform { try await self.repository.createList(name: name) } then: { self.reload(discover: true) }
    }

    func save(_ draft: M9BoxTaskDraft, editing: M9BoxTask?) {
        perform {
            if let editing { try await self.repository.update(editing, draft: draft) }
            else if let list = self.selected { try await self.repository.create(draft, in: list) }
        } then: { self.reload() }
    }

    func toggle(_ task: M9BoxTask) {
        perform { try await self.repository.setCompleted(task, !task.completed) } then: { self.reload() }
    }

    func delete(_ task: M9BoxTask) {
        perform { try await self.repository.delete(task) } then: { self.reload() }
    }

    private func perform(_ block: @escaping () async throws -> Void, then: @escaping () -> Void) {
        loading = true
        error = nil
        Task {
            do { try await block() } catch {
                self.error = message(error)
            }
            then()
        }
    }

    private func message(_ error: Error) -> String {
        if let e = error as? M9BoxCalDavError {
            if e.code == 412 { return NSLocalizedString("_tasks_conflict_", comment: "") }
            return String(format: NSLocalizedString("_tasks_http_error_", comment: ""), e.code)
        }
        return error.localizedDescription
    }
}

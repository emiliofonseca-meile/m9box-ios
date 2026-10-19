//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Combine

@MainActor
final class MeileTasksViewModel: ObservableObject {
    @Published var loading = true
    @Published var error: String?
    @Published var lists: [MeileCalendarCollection] = []
    @Published var selected: MeileCalendarCollection?
    @Published private(set) var tasks: [MeileTask] = []
    @Published var showCompleted = false

    private let repository: MeileTasksRepository

    init(repository: MeileTasksRepository) { self.repository = repository }

    /// Open tasks first, then completed ones (when shown); each section is its own tree.
    var visibleTasks: [MeileTaskNode] {
        MeileTaskTree.flatten(sorted(tasks.filter { !$0.completed }))
            + (showCompleted ? MeileTaskTree.flatten(sorted(tasks.filter { $0.completed })) : [])
    }

    private func sorted(_ list: [MeileTask]) -> [MeileTask] {
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

    func select(_ list: MeileCalendarCollection) { selected = list; reload(discover: false) }

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

    func save(_ draft: MeileTaskDraft, editing: MeileTask?) {
        perform {
            if let editing { try await self.repository.update(editing, draft: draft) }
            else if let list = self.selected { try await self.repository.create(draft, in: list) }
        } then: { self.reload() }
    }

    func toggle(_ task: MeileTask) {
        perform { try await self.repository.setCompleted(task, !task.completed) } then: { self.reload() }
    }

    func delete(_ task: MeileTask) {
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
        if let e = error as? MeileCalDavError {
            if e.code == 412 { return NSLocalizedString("_tasks_conflict_", comment: "") }
            return String(format: NSLocalizedString("_tasks_http_error_", comment: ""), e.code)
        }
        return error.localizedDescription
    }
}

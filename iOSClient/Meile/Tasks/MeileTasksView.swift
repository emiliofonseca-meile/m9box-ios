//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Tasks screen: list picker, checklist (tap the circle to complete), and an
//  editor sheet. Data comes from the Box over CalDAV (VTODO), so the same tasks
//  show up in the webmail and in Nextcloud Tasks.
//

import SwiftUI

struct MeileTasksView: View {
    @StateObject private var viewModel: MeileTasksViewModel
    @State private var editorTask: MeileTask?
    @State private var showEditor = false
    @State private var showNewList = false
    @State private var newListName = ""

    init(repository: MeileTasksRepository) {
        _viewModel = StateObject(wrappedValue: MeileTasksViewModel(repository: repository))
    }

    var body: some View {
        List {
            if let error = viewModel.error {
                Text(error).foregroundColor(.red).font(.footnote)
            }
            if viewModel.lists.count > 1 {
                Picker(NSLocalizedString("_tasks_list_", comment: ""), selection: listBinding) {
                    ForEach(viewModel.lists) { Text($0.displayName).tag($0.href) }
                }
            }
            if viewModel.lists.isEmpty && !viewModel.loading {
                Section {
                    Text(NSLocalizedString("_tasks_no_list_", comment: "")).font(.subheadline)
                    Button(NSLocalizedString("_tasks_create_list_", comment: "")) { showNewList = true }
                }
            } else {
                Section {
                    ForEach(viewModel.visibleTasks) { task in
                        row(task)
                    }
                    if viewModel.visibleTasks.isEmpty && !viewModel.loading {
                        Text(NSLocalizedString("_tasks_empty_", comment: "")).foregroundColor(.secondary)
                    }
                }
                Section {
                    Toggle(NSLocalizedString("_tasks_show_completed_", comment: ""), isOn: $viewModel.showCompleted)
                }
            }
        }
        .overlay { if viewModel.loading { ProgressView() } }
        .navigationTitle(NSLocalizedString("_meile_tasks_", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editorTask = nil; showEditor = true } label: { Image(systemName: "plus") }
                    .disabled(viewModel.selected == nil)
                    .accessibilityLabel(NSLocalizedString("_tasks_new_", comment: ""))
            }
        }
        .refreshable { viewModel.reload(discover: true) }
        .sheet(isPresented: $showEditor) {
            MeileTaskEditor(task: editorTask) { draft in viewModel.save(draft, editing: editorTask) }
        }
        .alert(NSLocalizedString("_tasks_create_list_", comment: ""), isPresented: $showNewList) {
            TextField(NSLocalizedString("_tasks_list_name_", comment: ""), text: $newListName)
            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) { newListName = "" }
            Button(NSLocalizedString("_save_", comment: "")) {
                let name = newListName.trimmingCharacters(in: .whitespaces)
                newListName = ""
                if !name.isEmpty { viewModel.createList(name: name) }
            }
        }
        .onAppear { if viewModel.lists.isEmpty { viewModel.start() } }
    }

    private var listBinding: Binding<String> {
        Binding(get: { viewModel.selected?.href ?? "" },
                set: { href in if let l = viewModel.lists.first(where: { $0.href == href }) { viewModel.select(l) } })
    }

    private func row(_ task: MeileTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { viewModel.toggle(task) } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(task.completed ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.title)
            .accessibilityValue(task.completed ? NSLocalizedString("_tasks_completed_", comment: "") : "")
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? "-" : task.title)
                    .strikethrough(task.completed)
                    .foregroundColor(task.completed ? .secondary : .primary)
                if let due = task.due {
                    Text(dueText(due, allDay: task.dueAllDay))
                        .font(.caption)
                        .foregroundColor(!task.completed && due < Date() ? .red : .secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { editorTask = task; showEditor = true }
        .swipeActions {
            Button(role: .destructive) { viewModel.delete(task) } label: {
                Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
            }
        }
    }

    private func dueText(_ date: Date, allDay: Bool) -> String {
        date.formatted(allDay ? .dateTime.day().month().year() : .dateTime.day().month().year().hour().minute())
    }
}

struct MeileTaskEditor: View {
    let task: MeileTask?
    let onSave: (MeileTaskDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var notes: String
    @State private var hasDue: Bool
    @State private var withTime: Bool
    @State private var due: Date
    @State private var priority: Int

    init(task: MeileTask?, onSave: @escaping (MeileTaskDraft) -> Void) {
        self.task = task
        self.onSave = onSave
        _title = State(initialValue: task?.title ?? "")
        _notes = State(initialValue: task?.notes ?? "")
        _hasDue = State(initialValue: task?.due != nil)
        _withTime = State(initialValue: task.map { $0.due != nil && !$0.dueAllDay } ?? false)
        _due = State(initialValue: task?.due ?? Date())
        _priority = State(initialValue: task?.priority ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("_tasks_title_field_", comment: ""), text: $title)
                TextField(NSLocalizedString("_tasks_notes_", comment: ""), text: $notes, axis: .vertical)
                    .lineLimit(3...8)
                Section {
                    Toggle(NSLocalizedString("_tasks_due_", comment: ""), isOn: $hasDue)
                    if hasDue {
                        Toggle(NSLocalizedString("_tasks_with_time_", comment: ""), isOn: $withTime)
                        DatePicker("", selection: $due, displayedComponents: withTime ? [.date, .hourAndMinute] : [.date])
                            .labelsHidden()
                    }
                }
                Picker(NSLocalizedString("_tasks_priority_", comment: ""), selection: $priority) {
                    Text(NSLocalizedString("_tasks_priority_none_", comment: "")).tag(0)
                    Text(NSLocalizedString("_tasks_priority_high_", comment: "")).tag(1)
                    Text(NSLocalizedString("_tasks_priority_medium_", comment: "")).tag(5)
                    Text(NSLocalizedString("_tasks_priority_low_", comment: "")).tag(9)
                }
            }
            .navigationTitle(NSLocalizedString(task == nil ? "_tasks_new_" : "_tasks_edit_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("_save_", comment: "")) {
                        onSave(MeileTaskDraft(title: title.trimmingCharacters(in: .whitespaces),
                                              notes: notes.isEmpty ? nil : notes,
                                              due: hasDue ? due : nil, dueAllDay: !withTime,
                                              completed: task?.completed ?? false, priority: priority))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

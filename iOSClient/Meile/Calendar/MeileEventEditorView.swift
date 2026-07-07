//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Event editor form, mirroring the Android EventEditorScreen: title/location/
//  description, all-day switch, start/end pickers, recurrence + reminder pickers,
//  target calendar, and — for recurring events — a scope prompt (this / this and
//  future / all) before saving or deleting. Portuguese UI.
//

import SwiftUI

struct MeileEventEditorView: View {
    let editing: MeileCalEvent?
    let calendars: [MeileCalendarCollection]
    let onSave: (MeileEventDraft, MeileRecurrenceScope) -> Void
    let onDelete: (MeileRecurrenceScope) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var summary: String
    @State private var location: String
    @State private var descriptionText: String
    @State private var allDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var rrule: String?
    @State private var reminderMinutes: Int?
    @State private var calendarHref: String

    @State private var scopePrompt: PendingAction?

    private let initial: MeileEventDraft

    private enum PendingAction: Identifiable {
        case save, delete
        var id: Int { self == .save ? 0 : 1 }
    }

    private struct RecurrenceOption { let label: String; let rrule: String? }
    private struct ReminderOption { let label: String; let minutes: Int? }

    private let recurrenceOptions: [RecurrenceOption] = [
        .init(label: "Não repete", rrule: nil),
        .init(label: "Diariamente", rrule: "FREQ=DAILY"),
        .init(label: "Semanalmente", rrule: "FREQ=WEEKLY"),
        .init(label: "Mensalmente", rrule: "FREQ=MONTHLY"),
        .init(label: "Anualmente", rrule: "FREQ=YEARLY")
    ]

    private let reminderOptions: [ReminderOption] = [
        .init(label: "Sem lembrete", minutes: nil),
        .init(label: "No horário", minutes: 0),
        .init(label: "10 min antes", minutes: 10),
        .init(label: "1 hora antes", minutes: 60),
        .init(label: "1 dia antes", minutes: 1440)
    ]

    init(editing: MeileCalEvent?,
         initial: MeileEventDraft,
         calendars: [MeileCalendarCollection],
         onSave: @escaping (MeileEventDraft, MeileRecurrenceScope) -> Void,
         onDelete: @escaping (MeileRecurrenceScope) -> Void) {
        self.editing = editing
        self.initial = initial
        self.calendars = calendars
        self.onSave = onSave
        self.onDelete = onDelete
        _summary = State(initialValue: initial.summary)
        _location = State(initialValue: initial.location ?? "")
        _descriptionText = State(initialValue: initial.description ?? "")
        _allDay = State(initialValue: initial.allDay)
        _start = State(initialValue: initial.start)
        _end = State(initialValue: initial.end)
        _rrule = State(initialValue: initial.rrule)
        _reminderMinutes = State(initialValue: initial.reminders.first?.minutesBefore)
        let firstWritable = calendars.first { !$0.readOnly }?.href ?? calendars.first?.href ?? ""
        _calendarHref = State(initialValue: initial.calendarHref.isEmpty ? firstWritable : initial.calendarHref)
    }

    private var writableCalendars: [MeileCalendarCollection] {
        let writable = calendars.filter { !$0.readOnly }
        return writable.isEmpty ? calendars : writable
    }

    var body: some View {
        Form {
            Section {
                TextField("Título", text: $summary)
                Toggle("Dia inteiro", isOn: $allDay)
                DatePicker("Início", selection: $start, displayedComponents: pickerComponents)
                DatePicker("Fim", selection: $end, displayedComponents: pickerComponents)
            }

            Section {
                TextField("Local", text: $location)
                TextField("Descrição", text: $descriptionText, axis: .vertical)
            }

            Section {
                Picker("Repetição", selection: rruleBinding) {
                    ForEach(recurrenceOptions.indices, id: \.self) { i in
                        Text(recurrenceOptions[i].label).tag(recurrenceOptions[i].rrule ?? "")
                    }
                }
                Picker("Lembrete", selection: reminderBinding) {
                    ForEach(reminderOptions.indices, id: \.self) { i in
                        Text(reminderOptions[i].label).tag(reminderOptions[i].minutes ?? -1)
                    }
                }
                if writableCalendars.count > 1 {
                    Picker("Agenda", selection: $calendarHref) {
                        ForEach(writableCalendars) { cal in
                            Text(cal.displayName).tag(cal.href)
                        }
                    }
                }
            }

            if editing != nil {
                Section {
                    Button(role: .destructive) { requestDelete() } label: {
                        Text("Excluir").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle(editing == nil ? "Novo evento" : "Editar evento")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Salvar") { requestSave() }
            }
        }
        .confirmationDialog("Evento recorrente", isPresented: scopeBinding, titleVisibility: .visible) {
            Button("Somente este") { resolveScope(.this) }
            Button("Este e os seguintes") { resolveScope(.thisAndFuture) }
            Button("Todos") { resolveScope(.all) }
            Button("Cancelar", role: .cancel) { scopePrompt = nil }
        } message: {
            Text("Aplicar a:")
        }
    }

    private var pickerComponents: DatePickerComponents {
        allDay ? [.date] : [.date, .hourAndMinute]
    }

    // MARK: bindings

    private var rruleBinding: Binding<String> {
        Binding(get: { rrule ?? "" }, set: { rrule = $0.isEmpty ? nil : $0 })
    }

    private var reminderBinding: Binding<Int> {
        Binding(get: { reminderMinutes ?? -1 }, set: { reminderMinutes = $0 < 0 ? nil : $0 })
    }

    private var scopeBinding: Binding<Bool> {
        Binding(get: { scopePrompt != nil }, set: { if !$0 { scopePrompt = nil } })
    }

    // MARK: actions

    private func buildDraft() -> MeileEventDraft {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespaces)
        let fallbackDuration: TimeInterval = allDay ? 86_400 : 3_600
        let safeEnd = end > start ? end : start.addingTimeInterval(fallbackDuration)
        return MeileEventDraft(
            uid: initial.uid,
            calendarHref: calendarHref,
            resourceHref: initial.resourceHref,
            etag: initial.etag,
            summary: trimmedSummary.isEmpty ? "(sem título)" : trimmedSummary,
            location: location.trimmedNonEmpty,
            description: descriptionText.trimmedNonEmpty,
            start: start,
            end: safeEnd,
            allDay: allDay,
            timeZoneId: initial.timeZoneId,
            rrule: rrule,
            reminders: reminderMinutes.map { [MeileReminder(minutesBefore: $0)] } ?? [],
            attendees: initial.attendees
        )
    }

    private func requestSave() {
        if editing?.recurring == true {
            scopePrompt = .save
        } else {
            onSave(buildDraft(), .all)
            dismiss()
        }
    }

    private func requestDelete() {
        if editing?.recurring == true {
            scopePrompt = .delete
        } else {
            onDelete(.all)
            dismiss()
        }
    }

    private func resolveScope(_ scope: MeileRecurrenceScope) {
        let action = scopePrompt
        scopePrompt = nil
        switch action {
        case .save: onSave(buildDraft(), scope)
        case .delete: onDelete(scope)
        case .none: return
        }
        dismiss()
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

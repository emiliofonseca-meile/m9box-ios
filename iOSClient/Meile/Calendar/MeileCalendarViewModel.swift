//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Observable state for the calendar UI. Mirrors the Android CalendarViewModel:
//  month navigation, per-calendar visibility, day selection, and CRUD that always
//  re-loads the visible month afterwards so the grid reflects the server.
//

import Foundation
import Combine

@MainActor
final class MeileCalendarViewModel: ObservableObject {
    @Published var loading = true
    @Published var error: String?
    @Published var calendars: [MeileCalendarCollection] = []
    @Published var hidden: Set<String> = []
    @Published var monthStart: Date
    @Published var selectedDay: Date
    @Published private(set) var monthEvents: [MeileCalEvent] = []

    let timeZoneId: String = TimeZone.current.identifier
    private let repository: MeileCalendarRepository
    private var calendar: Calendar

    init(repository: MeileCalendarRepository, now: Date = Date()) {
        self.repository = repository
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        self.calendar = cal
        self.monthStart = MeileCalendarViewModel.startOfMonth(now, cal)
        self.selectedDay = cal.startOfDay(for: now)
    }

    /// Writable calendar to default new events into, falling back to the first.
    var defaultCalendar: MeileCalendarCollection? {
        calendars.first { !$0.readOnly } ?? calendars.first
    }

    func start() { refresh() }

    func refresh() {
        loading = true
        error = nil
        let month = monthStart
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: month) ?? month
        Task {
            do {
                let cals = calendars.isEmpty ? try await repository.loadCalendars() : calendars
                let visible = cals.filter { !hidden.contains($0.href) }
                let events = await repository.loadEvents(calendars: visible, start: month, end: monthEnd)
                self.calendars = cals
                self.monthEvents = events
                self.loading = false
            } catch {
                self.error = error.localizedDescription
                self.loading = false
            }
        }
    }

    func goToMonth(offset: Int) {
        monthStart = calendar.date(byAdding: .month, value: offset, to: monthStart) ?? monthStart
        refresh()
    }

    func selectDay(_ day: Date) {
        selectedDay = calendar.startOfDay(for: day)
    }

    func toggleCalendar(_ href: String) {
        if hidden.contains(href) { hidden.remove(href) } else { hidden.insert(href) }
        refresh()
    }

    func save(draft: MeileEventDraft, editing: MeileCalEvent?, scope: MeileRecurrenceScope) {
        run("save") {
            if let editing = editing {
                try await self.repository.updateEvent(editing, draft: draft, scope: scope)
            } else {
                try await self.repository.createEvent(draft)
            }
        }
    }

    func delete(event: MeileCalEvent, scope: MeileRecurrenceScope) {
        run("delete") { try await self.repository.deleteEvent(event, scope: scope) }
    }

    /// Events overlapping the given day, sorted by start.
    func eventsForDay(_ day: Date) -> [MeileCalEvent] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        return monthEvents
            .filter { !hidden.contains($0.calendarHref) }
            .filter { $0.start < dayEnd && $0.end > dayStart }
            .sorted { $0.start < $1.start }
    }

    /// Set of day-start dates in the visible month that carry at least one event.
    func daysWithEvents() -> Set<Date> {
        var days = Set<Date>()
        for event in monthEvents where !hidden.contains(event.calendarHref) {
            days.insert(calendar.startOfDay(for: event.start))
        }
        return days
    }

    private func run(_ label: String, _ block: @escaping () async throws -> Void) {
        loading = true
        error = nil
        Task {
            do {
                try await block()
                refresh()
            } catch {
                self.error = "\(label): \(error.localizedDescription)"
                self.loading = false
            }
        }
    }

    private static func startOfMonth(_ date: Date, _ cal: Calendar) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? cal.startOfDay(for: date)
    }
}

//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  SwiftUI month calendar + day agenda, mirroring the Android CalendarScreen:
//  month header with prev/next, weekday row, month grid with event dots, and a
//  list of the selected day's events. The "+" toolbar button and tapping an event
//  push the editor. Portuguese UI to match the Android module.
//

import SwiftUI

struct MeileCalendarView: View {
    @StateObject private var viewModel: MeileCalendarViewModel

    init(repository: MeileCalendarRepository) {
        _viewModel = StateObject(wrappedValue: MeileCalendarViewModel(repository: repository))
    }

    // Test/preview injection of a ready-made view model.
    init(viewModel: MeileCalendarViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                monthHeader
                if let error = viewModel.error {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .padding(.horizontal)
                }
                weekdayRow
                MeileMonthGrid(
                    monthStart: viewModel.monthStart,
                    selectedDay: viewModel.selectedDay,
                    eventDays: viewModel.daysWithEvents(),
                    onSelect: viewModel.selectDay
                )
                .padding(.horizontal, 4)
                Divider().padding(.top, 4)
                agendaHeader
                agendaList
            }
            .navigationTitle("Calendário")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        MeileEventEditorView(
                            editing: nil,
                            initial: newDraft(),
                            calendars: viewModel.calendars,
                            onSave: { draft, scope in viewModel.save(draft: draft, editing: nil, scope: scope) },
                            onDelete: { _ in }
                        )
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(viewModel.defaultCalendar == nil)
                }
            }
            .onAppear { if viewModel.monthEvents.isEmpty { viewModel.start() } }
        }
    }

    private var monthHeader: some View {
        HStack {
            Button { viewModel.goToMonth(offset: -1) } label: {
                Image(systemName: "chevron.left").font(.title2)
            }
            Spacer()
            Text(monthTitle(viewModel.monthStart))
                .font(.title2).bold()
            Spacer()
            Button { viewModel.goToMonth(offset: 1) } label: {
                Image(systemName: "chevron.right").font(.title2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(["D", "S", "T", "Q", "Q", "S", "S"].enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
    }

    private var agendaHeader: some View {
        HStack {
            Text(dayLabel(viewModel.selectedDay)).bold()
            Spacer()
            if viewModel.loading { ProgressView().scaleEffect(0.8) }
        }
        .padding(12)
    }

    @ViewBuilder
    private var agendaList: some View {
        let events = viewModel.eventsForDay(viewModel.selectedDay)
        if events.isEmpty && !viewModel.loading {
            Text("Sem eventos")
                .foregroundColor(.secondary)
                .padding(.horizontal)
            Spacer()
        } else {
            List(events) { event in
                NavigationLink {
                    MeileEventEditorView(
                        editing: event,
                        initial: draft(from: event),
                        calendars: viewModel.calendars,
                        onSave: { draft, scope in viewModel.save(draft: draft, editing: event, scope: scope) },
                        onDelete: { scope in viewModel.delete(event: event, scope: scope) }
                    )
                } label: {
                    MeileEventRow(event: event)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            .listStyle(.plain)
        }
    }

    // MARK: draft builders

    private func newDraft() -> MeileEventDraft {
        let start = defaultStart()
        return MeileEventDraft(
            uid: nil,
            calendarHref: viewModel.defaultCalendar?.href ?? "",
            resourceHref: nil,
            etag: nil,
            summary: "",
            location: nil,
            description: nil,
            start: start,
            end: start.addingTimeInterval(3_600),
            allDay: false,
            timeZoneId: viewModel.timeZoneId,
            rrule: nil,
            reminders: [],
            attendees: []
        )
    }

    private func draft(from event: MeileCalEvent) -> MeileEventDraft {
        MeileEventDraft(
            uid: event.uid,
            calendarHref: event.calendarHref,
            resourceHref: event.resourceHref,
            etag: event.etag,
            summary: event.summary,
            location: event.location,
            description: event.eventDescription,
            start: event.start,
            end: event.end,
            allDay: event.allDay,
            timeZoneId: viewModel.timeZoneId,
            rrule: nil,
            reminders: [],
            attendees: []
        )
    }

    /// Selected day at the current time-of-day (or 09:00 if that is in the past).
    private func defaultStart() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let now = Date()
        let time = cal.dateComponents([.hour, .minute], from: now)
        return cal.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: viewModel.selectedDay)
            ?? viewModel.selectedDay
    }
}

// MARK: - Month grid

private struct MeileMonthGrid: View {
    let monthStart: Date
    let selectedDay: Date
    let eventDays: Set<Date>
    let onSelect: (Date) -> Void

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c
    }

    var body: some View {
        let cal = calendar
        let firstWeekday = cal.component(.weekday, from: monthStart) - 1 // 0 = Sunday
        let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let totalCells = ((firstWeekday + daysInMonth + 6) / 7) * 7
        let rows = totalCells / 7

        VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let cell = row * 7 + col
                        let dayNumber = cell - firstWeekday + 1
                        cellView(dayNumber: dayNumber, daysInMonth: daysInMonth, cal: cal)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(dayNumber: Int, daysInMonth: Int, cal: Calendar) -> some View {
        if dayNumber >= 1 && dayNumber <= daysInMonth,
           let dayDate = cal.date(byAdding: .day, value: dayNumber - 1, to: monthStart) {
            let day = cal.startOfDay(for: dayDate)
            let selected = cal.isDate(day, inSameDayAs: selectedDay)
            MeileDayCell(
                day: dayNumber,
                selected: selected,
                hasEvents: eventDays.contains(day),
                onTap: { onSelect(day) }
            )
        } else {
            Color.clear
        }
    }
}

private struct MeileDayCell: View {
    let day: Int
    let selected: Bool
    let hasEvents: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Text("\(day)")
                .font(.system(size: 13))
                .foregroundColor(selected ? .white : .primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(selected ? Color.accentColor : Color.clear))
            Circle()
                .fill(hasEvents ? Color.accentColor : Color.clear)
                .frame(width: 4, height: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Event row

private struct MeileEventRow: View {
    let event: MeileCalEvent

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary.isEmpty ? "(sem título)" : event.summary)
                    .fontWeight(.medium)
                Text(timeLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let loc = event.location, !loc.isEmpty {
                    Text(loc).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    private var dotColor: Color {
        if let hex = event.color, let c = Color(hex: hex) { return c }
        return .accentColor
    }

    private var timeLabel: String {
        event.allDay ? "Dia inteiro" : "\(fmt(event.start, "HH:mm")) – \(fmt(event.end, "HH:mm"))"
    }
}

// MARK: - formatting helpers

private func monthTitle(_ date: Date) -> String {
    fmt(date, "MMMM yyyy").capitalizedFirst
}

private func dayLabel(_ date: Date) -> String {
    fmt(date, "EEEE, d 'de' MMMM").capitalizedFirst
}

private func fmt(_ date: Date, _ pattern: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "pt_BR")
    f.timeZone = .current
    f.dateFormat = pattern
    return f.string(from: date)
}

private extension String {
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}

private extension Color {
    /// "#RRGGBB" (optionally 8-digit with alpha) → Color; nil if unparseable.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b)
    }
}

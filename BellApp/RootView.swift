import SwiftUI
import UniformTypeIdentifiers

/// The app itself is deliberately thin. The widget is the product; this is
/// where you import, correct, and configure it.
struct RootView: View {
    @EnvironmentObject private var store: TimetableStore
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            Group {
                if store.timetable.events.isEmpty {
                    EmptyStateView { isImporting = true }
                } else {
                    DayRailView()
                }
            }
            .background(Palette.ink)
            .navigationTitle("Bell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { WeekView() } label: {
                        Image(systemName: "calendar")
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.timetableExport, .zip, .xml, .data]
            ) { result in
                if case .success(let url) = result { store.importTimetable(from: url) }
            }
            .alert("Import failed", isPresented: .constant(store.importError != nil)) {
                Button("OK") { store.importError = nil }
            } message: {
                Text(store.importError ?? "")
            }
        }
    }
}

// MARK: - Empty state
//
// An empty screen is an invitation to act, so it says exactly what to do and
// what will happen — not "no data".

struct EmptyStateView: View {
    var onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bring your schedule over")
                .font(.system(size: 26, weight: .semibold))

            Text("Export from your current timetable app and open the .timetable file here. "
                 + "Courses, rooms, and times come across; colors get reassigned so they stay "
                 + "readable when your home screen is tinted.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420, alignment: .leading)

            Button(action: onImport) {
                Label("Choose file", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Day view
//
// The organising idea: a single time rail down the left with the day's blocks
// pinned to it, and a hairline marking where you are right now. Gaps stay
// visible as gaps — empty space between classes is the thing you're usually
// trying to find, so it gets shown at true scale rather than collapsed into a
// list of equal-height rows.

struct DayRailView: View {
    @EnvironmentObject private var store: TimetableStore
    @State private var selectedDay = Date.now
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State private var now = Date.now

    private var occurrences: [ScheduleEngine.Occurrence] {
        store.engine.occurrences(on: selectedDay)
    }

    var body: some View {
        VStack(spacing: 0) {
            DayStrip(selection: $selectedDay)
                .padding(.bottom, 8)

            if let holiday = store.engine.exception(on: selectedDay) {
                QuietState(headline: holiday.name, detail: "No classes scheduled", symbol: "moon.zzz")
                    .padding(24)
                Spacer()
            } else if occurrences.isEmpty {
                QuietState(headline: "Nothing scheduled", detail: nil, symbol: "circle.dotted")
                    .padding(24)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(occurrences.enumerated()), id: \.element.id) { index, occurrence in
                            if index > 0 {
                                GapMarker(
                                    from: occurrences[index - 1],
                                    to: occurrence,
                                    isTight: store.engine.isTightTransition(
                                        from: occurrences[index - 1], to: occurrence))
                            }

                            ClassCard(
                                occurrence: occurrence,
                                color: store.palette[occurrence.event.course] ?? Palette.rail,
                                now: now)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
        }
        .onReceive(timer) { now = $0 }
    }
}

struct DayStrip: View {
    @Binding var selection: Date

    private var days: [Date] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -2, to: .now) ?? .now
        return (0 ..< 14).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    let isSelected = Calendar.current.isDate(day, inSameDayAs: selection)
                    Button { selection = day } label: {
                        VStack(spacing: 2) {
                            Text(day, format: .dateTime.weekday(.narrow))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(day, format: .dateTime.day())
                                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                                .monospacedDigit()
                        }
                        .frame(width: 42, height: 48)
                        .background {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(isSelected ? Palette.rail : .clear)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct ClassCard: View {
    var occurrence: ScheduleEngine.Occurrence
    var color: Color
    var now: Date

    private var isLive: Bool { occurrence.status(at: now) == .inProgress }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(occurrence.start, format: .dateTime.hour().minute())
                    .font(.system(size: 13, weight: .medium))
                Text(occurrence.end, format: .dateTime.hour().minute())
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .monospacedDigit()
            .frame(width: 54, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(occurrence.event.course)
                    .font(.system(size: 17, weight: .medium))
                if !occurrence.event.room.isEmpty {
                    Text(occurrence.event.room)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                if isLive {
                    ProgressRail(progress: occurrence.progress(at: now), color: color)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .opacity(occurrence.status(at: now) == .finished ? 0.4 : 1)
    }
}

/// The space between two classes, drawn at a height proportional to its length
/// so a ten-minute change looks different from a two-hour gap at a glance.
struct GapMarker: View {
    var from: ScheduleEngine.Occurrence
    var to: ScheduleEngine.Occurrence
    var isTight: Bool

    private var minutes: Int {
        Int(to.start.timeIntervalSince(from.end) / 60)
    }

    var body: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 54)
            Rectangle()
                .fill(isTight ? Color.orange.opacity(0.7) : Color.white.opacity(0.12))
                .frame(width: 4, height: max(18, min(64, CGFloat(minutes) * 0.7)))
            Text(gapLabel)
                .font(.system(size: 11))
                .foregroundStyle(isTight ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            Spacer()
        }
    }

    private var gapLabel: String {
        guard let walk = Campus.walkDescription(from: from.event.building, to: to.event.building)
        else { return "\(minutes) min" }
        return isTight ? "\(minutes) min — \(walk)" : "\(minutes) min · \(walk)"
    }
}

// MARK: - Week

struct WeekView: View {
    @EnvironmentObject private var store: TimetableStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(0 ..< (store.timetable.showsWeekends ? 7 : 5), id: \.self) { index in
                    let day = Calendar.current.date(
                        byAdding: .day, value: index, to: startOfWeek) ?? .now
                    let occurrences = store.engine.occurrences(on: day)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(day, format: .dateTime.weekday(.wide))
                            .font(.system(size: 15, weight: .semibold))

                        if occurrences.isEmpty {
                            Text("Clear").font(.system(size: 13)).foregroundStyle(.secondary)
                        } else {
                            ForEach(occurrences) { occurrence in
                                ClassRow(
                                    occurrence: occurrence,
                                    color: store.palette[occurrence.event.course] ?? Palette.rail,
                                    now: .now)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Palette.ink)
        .navigationTitle("Week")
    }

    private var startOfWeek: Date {
        let calendar = Calendar.current
        let index = store.engine.mondayBasedIndex(for: .now)
        return calendar.date(byAdding: .day, value: -index,
                             to: calendar.startOfDay(for: .now)) ?? .now
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var store: TimetableStore
    @State private var leaveBuffer = SharedStore.leaveBuffer
    @State private var showsRooms = SharedStore.showsRoomNumbers

    var body: some View {
        Form {
            Section {
                DatePicker("First day",
                           selection: Binding(
                            get: { store.timetable.termStart ?? .now },
                            set: { date in store.update { $0.termStart = date } }),
                           displayedComponents: .date)
                DatePicker("Last day",
                           selection: Binding(
                            get: { store.timetable.termEnd ?? .now },
                            set: { date in store.update { $0.termEnd = date } }),
                           displayedComponents: .date)
            } header: {
                Text("Term")
            } footer: {
                Text("Outside these dates the widget stops showing classes instead of "
                     + "repeating last week's schedule forever.")
            }

            Section {
                Stepper("Leave \(leaveBuffer) min early", value: $leaveBuffer, in: 0 ... 20)
                    .onChange(of: leaveBuffer) { SharedStore.leaveBuffer = $1 }
            } header: {
                Text("Getting to class")
            } footer: {
                Text("Added on top of the walking time between buildings.")
            }

            Section("Widget") {
                Toggle("Show room numbers", isOn: $showsRooms)
                    .onChange(of: showsRooms) { SharedStore.showsRoomNumbers = $1 }

                NavigationLink("Hidden courses") { HiddenCoursesView() }
                NavigationLink("Room coordinates") { CoordinatesView() }
            }

            Section {
                LabeledContent("Widget reads from") {
                    Text(SharedStore.hasSharedContainer ? "Shared container" : "App bundle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text(SharedStore.hasSharedContainer
                     ? "Importing a new file updates the widget straight away."
                     : "App Groups isn't active, so the widget reads the Events.xml compiled "
                       + "into the app. To change your schedule, replace that file and rebuild.")
            }

            Section("Breaks") {
                NavigationLink("Add a break") { BreakEditor() }
                ForEach(store.timetable.exceptions) { exception in
                    VStack(alignment: .leading) {
                        Text(exception.name)
                        Text(exception.start.formatted(.dateTime.month().day())
                             + " – "
                             + exception.end.formatted(.dateTime.month().day()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    store.update { $0.exceptions.remove(atOffsets: offsets) }
                }
            }
        }
        .navigationTitle("Settings")
    }
}

struct HiddenCoursesView: View {
    @EnvironmentObject private var store: TimetableStore
    @State private var hidden = SharedStore.hiddenCourses

    var body: some View {
        List(store.timetable.courses, id: \.self) { course in
            Toggle(course, isOn: Binding(
                get: { !hidden.contains(course) },
                set: { isVisible in
                    if isVisible { hidden.remove(course) } else { hidden.insert(course) }
                    SharedStore.hiddenCourses = hidden
                }))
        }
        .navigationTitle("Show on widgets")
    }
}

struct BreakEditor: View {
    @EnvironmentObject private var store: TimetableStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start = Date.now
    @State private var end = Date.now

    var body: some View {
        Form {
            TextField("Name", text: $name)
            DatePicker("From", selection: $start, displayedComponents: .date)
            DatePicker("To", selection: $end, displayedComponents: .date)

            Button("Save break") {
                store.update {
                    $0.exceptions.append(
                        ScheduleException(name: name.isEmpty ? "Break" : name,
                                          start: Calendar.current.startOfDay(for: start),
                                          end: end))
                }
                dismiss()
            }
            .disabled(end < start)
        }
        .navigationTitle("New break")
    }
}


/// Shows which rooms have a real coordinate and which are still guessed.
///
/// Editing happens in `Shared/RoomCoordinates.swift` rather than here, because
/// without App Groups anything typed into the app can't reach the widget. This
/// screen exists to tell you what's worth going and fixing.
struct CoordinatesView: View {
    @EnvironmentObject private var store: TimetableStore

    private var rooms: [String] {
        Array(Set(store.timetable.events.map(\.room))).filter { !$0.isEmpty }.sorted()
    }

    var body: some View {
        List {
            Section {
                ForEach(rooms, id: \.self) { room in
                    HStack {
                        Text(room)
                        Spacer()
                        if RoomCoordinates.coordinate(forRoom: room) != nil {
                            Label("Set", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                        } else {
                            Label("Estimated", systemImage: "questionmark.circle")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Text("Rooms")
            } footer: {
                Text("Green means the coordinate came from you. Orange means Bell is "
                     + "guessing, and the walking times for that room are rough.")
            }

            Section {
                Text("1. Find the building in Google Maps.")
                Text("2. Right-click the door you use.")
                Text("3. Click the coordinates at the top of the menu to copy them.")
                Text("4. Paste into Shared/RoomCoordinates.swift and rebuild.")
            } header: {
                Text("Adding a coordinate")
            } footer: {
                Text("Coordinates live in a source file because the widget runs in its own "
                     + "sandbox and can't read anything you type here without App Groups.")
            }
        }
        .navigationTitle("Room coordinates")
    }
}

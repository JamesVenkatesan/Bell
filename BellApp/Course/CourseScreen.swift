import MapKit
import SwiftUI

/// Everything about one course, reached by zooming out of any of its classes.
///
/// Ordered by how often each part is the reason you opened it: when it next
/// meets, whether you've been going, what's due, and where the room is.
struct CourseScreen: View {
    var code: String

    @Environment(BellStore.self) private var store
    @State private var isAddingWork = false

    var body: some View {
        // Rebuilt per body pass. Cheap (a few weeks of value types), and it
        // means a write anywhere in the store shows up here without plumbing.
        let summary = CourseSummary.build(course: code,
                                          engine: store.engine,
                                          attendance: store.attendance(forCourse: code),
                                          now: .now)
        let color = store.palette[code] ?? Bell.Surface.scaffold
        let stored = store.course(code: code)

        ScrollView {
            VStack(alignment: .leading, spacing: Bell.Space.section) {
                CourseHeader(code: code,
                             color: color,
                             instructor: stored?.instructor,
                             kind: stored?.kind ?? .lecture,
                             summary: summary)

                if let next = summary.upcoming.first {
                    NextMeeting(occurrence: next, color: color)
                }

                section("Attendance") {
                    AttendanceSection(summary: summary) { mark, state in
                        store.record(state, forCourse: code, at: mark.occurrence.start)
                        (state == .attended ? Haptic.confirm : Haptic.select).play()
                    }
                }

                section("Upcoming work", trailing: {
                    Button { isAddingWork = true } label: {
                        Label("Add", systemImage: "plus")
                            .font(Bell.Type_.caption.weight(.medium))
                    }
                    .buttonStyle(.glass)
                }) {
                    WorkSection(work: summary.work,
                                onToggle: { task in
                                    withAnimation(Bell.Motion.standard) {
                                        store.setTaskDone(!task.isDone, id: task.id)
                                    }
                                    Haptic.confirm.play()
                                },
                                onDelete: { task in
                                    withAnimation(Bell.Motion.dismiss) { store.deleteTask(id: task.id) }
                                })
                }

                let rooms = Array(Set(summary.weeklyPattern.map(\.room))).filter { !$0.isEmpty }.sorted()
                if !rooms.isEmpty {
                    section(rooms.count == 1 ? "Room" : "Rooms") {
                        RoomMap(rooms: rooms)
                    }
                }
            }
            .padding(.horizontal, Bell.Space.gutter)
            .padding(.bottom, Bell.Space.section)
        }
        .background(Bell.Surface.canvas)
        .navigationTitle(code)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingWork) {
            WorkEditor(course: code) { title, due, kind in
                withAnimation(Bell.Motion.arrive) {
                    _ = store.addTask(title: title, course: code, due: due, kind: kind)
                }
                Haptic.confirm.play()
            }
            .presentationDetents([.medium])
            .presentationBackground(Bell.Material_.overlay)
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }

    private func section<Trailing: View, Content: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Bell.Space.base) {
            HStack {
                Text(title)
                    .font(Bell.Type_.micro)
                    .foregroundStyle(Bell.Content.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                trailing()
            }
            content()
        }
    }
}

// MARK: - Header

/// The destination of the hero. Course colour fills it because this is the
/// one place the colour is the subject rather than a label.
private struct CourseHeader: View {
    var code: String
    var color: Color
    var instructor: String?
    var kind: CourseKind
    var summary: CourseSummary

    var body: some View {
        let ink = Bell.legibleOn(color)

        VStack(alignment: .leading, spacing: Bell.Space.base) {
            Label(kind.rawValue.capitalized, systemImage: kind.symbol)
                .font(Bell.Type_.micro)
                .opacity(0.75)

            Text(code)
                .font(Bell.Type_.display)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            if let instructor {
                Text(instructor)
                    .font(Bell.Type_.body)
                    .opacity(0.8)
            }

            HStack(spacing: Bell.Space.loose) {
                stat(value: "\(summary.weeklyPattern.count)",
                     label: summary.weeklyPattern.count == 1 ? "meeting a week" : "meetings a week")
                stat(value: hours(summary.weeklyMinutes), label: "in class weekly")
            }
            .padding(.top, Bell.Space.tight)
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Bell.Space.loose)
        .background {
            // Solid, like the hero it zooms out of: the course's colour is
            // the subject here, so it's a slab, not a gradient card.
            RoundedRectangle(cornerRadius: Bell.Radius.card, style: .continuous)
                .fill(color)
        }
        .padding(.top, Bell.Space.snug)
        .accessibilityElement(children: .combine)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(Bell.Type_.data(20, weight: .semibold))
            Text(label).font(Bell.Type_.caption).opacity(0.75)
        }
    }

    private func hours(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m)"
    }
}

private struct NextMeeting: View {
    var occurrence: ScheduleEngine.Occurrence
    var color: Color

    var body: some View {
        HStack(spacing: Bell.Space.base) {
            Image(systemName: "clock")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Bell.Content.secondary)
            VStack(alignment: .leading, spacing: Bell.Space.hair) {
                Text("Next \(occurrence.start, format: .dateTime.weekday(.wide)) at \(occurrence.start, format: .dateTime.hour().minute())")
                    .font(Bell.Type_.headline)
                    .foregroundStyle(Bell.Content.primary)
                Text(occurrence.event.room.isEmpty ? "No room listed" : occurrence.event.room)
                    .font(Bell.Type_.caption)
                    .foregroundStyle(Bell.Content.secondary)
            }
            Spacer()
            Text(occurrence.start, style: .relative)
                .font(Bell.Type_.data(13))
                .foregroundStyle(Bell.Content.secondary)
                .multilineTextAlignment(.trailing)
        }
        .monospacedDigit()
        .padding(Bell.Space.roomy)
        .background(RoundedRectangle(cornerRadius: Bell.Radius.large, style: .continuous)
            .fill(Bell.Surface.raised))
    }
}

// MARK: - Attendance

private struct AttendanceSection: View {
    var summary: CourseSummary
    var onMark: (CourseSummary.Mark, AttendanceState) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Bell.Space.roomy) {
            HStack(alignment: .firstTextBaseline, spacing: Bell.Space.loose) {
                VStack(alignment: .leading, spacing: 0) {
                    if let rate = summary.attendanceRate {
                        Text(rate, format: .percent.precision(.fractionLength(0)))
                            .font(Bell.Type_.data(34, weight: .semibold))
                            .contentTransition(.numericText(value: rate))
                    } else {
                        Text("No record yet")
                            .font(Bell.Type_.headline)
                    }
                    Text(summary.attendanceRate == nil ? "Mark a class below" : "of recorded classes")
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Content.secondary)
                }
                .foregroundStyle(Bell.Content.primary)

                if summary.streak > 1 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(summary.streak)")
                            .font(Bell.Type_.data(34, weight: .semibold))
                            .contentTransition(.numericText(value: Double(summary.streak)))
                        Text("in a row")
                            .font(Bell.Type_.caption)
                            .foregroundStyle(Bell.Content.secondary)
                    }
                    .foregroundStyle(Bell.Content.primary)
                    .transition(.bellCard)
                }
                Spacer()
            }
            .animation(Bell.Motion.arrive, value: summary.streak)

            if summary.history.isEmpty {
                Text("Nothing has happened yet this term.")
                    .font(Bell.Type_.caption)
                    .foregroundStyle(Bell.Content.tertiary)
            } else {
                HistoryStrip(history: summary.history)

                VStack(spacing: 0) {
                    ForEach(summary.history.prefix(4)) { mark in
                        MarkRow(mark: mark) { onMark(mark, $0) }
                        if mark.id != summary.history.prefix(4).last?.id {
                            Rectangle().fill(Bell.Surface.hairline).frame(height: Bell.Stroke.hair)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Bell.Radius.large, style: .continuous)
                    .fill(Bell.Surface.raised))
            }
        }
    }
}

/// The term so far as a row of marks, oldest on the left.
///
/// Encoded by brightness and fill, not hue: attended is solid and bright,
/// missed is a hollow ring, unrecorded is a faint dot. Readable at a glance
/// and still readable to anyone who can't separate red from green.
private struct HistoryStrip: View {
    var history: [CourseSummary.Mark]

    var body: some View {
        HStack(spacing: Bell.Space.tight) {
            ForEach(history.reversed()) { mark in
                dot(for: mark.state)
                    .frame(width: 10, height: 10)
                    .frame(maxWidth: .infinity)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Bell.Motion.snap, value: history.map(\.state))
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func dot(for state: AttendanceState?) -> some View {
        switch state {
        case .attended?:
            Circle().fill(Bell.Content.primary)
        case .missed?:
            Circle().strokeBorder(Bell.Signal.conflict, lineWidth: 1.5)
        case .excused?:
            Circle().strokeBorder(Bell.Content.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
        case .unknown?, nil:
            Circle().fill(Bell.Content.tertiary).padding(3)
        }
    }

    private var accessibilitySummary: String {
        let attended = history.filter { $0.state == .attended }.count
        let missed = history.filter { $0.state == .missed }.count
        return "\(attended) attended, \(missed) missed, of the last \(history.count) classes"
    }
}

private struct MarkRow: View {
    var mark: CourseSummary.Mark
    var onMark: (AttendanceState) -> Void

    var body: some View {
        HStack(spacing: Bell.Space.base) {
            VStack(alignment: .leading, spacing: 0) {
                Text(mark.occurrence.start, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(Bell.Type_.body)
                    .foregroundStyle(Bell.Content.primary)
                if mark.wasAutomatic {
                    Label("Marked by location", systemImage: "location.fill")
                        .font(Bell.Type_.micro)
                        .foregroundStyle(Bell.Signal.inferred)
                }
            }
            Spacer()
            choice(.attended, "Went", "checkmark")
            choice(.missed, "Missed", "xmark")
        }
        .padding(.horizontal, Bell.Space.roomy)
        .padding(.vertical, Bell.Space.base)
    }

    private func choice(_ state: AttendanceState, _ label: String, _ symbol: String) -> some View {
        let selected = mark.state == state
        return Button { onMark(state) } label: {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(selected ? Bell.Surface.canvas : Bell.Content.secondary)
                .background(Circle().fill(selected
                                          ? (state == .attended ? Bell.Content.primary : Bell.Signal.conflict)
                                          : Bell.Surface.sunken))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.bellPress)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Work

private struct WorkSection: View {
    var work: [TaskEvent]
    var onToggle: (TaskEvent) -> Void
    var onDelete: (TaskEvent) -> Void

    var body: some View {
        if work.isEmpty {
            Text("Nothing due. Add exams and deadlines here to see them on this page.")
                .font(Bell.Type_.caption)
                .foregroundStyle(Bell.Content.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: Bell.Space.snug) {
                ForEach(work) { task in
                    HStack(spacing: Bell.Space.base) {
                        Button { onToggle(task) } label: {
                            Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(task.isDone ? Bell.Signal.settled : Bell.Content.tertiary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(task.isDone ? "Mark not done" : "Mark done")

                        VStack(alignment: .leading, spacing: Bell.Space.hair) {
                            Text(task.title)
                                .font(Bell.Type_.headline)
                                .foregroundStyle(Bell.Content.primary)
                            Label {
                                Text(task.due, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                            } icon: {
                                Image(systemName: task.kind.symbol)
                            }
                            .font(Bell.Type_.caption)
                            .monospacedDigit()
                            .foregroundStyle(dueColor(task.due))
                            if task.isAutomatic { AutomaticBadge(reason: nil) }
                        }
                        Spacer()
                    }
                    .padding(Bell.Space.roomy)
                    .background(RoundedRectangle(cornerRadius: Bell.Radius.large, style: .continuous)
                        .fill(Bell.Surface.raised))
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { onDelete(task) }
                    }
                    .transition(.bellRow)
                }
            }
        }
    }

    /// Amber inside two days. Earlier than that it's just a date.
    private func dueColor(_ due: Date) -> Color {
        due.timeIntervalSinceNow < 2 * 86_400 ? Bell.Signal.urgent : Bell.Content.secondary
    }
}

private struct WorkEditor: View {
    var course: String
    var onSave: (String, Date, TaskKind) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var due = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var kind: TaskKind = .assignment
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("What's due", text: $title)
                    .focused($isTitleFocused)
                Picker("Kind", selection: $kind) {
                    ForEach(TaskKind.allCases.filter { $0 != .meeting }, id: \.self) { kind in
                        Label(kind.rawValue.capitalized, systemImage: kind.symbol).tag(kind)
                    }
                }
                DatePicker("Due", selection: $due)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("New for \(course)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", role: .confirm) {
                        onSave(title.trimmingCharacters(in: .whitespaces), due, kind)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { isTitleFocused = true }
        }
    }
}

// MARK: - Map

/// Where the room is, with a walking route one tap away.
///
/// Says plainly when the pin is a guess. A confident-looking pin in the wrong
/// place is worse than no map, because you'd walk to it.
private struct RoomMap: View {
    var rooms: [String]

    private struct Pin: Identifiable {
        var room: String
        var coordinate: CLLocationCoordinate2D
        var isMeasured: Bool
        var id: String { room }
    }

    private var pins: [Pin] {
        rooms.compactMap { room in
            let building = room.split(separator: " ").first.map(String.init)
            if let exact = RoomCoordinates.coordinate(forRoom: room) {
                return Pin(room: room, coordinate: exact, isMeasured: true)
            }
            guard let estimate = Campus.coordinate(for: building) else { return nil }
            return Pin(room: room, coordinate: estimate, isMeasured: false)
        }
    }

    var body: some View {
        let pins = pins
        if pins.isEmpty {
            Text("No position on file for \(rooms.joined(separator: ", ")). Add one in Room coordinates.")
                .font(Bell.Type_.caption)
                .foregroundStyle(Bell.Content.tertiary)
        } else {
            VStack(alignment: .leading, spacing: Bell.Space.snug) {
                Map(initialPosition: .automatic) {
                    ForEach(pins) { pin in
                        Marker(pin.room, systemImage: "building.columns", coordinate: pin.coordinate)
                    }
                    UserAnnotation()
                }
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
                .mapControls { }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: Bell.Radius.card, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let first = pins.first {
                        Button {
                            directions(to: first)
                        } label: {
                            Label("Walk there", systemImage: "figure.walk")
                                .font(Bell.Type_.caption.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                        .padding(Bell.Space.snug)
                    }
                }

                if pins.contains(where: { !$0.isMeasured }) {
                    Label("Position estimated from the building. Walking times to it are rough.",
                          systemImage: "questionmark.circle")
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Content.tertiary)
                }
            }
        }
    }

    private func directions(to pin: Pin) {
        let item = MKMapItem(location: CLLocation(latitude: pin.coordinate.latitude,
                                                  longitude: pin.coordinate.longitude),
                             address: nil)
        item.name = pin.room
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

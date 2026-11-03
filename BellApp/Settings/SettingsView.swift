import SwiftUI

// MARK: - Settings

struct SettingsView: View {
    var onReplayIntroduction: () -> Void = {}
    @Environment(BellStore.self) private var store
    @State private var leaveBuffer = Preferences.leaveBuffer
    @State private var showsRooms = Preferences.showsRoomNumbers

    var body: some View {
        Form {
            Section {
                DatePicker("First day",
                           selection: Binding(
                            get: { store.timetable.termStart ?? .now },
                            set: { date in
                                store.setTerm(start: date,
                                              end: store.timetable.termEnd ?? date)
                            }),
                           displayedComponents: .date)
                DatePicker("Last day",
                           selection: Binding(
                            get: { store.timetable.termEnd ?? .now },
                            set: { date in
                                store.setTerm(start: store.timetable.termStart ?? date,
                                              end: date)
                            }),
                           displayedComponents: .date)
            } header: {
                Text("Term")
            } footer: {
                Text("Outside these dates the widget stops showing classes instead of "
                     + "repeating last week's schedule forever.")
            }

            Section {
                Stepper("Leave \(leaveBuffer) min early", value: $leaveBuffer, in: 0 ... 20)
                    .onChange(of: leaveBuffer) { Preferences.leaveBuffer = $1 }
            } header: {
                Text("Getting to class")
            } footer: {
                Text("Added on top of the walking time between buildings.")
            }

            Section {
                NavigationLink {
                    WidgetGalleryView()
                } label: {
                    Label("Widgets", systemImage: "square.grid.2x2")
                }
                NavigationLink {
                    EmailSettingsView()
                } label: {
                    Label("Email", systemImage: "envelope")
                }
                NavigationLink {
                    NotionSettingsView()
                } label: {
                    Label("Notion", systemImage: "checklist")
                }
                NavigationLink {
                    LocationSettingsView()
                } label: {
                    Label("Location", systemImage: "location")
                }
                NavigationLink {
                    MorningsSettingsView()
                } label: {
                    Label("Mornings", systemImage: "alarm")
                }
                NavigationLink {
                    CalendarSettingsView()
                } label: {
                    Label("Calendar", systemImage: "calendar.badge.clock")
                }
            } footer: {
                Text("A wake-up alarm timed to your first class, and your classes in Calendar with clashes checked.")
            }

            Section("Widget") {
                Toggle("Show room numbers", isOn: $showsRooms)
                    .onChange(of: showsRooms) { Preferences.showsRoomNumbers = $1 }

                NavigationLink("Hidden courses") { HiddenCoursesView() }
                NavigationLink("Room coordinates") { CoordinatesView() }
            }

            Section {
                LabeledContent("Widget reads from") {
                    Text(AppGroup.isAvailable ? "Shared container" : "App bundle")
                        .foregroundStyle(.secondary)
                }
                if let error = store.lastError {
                    Text(error)
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Signal.conflict)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text(AppGroup.isAvailable
                     ? "Importing a new file updates the widget straight away."
                     : "App Groups isn't active, so the widget reads the Events.xml compiled "
                       + "into the app. To change your schedule, replace that file and rebuild.")
            }

            Section {
                Button("Show the introduction again", action: onReplayIntroduction)
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
                    for index in offsets {
                        store.removeException(named: store.timetable.exceptions[index].name)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Bell.Surface.canvas)
        .navigationTitle("Settings")
    }
}

struct HiddenCoursesView: View {
    @Environment(BellStore.self) private var store
    @Environment(AppSession.self) private var session
    @State private var hidden = Preferences.hiddenCourses

    var body: some View {
        List(store.timetable.courses, id: \.self) { course in
            Toggle(course, isOn: Binding(
                get: { !hidden.contains(course) },
                set: { isVisible in
                    if isVisible { hidden.remove(course) } else { hidden.insert(course) }
                    store.setHidden(!isVisible, forCourse: course)
                    // Hiding isn't part of the timetable value, so the
                    // usual change-driven sync wouldn't see it.
                    session.scheduleCalendarSync(using: store)
                }))
        }
        .navigationTitle("Show on widgets")
    }
}

struct BreakEditor: View {
    @Environment(BellStore.self) private var store
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
                store.addException(name: name.isEmpty ? "Break" : name,
                                   start: Calendar.current.startOfDay(for: start),
                                   end: end)
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
    @Environment(BellStore.self) private var store

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

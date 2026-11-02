import EventKit
import SwiftUI

/// Calendar sync, with what each switch actually does written beside it.
///
/// The footers carry real information on purpose. "Sync with Calendar" can
/// mean five different things; saying which one Bell means, including what
/// it won't do, is cheaper than a support conversation with yourself later.
struct CalendarSettingsView: View {
    @Environment(BellStore.self) private var store
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL

    @State private var writes = Preferences.calendarWritesEnabled
    @State private var reads = Preferences.calendarReadsEnabled
    @State private var excluded = Preferences.excludedCalendarIDs
    @State private var targetID = Preferences.calendarIdentifier
    @State private var isConfirmingRemoval = false

    private var sync: CalendarSync { session.calendar }

    var body: some View {
        Form {
            accessSection

            if sync.access == .granted {
                writeSection
                readSection
                cancellationSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(Bell.Surface.canvas)
        .navigationTitle("Calendar")
        .onAppear { sync.refreshAccess() }
        .confirmationDialog("Remove Bell's events?", isPresented: $isConfirmingRemoval,
                            titleVisibility: .visible) {
            Button("Remove events", role: .destructive) {
                sync.removeAll()
                Haptic.warn.play()
            }
        } message: {
            Text("Every class Bell added is removed from the calendar. Your own events in it are left alone.")
        }
    }

    // MARK: - Access

    @ViewBuilder
    private var accessSection: some View {
        switch sync.access {
        case .granted:
            EmptyView()
        case .notDetermined:
            Section {
                Button("Allow calendar access") {
                    Task {
                        await sync.requestAccess()
                        Haptic.select.play()
                    }
                }
            } footer: {
                Text("Bell needs full access: to add classes it must also read them back, or it would add duplicates each time.")
            }
        case .writeOnly, .denied:
            Section {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } header: {
                Text("Access")
            } footer: {
                Text(sync.access == .writeOnly
                     ? "Bell has add-only access. That can't see Bell's own events to update them, so it would duplicate classes on every change. Choose Full Access in Settings."
                     : "Calendar access is off. Turn it on in Settings to use this.")
            }
        }
    }

    // MARK: - Writing

    private var writeSection: some View {
        Section {
            Toggle("Add classes to a calendar", isOn: $writes)
                .onChange(of: writes) { _, on in
                    Preferences.calendarWritesEnabled = on
                    if on {
                        session.syncCalendar(using: store)
                        targetID = Preferences.calendarIdentifier
                    }
                }

            if writes {
                Picker("Write to", selection: Binding(
                    get: { targetID ?? "" },
                    set: { id in
                        guard let calendar = sync.writableCalendars.first(where: { $0.calendarIdentifier == id })
                        else { return }
                        // Clean up the old target before moving, or its
                        // events would be orphaned there forever.
                        sync.removeAll()
                        sync.chooseTarget(calendar)
                        targetID = id
                        session.syncCalendar(using: store)
                    })) {
                    if targetID == nil { Text("New “Bell” calendar").tag("") }
                    ForEach(sync.writableCalendars, id: \.calendarIdentifier) { calendar in
                        Text("\(calendar.title) · \(calendar.source.title)").tag(calendar.calendarIdentifier)
                    }
                }

                if let report = sync.lastReport {
                    LabeledContent("Last sync") {
                        Text(report.at, format: .relative(presentation: .named))
                            .foregroundStyle(Bell.Content.secondary)
                    }
                    if report.suspectedReset {
                        Label("Many classes were missing at once, so Bell put them back rather than treating them as cancelled.",
                              systemImage: "arrow.uturn.backward.circle")
                            .font(Bell.Type_.caption)
                            .foregroundStyle(Bell.Signal.urgent)
                    }
                }
                if let error = sync.lastError {
                    Text(error).font(Bell.Type_.caption).foregroundStyle(Bell.Signal.conflict)
                }

                Button("Sync now") {
                    session.syncCalendar(using: store)
                    Haptic.select.play()
                }
                Button("Remove Bell's events", role: .destructive) { isConfirmingRemoval = true }
            }
        } header: {
            Text("Your classes")
        } footer: {
            Text("The next four weeks of classes, kept up to date as your schedule changes. Edits made in "
                 + "Calendar are replaced; deleting one class marks it cancelled in Bell. "
                 + "A new calendar goes in iCloud, so it reaches your Mac too. To see classes in the "
                 + "Google or Outlook apps, write to one of that account's calendars instead: those apps "
                 + "only show what's on their own servers.")
        }
        .onAppear { targetID = Preferences.calendarIdentifier }
    }

    // MARK: - Reading

    private var readSection: some View {
        Section {
            Toggle("Check my other calendars", isOn: $reads)
                .onChange(of: reads) { _, on in
                    Preferences.calendarReadsEnabled = on
                    sync.loadExternal()
                }

            if reads {
                ForEach(sync.readableCalendars, id: \.calendarIdentifier) { calendar in
                    Toggle(isOn: Binding(
                        get: { !excluded.contains(calendar.calendarIdentifier) },
                        set: { include in
                            if include { excluded.remove(calendar.calendarIdentifier) }
                            else { excluded.insert(calendar.calendarIdentifier) }
                            Preferences.excludedCalendarIDs = excluded
                            sync.loadExternal()
                        })) {
                        Label {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(calendar.title)
                                Text(calendar.source.title)
                                    .font(Bell.Type_.caption)
                                    .foregroundStyle(Bell.Content.tertiary)
                            }
                        } icon: {
                            Circle().fill(Color(cgColor: calendar.cgColor)).frame(width: 10, height: 10)
                        }
                    }
                }
            }
        } header: {
            Text("Clashes")
        } footer: {
            Text("Events from these calendars appear in your day and are checked against your classes, "
                 + "including ones too close to walk between. Events marked Free are ignored. Read on this "
                 + "device only and never stored.")
        }
    }

    // MARK: - Cancellations

    @ViewBuilder
    private var cancellationSection: some View {
        let upcoming = store.cancellations().filter { $0.start > Calendar.current.date(byAdding: .day, value: -1, to: .now)! }
        if !upcoming.isEmpty {
            Section("Cancelled classes") {
                ForEach(upcoming, id: \.key) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.course)
                            Text(item.start, format: .dateTime.weekday(.wide).month().day().hour().minute())
                                .font(Bell.Type_.caption)
                                .foregroundStyle(Bell.Content.secondary)
                        }
                        Spacer()
                        Button("Restore") {
                            store.restore(cancellationKey: item.key)
                            Haptic.confirm.play()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

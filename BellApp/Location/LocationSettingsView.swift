import CoreLocation
import SwiftUI

/// Everything Bell does with where you are, and what each part needs.
struct LocationSettingsView: View {
    @Environment(BellStore.self) private var store
    @Environment(AppSession.self) private var session

    @State private var attendance = Preferences.autoAttendanceEnabled
    @State private var escalation = Preferences.escalationEnabled
    @State private var lookupAllowed = Preferences.buildingLookupAllowed
    @State private var isLookingUp = false
    @State private var lookupResult: [String: Bool] = [:]
    @State private var homeMessage: String?
    @State private var refresh = 0

    private var location: LocationServices { session.location }

    var body: some View {
        let unknown = LocationServices.unknownBuildings(in: store.timetable)
        Form {
            Section {
                Toggle("Mark attendance when I arrive", isOn: $attendance)
                    .onChange(of: attendance) { _, on in
                        Preferences.autoAttendanceEnabled = on
                        if on { CLLocationManager().requestAlwaysAuthorization() }
                        if !on { escalation = false }
                        Task {
                            await location.start(store: store)
                            await session.refreshBackgroundWork(using: store)
                        }
                    }
                if location.isMonitoring {
                    LabeledContent("Watching") {
                        Text(location.watched.joined(separator: ", "))
                            .foregroundStyle(Bell.Content.secondary)
                    }
                    if let last = location.lastEvent {
                        LabeledContent("Last", value: last)
                    }
                }
            } header: {
                Text("Attendance")
            } footer: {
                Text("Bell watches only the buildings of your next classes and marks a class attended when you "
                     + "arrive within 15 minutes of the start. It never marks a class missed: no signal isn't "
                     + "proof you weren't there. Needs location set to Always.")
            }

            Section {
                Toggle("Escalating walk alerts", isOn: $escalation)
                    .disabled(!attendance)
                    .onChange(of: escalation) { _, on in
                        Preferences.escalationEnabled = on
                        Task { await session.refreshBackgroundWork(using: store) }
                    }
            } header: {
                Text("Getting there")
            } footer: {
                Text(attendance
                     ? "A quiet heads-up ten minutes before you need to leave, then \"leave now\", then how late "
                       + "you'll be. Arriving cancels the rest, and leaving a building re-checks the walk from there."
                     : "Needs attendance above: without knowing when you arrive, Bell couldn't stop the alerts.")
            }

            Section {
                ForEach(unknown, id: \.self) { building in
                    LabeledContent(building) {
                        if let found = lookupResult[building] {
                            Text(found ? "Found" : "Not found").foregroundStyle(found ? Bell.Signal.settled : Bell.Signal.urgent)
                        } else {
                            Text("No position").foregroundStyle(Bell.Content.tertiary)
                        }
                    }
                }
                if !unknown.isEmpty {
                    Button(isLookingUp ? "Looking up…" : "Look up with Apple Maps") {
                        Preferences.buildingLookupAllowed = true
                        lookupAllowed = true
                        isLookingUp = true
                        Task {
                            lookupResult = await location.lookUpUnknownBuildings(in: store.timetable)
                            isLookingUp = false
                            await location.sync(store: store)
                            refresh += 1
                        }
                    }
                    .disabled(isLookingUp)
                }
                Toggle("Look up new buildings automatically", isOn: $lookupAllowed)
                    .onChange(of: lookupAllowed) { _, on in Preferences.buildingLookupAllowed = on }
            } header: {
                Text("Buildings")
            } footer: {
                Text("A lookup sends the building code and \"Purdue University\" to Apple Maps, and keeps a result "
                     + "only if it's on campus. Bell also learns a building's position on its own when you open "
                     + "the app during a class there. Neither needs Room coordinates edited by hand.")
            }
            .id(refresh)

            Section {
                Button("I'm at home: use this location") {
                    homeMessage = location.setHomeHere()
                        ? "Saved. Wake-up and the first walk of the day now start from here."
                        : "No accurate location yet. Try again outside, or in a moment."
                    Task { await session.refreshBackgroundWork(using: store) }
                }
                if let homeMessage {
                    Text(homeMessage).font(Bell.Type_.caption).foregroundStyle(Bell.Content.secondary)
                }
            } header: {
                Text("Home")
            }

            Section {
                Text("iOS only lets Bell start the class Live Activity while it's open, or from a Shortcut. "
                     + "Bell starts it up to three hours early whenever you open it. To have it start on its own, "
                     + "make a Personal Automation in Shortcuts (for example \"When I arrive at WALC\") that runs "
                     + "Bell's \"Track my class\".")
                    .font(Bell.Type_.caption)
                    .foregroundStyle(Bell.Content.secondary)
            } header: {
                Text("Live Activity")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Bell.Surface.canvas)
        .navigationTitle("Location")
    }
}

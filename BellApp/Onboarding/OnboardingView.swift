import CoreLocation
import SwiftUI
import UserNotifications

/// Three screens: what Bell is, getting a schedule in, and the two
/// permissions that make it useful.
///
/// Each screen earns its place by doing something. The first shows the idea
/// instead of describing it; the second imports; the third asks for access
/// with the reason next to the request, rather than in a cold system prompt
/// on first launch, which is the prompt people decline.
struct OnboardingView: View {
    var onFinish: () -> Void

    @Environment(BellStore.self) private var store
    @Environment(AppSession.self) private var session

    @State private var page = Page.idea
    @State private var isImporting = false

    enum Page: Int, CaseIterable, Hashable {
        case idea, schedule, permissions
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                IdeaPage().tag(Page.idea)
                SchedulePage(hasSchedule: !store.timetable.events.isEmpty,
                             onImport: { isImporting = true })
                    .tag(Page.schedule)
                PermissionsPage().tag(Page.permissions)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(Bell.Motion.standard, value: page)

            footer
        }
        // Each page is a full-bleed slab from the light end of the ramp, the
        // same language as the hero, so the introduction looks like the app.
        // Pinned to the light appearance: these three take ink text at 8.8:1
        // or better, and adaptive ink would turn pale on them in dark mode.
        .background(pageColor.ignoresSafeArea().animation(Bell.Motion.standard, value: page))
        .environment(\.colorScheme, .light)
        .haptic(.tick, on: page)
        .sheet(isPresented: $isImporting) {
            ImportView()
                .environment(store)
        }
        .onChange(of: store.timetable.events.isEmpty) { _, isEmpty in
            // A schedule arriving is the moment this flow exists for, so it
            // moves on by itself rather than making you find the button.
            if !isEmpty, page == .schedule {
                withAnimation(Bell.Motion.arrive) { page = .permissions }
            }
        }
    }

    private var pageColor: Color {
        switch page {
        case .idea: Palette.steps[0]        // Lemon
        case .schedule: Palette.steps[2]    // Aqua
        case .permissions: Palette.steps[3] // Tangerine
        }
    }

    private var footer: some View {
        VStack(spacing: Bell.Space.roomy) {
            PageDots(count: Page.allCases.count, current: page.rawValue)

            Button {
                if let next = Page(rawValue: page.rawValue + 1) {
                    withAnimation(Bell.Motion.standard) { page = next }
                } else {
                    Haptic.confirm.play()
                    onFinish()
                }
            } label: {
                Text(primaryLabel)
                    .font(Bell.Type_.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Bell.Space.snug)
                    .contentTransition(.opacity)
            }
            .buttonStyle(.glassProminent)
            // Filled with the near-white app tint, so the label takes the canvas
            // colour; left alone it was white on white.
            .foregroundStyle(Bell.Surface.canvas)
            .animation(Bell.Motion.snap, value: primaryLabel)
        }
        .padding(.horizontal, Bell.Space.loose)
        .padding(.bottom, Bell.Space.loose)
    }

    private var primaryLabel: String {
        switch page {
        case .idea: "Continue"
        case .schedule: store.timetable.events.isEmpty ? "Skip for now" : "Continue"
        case .permissions: "Start using Bell"
        }
    }
}

// MARK: - Pages

/// Shows a day drawn to scale, assembling itself. Built from the same
/// emphasis and colour rules as the real timeline, so the promise and the
/// product look alike.
private struct IdeaPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var level = 1.0

    var body: some View {
        OnboardingPage(
            symbol: "bell",
            title: "The next bell, always",
            message: "One number: the minutes until your class starts, ends, or it's time to leave. "
                + "The colour sinks as the time runs out, so you can read it from across a room.") {
            BellDemo(level: level)
                .frame(maxWidth: 320)
                .onAppear {
                    guard !reduceMotion else { level = 0.45; return }
                    withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: false)) { level = 0.1 }
                }
        }
    }
}

/// The hero, demonstrated rather than described: a slab draining on a loop.
private struct BellDemo: View {
    var level: Double
    private let color = Palette.steps[8] // Cobalt, white text

    var body: some View {
        // Animatable in `level`, so the number counts as the colour sinks.
        Text("").modifier(DemoLevel(level: level, color: color))
    }
}

private struct DemoLevel: ViewModifier, Animatable {
    var level: Double
    var color: Color
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func body(content: Content) -> some View {
        let minutes = max(1, Int((level * 18).rounded(.up)))
        let face = VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: Bell.Space.snug) {
                Text("\(minutes)").font(Bell.Type_.bell(96))
                Text("min").font(Bell.Type_.title)
            }
            Text("until ECE 30200").font(Bell.Type_.title)
                .padding(.bottom, Bell.Space.roomy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Bell.Space.roomy)

        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Bell.ink.opacity(0.08)
                color.frame(height: geometry.size.height * level)
                face.foregroundStyle(Bell.ink)
                face.foregroundStyle(Bell.paper)
                    .mask(alignment: .bottom) { Rectangle().frame(height: geometry.size.height * level) }
            }
        }
        .frame(height: 230)
        .clipShape(.rect(cornerRadius: Bell.Radius.card, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Example: 18 minutes until ECE 30200, counting down")
    }
}

private struct SchedulePage: View {
    var hasSchedule: Bool
    var onImport: () -> Void

    var body: some View {
        OnboardingPage(
            symbol: hasSchedule ? "checkmark.circle" : "square.and.arrow.down",
            title: hasSchedule ? "Schedule in" : "Bring your schedule",
            message: hasSchedule
                ? "Bell has your classes. You can update them any time from the Today screen."
                : "The best source is your registrar's calendar link, which keeps itself current. "
                    + "A PDF or a screenshot works too. It's read on this device and you check "
                    + "the result before anything is saved.") {
            if !hasSchedule {
                Button(action: onImport) {
                    Label("Import schedule", systemImage: "arrow.down.doc")
                        .font(Bell.Type_.headline)
                        .padding(.horizontal, Bell.Space.base)
                        .padding(.vertical, Bell.Space.tight)
                }
                .buttonStyle(.glass)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Bell.Signal.settled)
                    .symbolEffect(.bounce, options: .nonRepeating)
                    .transition(.bellCard)
            }
        }
        .animation(Bell.Motion.arrive, value: hasSchedule)
    }
}

private struct PermissionsPage: View {
    @Environment(AppSession.self) private var session
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var location: CLAuthorizationStatus = .notDetermined

    var body: some View {
        OnboardingPage(
            symbol: "figure.walk.motion",
            title: "Leave on time",
            message: "Three things make Bell more than a timetable. All of it stays on this device.") {
            VStack(spacing: Bell.Space.base) {
                PermissionRow(
                    symbol: "location",
                    title: "Location while using Bell",
                    detail: "Turns building-to-building estimates into real walking times from where you are.",
                    isGranted: location == .authorizedWhenInUse || location == .authorizedAlways,
                    isDecided: location != .notDetermined) {
                        session.requestLocationAccess()
                        Task { await refreshAfterPrompt() }
                    }
                PermissionRow(
                    symbol: "calendar",
                    title: "Calendar",
                    detail: "Adds your classes to Calendar and checks your other events for clashes, including ones you can't walk between in time.",
                    isGranted: session.calendar.access == .granted,
                    isDecided: session.calendar.access != .notDetermined) {
                        Task {
                            await session.calendar.requestAccess()
                            // Asking was the opt-in. Leaving both switches
                            // off after a yes would look broken.
                            if session.calendar.access == .granted {
                                Preferences.calendarWritesEnabled = true
                                Preferences.calendarReadsEnabled = true
                            }
                        }
                    }
                PermissionRow(
                    symbol: "bell.badge",
                    title: "Notifications",
                    detail: "Only when it changes what you'd do: the first class of the day, and changes too tight to walk.",
                    isGranted: notifications == .authorized,
                    isDecided: notifications != .notDetermined) {
                        Task {
                            await Notifier.requestAuthorization()
                            await refresh()
                        }
                    }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        location = CLLocationManager().authorizationStatus
    }

    /// The location prompt answers asynchronously and outside our control,
    /// so poll briefly rather than wiring a delegate for one screen.
    private func refreshAfterPrompt() async {
        for _ in 0 ..< 20 {
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
            if location != .notDetermined { break }
        }
    }
}

// MARK: - Pieces

private struct OnboardingPage<Illustration: View>: View {
    var symbol: String
    var title: String
    var message: String
    @ViewBuilder var illustration: Illustration

    var body: some View {
        VStack(alignment: .leading, spacing: Bell.Space.base) {
            Spacer(minLength: Bell.Space.section)
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Bell.Content.secondary)
                .symbolEffect(.drawOn, options: .nonRepeating)
            Text(title)
                .font(Bell.Type_.display)
                .foregroundStyle(Bell.Content.primary)
            Text(message)
                .font(Bell.Type_.body)
                .foregroundStyle(Bell.Content.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Bell.Space.loose)
            illustration
                .frame(maxWidth: .infinity)
            Spacer(minLength: Bell.Space.loose)
        }
        .padding(.horizontal, Bell.Space.loose)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
}

private struct PermissionRow: View {
    var symbol: String
    var title: String
    var detail: String
    var isGranted: Bool
    var isDecided: Bool
    var onRequest: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Bell.Space.base) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Bell.Content.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: Bell.Space.tight) {
                Text(title).font(Bell.Type_.headline).foregroundStyle(Bell.Content.primary)
                Text(detail)
                    .font(Bell.Type_.caption)
                    .foregroundStyle(Bell.Content.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Bell.Signal.settled)
                    .transition(.bellCard)
            } else if isDecided {
                // Declined. iOS won't show the prompt twice, so the honest
                // thing is to say where it can be changed.
                Text("Off in Settings")
                    .font(Bell.Type_.micro)
                    .foregroundStyle(Bell.Content.tertiary)
            } else {
                Button("Allow", action: onRequest)
                    .font(Bell.Type_.caption.weight(.semibold))
                    .buttonStyle(.glass)
            }
        }
        .padding(Bell.Space.roomy)
        .background(RoundedRectangle(cornerRadius: Bell.Radius.large, style: .continuous)
            .fill(Bell.Surface.raised))
        .animation(Bell.Motion.arrive, value: isGranted)
        .haptic(.confirm, on: isGranted)
    }
}

/// Page position as one capsule that stretches to the current page.
private struct PageDots: View {
    var count: Int
    var current: Int

    var body: some View {
        HStack(spacing: Bell.Space.snug) {
            ForEach(0 ..< count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Bell.Content.primary : Bell.Content.tertiary)
                    .frame(width: index == current ? 20 : 6, height: 6)
            }
        }
        .animation(Bell.Motion.snap, value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

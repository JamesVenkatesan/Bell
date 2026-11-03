import SwiftUI

/// Places the app can push to. A value rather than a destination view, so the
/// hero source and the pushed screen agree on identity through `HeroID`
/// instead of through two closures that could drift.
enum Route: Hashable {
    /// `sourceID` is the occurrence (or grid block) the user tapped. The
    /// course page zooms out of exactly that shape.
    case course(code: String, sourceID: String)
    case week
    case inbox
    case review
    case location
    case gallery
    case notion
    case settings
}

struct RootView: View {
    @Environment(BellStore.self) private var store
    @Environment(AppSession.self) private var session

    @State private var path: [Route] = []
    @State private var isImporting = false
    @State private var isOnboarding = false

    /// One namespace for every hero in the app. The zoom transition matches
    /// a source and a destination by (id, namespace), so they must share it.
    @Namespace private var hero

    var body: some View {
        NavigationStack(path: $path) {
            TodayScreen(hero: hero,
                        open: { path.append($0) },
                        onImport: { isImporting = true })
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .sheet(isPresented: $isImporting) {
            ImportView()
                .environment(store)
        }
        .fullScreenCover(isPresented: $isOnboarding) {
            OnboardingView {
                Preferences.hasCompletedOnboarding = true
                isOnboarding = false
            }
            .environment(store)
            .environment(session)
        }
        .onAppear {
            #if DEBUG
            // `-BellRoute week` or `-BellRoute "course:ECE 30200"` opens a
            // screen directly, for screenshots without driving the UI.
            if let route = UserDefaults.standard.string(forKey: "BellRoute") {
                if route == "week" { path = [.week] }
                if route == "inbox" { path = [.inbox] }
                if route == "review" { path = [.review] }
                if route == "settings" { path = [.settings] }
                if route == "location" { path = [.location] }
                if route == "gallery" { path = [.gallery] }
                if route == "notion" { path = [.notion] }
                if route.hasPrefix("course:") {
                    path = [.course(code: String(route.dropFirst(7)), sourceID: "debug")]
                }
            }
            #endif
            isOnboarding = OnboardingGate.shouldPresent(
                hasCompleted: Preferences.hasCompletedOnboarding,
                hasSchedule: !store.timetable.events.isEmpty)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "BellOnboarding") { isOnboarding = true }
            #endif
        }
        .onChange(of: session.requestedCourse) { _, code in
            guard let code else { return }
            path = [.course(code: code, sourceID: "link-\(code)")]
            session.requestedCourse = nil
        }
        .alert("Import failed", isPresented: .constant(session.importError != nil)) {
            Button("OK") { session.importError = nil }
        } message: {
            Text(session.importError ?? "")
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .course(let code, let sourceID):
            CourseScreen(code: code)
                .navigationTransition(.zoom(sourceID: HeroID.card(sourceID), in: hero))
        case .week:
            WeekScreen(hero: hero, open: { path.append($0) })
        case .inbox:
            InboxScreen()
        case .review:
            WeeklyReviewScreen()
        case .location:
            LocationSettingsView()
        case .gallery:
            WidgetGalleryView()
        case .notion:
            NotionSettingsView()
        case .settings:
            SettingsView(onReplayIntroduction: { isOnboarding = true })
        }
    }
}

/// Whether to show the introduction.
///
/// Someone who already has a schedule has, by definition, found their way
/// around: showing them a welcome over their own timetable is an obstacle,
/// not an introduction. That covers everyone who used Bell before onboarding
/// existed, without needing a migration flag.
enum OnboardingGate {
    static func shouldPresent(hasCompleted: Bool, hasSchedule: Bool) -> Bool {
        !hasCompleted && !hasSchedule
    }
}

import SwiftUI
import WidgetKit

/// All eight widgets, at their real sizes, from today's real data, so they can
/// be reviewed without adding each one to the home screen.
///
/// Tinted mode is an approximation and says so. The app can render a
/// widget's tinted *layout* (it sets the rendering mode the views respond
/// to), but not the system's own tint compositing over the wallpaper. The
/// home screen is the final check.
struct WidgetGalleryView: View {
    @Environment(BellStore.self) private var store
    @State private var tinted = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let model = WidgetModel.build(
                timetable: store.timetable, palette: store.palette, busy: SnapshotCache.busy(),
                hidden: Preferences.hiddenCourses, leaveBuffer: Preferences.leaveBuffer,
                completedTasks: WidgetActions.completedTasks, markedAttendance: WidgetActions.markedAttendance,
                now: context.date)

            ScrollView {
                VStack(alignment: .leading, spacing: Bell.Space.section) {
                    Picker("Appearance", selection: $tinted) {
                        Text("Full colour").tag(false)
                        Text("Tinted").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if tinted {
                        Text("An approximation: Bell can show each widget's tinted layout, but only your home screen applies the real tint.")
                            .font(Bell.Type_.caption)
                            .foregroundStyle(Bell.Content.secondary)
                    }

                    ForEach(WidgetKind.allCases) { kind in
                        VStack(alignment: .leading, spacing: Bell.Space.snug) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(kind.name).font(Bell.Type_.headline)
                                Text(kind.question).font(Bell.Type_.caption).foregroundStyle(Bell.Content.secondary)
                            }
                            WidgetPreview(kind: kind, model: model, tinted: tinted)
                        }
                    }
                }
                .padding(Bell.Space.gutter)
            }
        }
        .background(Bell.Surface.canvas)
        .navigationTitle("Widgets")
        // Inline: a large title collided with the picker at the top.
        .navigationBarTitleDisplayMode(.inline)
        .animation(Bell.Motion.standard, value: tinted)
    }
}

/// One widget at its family's real size, with the system's margins and corner.
struct WidgetPreview: View {
    var kind: WidgetKind
    var model: WidgetModel
    var tinted: Bool

    private var size: CGSize {
        switch kind.family {
        case .systemSmall: CGSize(width: 170, height: 170)
        case .systemMedium: CGSize(width: 364, height: 170)
        case .systemLarge: CGSize(width: 364, height: 382)
        case .accessoryRectangular: CGSize(width: 172, height: 76)
        default: CGSize(width: 76, height: 76)
        }
    }

    private var isLockScreen: Bool { kind.family == .accessoryRectangular || kind.family == .accessoryCircular }

    var body: some View {
        let content = WidgetBody(kind: kind, model: model)
            .environment(\.widgetRenderingMode, tinted || isLockScreen ? .accented : .fullColor)
            .padding(isLockScreen ? 0 : 16)
            .frame(width: size.width, height: size.height)

        Group {
            if isLockScreen {
                // Lock screen widgets sit on the wallpaper in white.
                content
                    .foregroundStyle(.white)
                    .environment(\.colorScheme, .dark)
                    .padding(Bell.Space.base)
                    .background(RoundedRectangle(cornerRadius: Bell.Radius.card, style: .continuous)
                        .fill(Color(hex: 0x1C2333)))
            } else if tinted {
                content
                    .environment(\.colorScheme, .dark)
                    .grayscale(1)
                    .background(Color(hex: 0x2A2F3A))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                content
                    .background(WidgetBody.background(kind, model))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.name) widget preview")
    }
}

import PhotosUI
import SwiftUI

/// Everything Bell has been handed that isn't a class: exams, deadlines,
/// interviews, pulled out of messages, emails and screenshots.
///
/// Three groups, in the order they need attention. What Bell added on its
/// own comes first and is labelled as such, so an automatic add is seen and
/// can be undone. Then what's waiting for a decision. Then what's coming up.
struct InboxScreen: View {
    @Environment(BellStore.self) private var store
    @Environment(AppSession.self) private var session

    @State private var photoItem: PhotosPickerItem?
    @State private var editing: InboxEntry?
    @State private var isTyping = false
    @State private var screenshotProblem: String?

    private var processor: InboxProcessor { session.inbox }

    private var automatic: [InboxEntry] {
        store.inbox.filter { $0.state == .accepted && $0.wasAutoAccepted && isAhead($0) }
    }
    private var pending: [InboxEntry] { store.inbox.filter { $0.state == .pending } }
    private var upcoming: [TaskEvent] {
        store.timetable.tasks
            .filter { !$0.isDone && $0.due >= Calendar.current.startOfDay(for: .now) }
            .sorted { $0.due < $1.due }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Bell.Space.section) {
                captureBar

                if let screenshotProblem {
                    Label(screenshotProblem, systemImage: "photo.badge.exclamationmark")
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Signal.urgent)
                        .transition(.bellCard)
                }

                if !automatic.isEmpty {
                    group("Added by Bell", detail: "These looked important, so Bell added them without asking.") {
                        ForEach(automatic) { entry in
                            InboxCard(entry: entry, mode: .automatic) { action in handle(action, entry) }
                                .transition(.bellCard)
                        }
                    }
                }

                if !pending.isEmpty {
                    group("To review", detail: nil) {
                        ForEach(pending) { entry in
                            InboxCard(entry: entry, mode: .review) { action in handle(action, entry) }
                                .transition(.bellCard)
                        }
                    }
                }

                if !upcoming.isEmpty {
                    group("Coming up", detail: nil) {
                        VStack(spacing: Bell.Space.snug) {
                            let pressure = Dictionary(DeadlinePressure.evaluate(
                                tasks: upcoming, engine: store.engine, busy: session.calendar.external, now: .now)
                                .map { ($0.task.id, $0) }, uniquingKeysWith: { a, _ in a })
                            ForEach(upcoming) { task in
                                TaskRow(task: task, pressure: pressure[task.id]) {
                                    withAnimation(Bell.Motion.standard) { store.setTaskDone(true, id: task.id) }
                                    Haptic.confirm.play()
                                }
                                .transition(.bellRow)
                            }
                        }
                    }
                }

                if pending.isEmpty && automatic.isEmpty && upcoming.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, Bell.Space.gutter)
            .padding(.bottom, Bell.Space.section)
            .animation(Bell.Motion.standard, value: store.inbox)
        }
        .background(Bell.Surface.canvas)
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.large)
        .overlay {
            if processor.isWorking {
                ProgressView("Reading")
                    .padding(Bell.Space.loose)
                    .glassEffect(Bell.Material_.floating, in: .rect(cornerRadius: Bell.Radius.large))
                    .transition(.opacity)
            }
        }
        .animation(Bell.Motion.snap, value: processor.isWorking)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await processor.process(imageData: data, source: .photo, store: store)
                }
                photoItem = nil
            }
        }
        .sheet(item: $editing) { entry in
            InboxEditor(reading: entry.reading, courses: store.timetable.courses) { edited in
                withAnimation(Bell.Motion.arrive) { store.accept(inboxID: entry.id, edited: edited) }
                Haptic.confirm.play()
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $isTyping) {
            TypeIn { text in
                Task { await processor.process(text: text, source: .manual, store: store) }
            }
            .presentationDetents([.medium])
        }
        .onDisappear { processor.clearJustAutoAdded() }
    }

    // MARK: - Capture

    /// Four ways in, as glass controls over the list. Paste uses the system
    /// paste button, which reads the clipboard without the "allow paste"
    /// prompt, because the tap itself is the permission.
    private var captureBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: Bell.Space.snug) {
                HStack(spacing: Bell.Space.snug) {
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { await processor.process(text: text, source: .shareSheet, store: store) }
                    }
                    .buttonBorderShape(.capsule)
                    .labelStyle(.titleAndIcon)

                    Button {
                        Task { await latestScreenshot() }
                    } label: {
                        Label("Latest screenshot", systemImage: "camera.viewfinder")
                    }
                    .buttonStyle(.glass)

                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Photo", systemImage: "photo")
                    }
                    .buttonStyle(.glass)

                    Button { isTyping = true } label: {
                        Label("Type", systemImage: "character.cursor.ibeam")
                    }
                    .buttonStyle(.glass)
                }
                .font(Bell.Type_.caption.weight(.medium))
            }
            .padding(.vertical, Bell.Space.tight)
        }
        .scrollClipDisabled()
    }

    private func latestScreenshot() async {
        switch await LatestScreenshot.load() {
        case .success(let data):
            screenshotProblem = nil
            await processor.process(imageData: data, source: .screenshot, store: store)
        case .failure(.denied):
            screenshotProblem = "Bell needs access to Photos to read your latest screenshot. You can allow it in Settings."
            Haptic.reject.play()
        case .failure(.none):
            screenshotProblem = "No screenshots found."
            Haptic.reject.play()
        }
    }

    // MARK: - Actions

    private func handle(_ action: InboxCard.Action, _ entry: InboxEntry) {
        switch action {
        case .add:
            withAnimation(Bell.Motion.arrive) { store.accept(inboxID: entry.id) }
            Haptic.confirm.play()
        case .edit:
            editing = entry
        case .dismiss:
            withAnimation(Bell.Motion.dismiss) { store.dismiss(inboxID: entry.id) }
        case .undo:
            withAnimation(Bell.Motion.standard) { store.undoAutomaticAdd(inboxID: entry.id) }
            Haptic.select.play()
        }
    }

    private func isAhead(_ entry: InboxEntry) -> Bool {
        guard let start = entry.start else { return false }
        return start >= Calendar.current.startOfDay(for: .now)
    }

    // MARK: - Pieces

    private func group<Content: View>(_ title: String, detail: String?,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Bell.Space.base) {
            VStack(alignment: .leading, spacing: Bell.Space.hair) {
                Text(title)
                    .font(Bell.Type_.micro)
                    .foregroundStyle(Bell.Content.secondary)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail).font(Bell.Type_.caption).foregroundStyle(Bell.Content.tertiary)
                }
            }
            content()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Bell.Space.base) {
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Bell.Content.tertiary)
            Text("Nothing waiting")
                .font(Bell.Type_.headline)
                .foregroundStyle(Bell.Content.primary)
            Text("Share a message, an email or a web page to Bell from the share sheet, or screenshot "
                 + "a text and tap Latest screenshot. Bell reads it on this device and pulls out "
                 + "the date, time and place.")
                .font(Bell.Type_.caption)
                .foregroundStyle(Bell.Content.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Bell can't read Messages directly: iOS doesn't let any app do that.")
                .font(Bell.Type_.caption)
                .foregroundStyle(Bell.Content.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Bell.Space.loose)
    }
}

// MARK: - Card

private struct InboxCard: View {
    enum Mode { case review, automatic }
    enum Action { case add, edit, dismiss, undo }

    var entry: InboxEntry
    var mode: Mode
    var onAction: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Bell.Space.base) {
            HStack(spacing: Bell.Space.snug) {
                if mode == .automatic {
                    AutomaticBadge(reason: entry.keyword)
                } else if let keyword = entry.keyword {
                    Label("Looks like \(article(keyword)) \(keyword)", systemImage: "exclamationmark.circle")
                        .font(Bell.Type_.micro)
                        .foregroundStyle(Bell.Signal.urgent)
                }
                Spacer()
                Text(entry.source.label)
                    .font(Bell.Type_.micro)
                    .foregroundStyle(Bell.Content.tertiary)
            }

            VStack(alignment: .leading, spacing: Bell.Space.tight) {
                Text(entry.title)
                    .font(Bell.Type_.headline)
                    .foregroundStyle(Bell.Content.primary)
                if let when = whenText {
                    Label(when, systemImage: entry.kind == .other ? "calendar" : symbol)
                        .font(Bell.Type_.caption)
                        .monospacedDigit()
                        .foregroundStyle(Bell.Content.secondary)
                } else {
                    Label("No date found", systemImage: "calendar.badge.exclamationmark")
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Signal.urgent)
                }
                let place = [entry.course, entry.location].compactMap { $0 }.joined(separator: " · ")
                if !place.isEmpty {
                    Text(place).font(Bell.Type_.caption).foregroundStyle(Bell.Content.tertiary)
                }
                if let caution = entry.caution {
                    Text(caution)
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Signal.urgent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: Bell.Space.snug) {
                switch mode {
                case .review:
                    Button { onAction(.add) } label: { Text("Add") }
                        .buttonStyle(.glassProminent)
                        // Filled with the near-white app tint, so the label takes the canvas
                        // colour; left alone it was white on white.
                        .foregroundStyle(Bell.Surface.canvas)
                        .disabled(entry.start == nil)
                    Button { onAction(.edit) } label: { Text("Edit") }
                        .buttonStyle(.glass)
                    Spacer()
                    Button("Dismiss", role: .destructive) { onAction(.dismiss) }
                        .font(Bell.Type_.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Bell.Content.tertiary)
                case .automatic:
                    Spacer()
                    Button { onAction(.undo) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.glass)
                }
            }
            .font(Bell.Type_.caption.weight(.semibold))
        }
        .padding(Bell.Space.roomy)
        .background(RoundedRectangle(cornerRadius: Bell.Radius.card, style: .continuous)
            .fill(Bell.Surface.raised))
        .overlay {
            // The automatic ones carry the inferred colour on their edge as
            // well as in the badge: the distinction has to survive a glance.
            RoundedRectangle(cornerRadius: Bell.Radius.card, style: .continuous)
                .strokeBorder(mode == .automatic ? Bell.Signal.inferred.opacity(0.6) : Bell.Surface.hairline,
                              lineWidth: mode == .automatic ? 1 : Bell.Stroke.hair)
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        TaskEvent(title: "", due: .now, kind: entry.kind).kind.symbol
    }

    private var whenText: String? {
        guard let start = entry.start else { return nil }
        if !entry.hasTime {
            return start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        var text = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        if let end = entry.end { text += "–" + end.formatted(.dateTime.hour().minute()) }
        return text
    }

    private func article(_ word: String) -> String {
        "aeiou".contains(word.first ?? "x") ? "an" : "a"
    }
}

/// The mark on anything Bell added without being asked.
///
/// Uses `Signal.inferred`, the colour the design system reserves for model
/// output and never puts on the user's own content, plus a symbol and words,
/// so it reads the same in tinted mode and to VoiceOver.
struct AutomaticBadge: View {
    var reason: String?

    var body: some View {
        Label(reason.map { "Added by Bell · \($0)" } ?? "Added by Bell", systemImage: "sparkles")
            .font(Bell.Type_.micro)
            .foregroundStyle(Bell.Signal.inferred)
            .accessibilityLabel("Added automatically by Bell" + (reason.map { ", because it mentions \($0)" } ?? ""))
    }
}

/// A task row used by the inbox and the today screen.
struct TaskRow: View {
    var task: TaskEvent
    var pressure: DeadlinePressure? = nil
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: Bell.Space.base) {
            Button(action: onDone) {
                Image(systemName: "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Bell.Content.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark done")

            VStack(alignment: .leading, spacing: Bell.Space.hair) {
                Text(task.title)
                    .font(Bell.Type_.body.weight(.medium))
                    .foregroundStyle(Bell.Content.primary)
                    .lineLimit(1)
                HStack(spacing: Bell.Space.snug) {
                    Text(task.due, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        .monospacedDigit()
                        .foregroundStyle(task.due.timeIntervalSinceNow < 2 * 86_400
                                         ? Bell.Signal.urgent : Bell.Content.secondary)
                    if let course = task.course {
                        Text(course).foregroundStyle(Bell.Content.tertiary)
                    }
                }
                .font(Bell.Type_.caption)
                if let pressure, pressure.effortHours > 0, pressure.level != .overdue {
                    // The free hours are measured; the effort isn't, so only
                    // the measured number is stated and the colour carries
                    // the judgement.
                    Text("About \(Int(pressure.freeHours.rounded())) free hours before it")
                        .font(Bell.Type_.micro)
                        .foregroundStyle(pressure.level >= .critical ? Bell.Signal.conflict
                                         : pressure.level == .tight ? Bell.Signal.urgent : Bell.Content.tertiary)
                }
                if task.isAutomatic { AutomaticBadge(reason: nil) }
            }
            Spacer(minLength: 0)
            Image(systemName: task.kind.symbol)
                .foregroundStyle(Bell.Content.tertiary)
        }
        .padding(.horizontal, Bell.Space.roomy)
        .padding(.vertical, Bell.Space.base)
        .background(RoundedRectangle(cornerRadius: Bell.Radius.large, style: .continuous)
            .fill(Bell.Surface.raised))
        .overlay {
            if task.isAutomatic {
                RoundedRectangle(cornerRadius: Bell.Radius.large, style: .continuous)
                    .strokeBorder(Bell.Signal.inferred.opacity(0.5), lineWidth: 1)
            }
        }
    }
}

// MARK: - Editing

private struct InboxEditor: View {
    @State var reading: InboxReading
    var courses: [String]
    var onSave: (InboxReading) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $reading.title)
                Picker("Kind", selection: $reading.kind) {
                    ForEach(TaskEvent.Kind.allCases, id: \.self) { kind in
                        Label(kind.rawValue.capitalized, systemImage: kind.symbol).tag(kind)
                    }
                }
                Toggle("Has a time", isOn: $reading.hasTime)
                DatePicker("When",
                           selection: Binding(get: { reading.start ?? .now }, set: { reading.start = $0 }),
                           displayedComponents: reading.hasTime ? [.date, .hourAndMinute] : [.date])
                TextField("Where", text: Binding(get: { reading.location ?? "" },
                                                 set: { reading.location = $0.isEmpty ? nil : $0 }))
                Picker("Course", selection: Binding(get: { reading.course ?? "" },
                                                    set: { reading.course = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag("")
                    ForEach(courses, id: \.self) { Text($0).tag($0) }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Check details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", role: .confirm) {
                        if reading.start == nil { reading.start = .now }
                        onSave(reading)
                        dismiss()
                    }
                    .disabled(reading.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private struct TypeIn: View {
    var onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(Bell.Space.gutter)
                .navigationTitle("Paste or type")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Read", role: .confirm) {
                            onSubmit(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { focused = true }
        }
    }
}

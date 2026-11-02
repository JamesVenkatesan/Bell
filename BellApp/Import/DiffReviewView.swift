import SwiftUI

/// The screen between parsing and writing.
///
/// Its whole job is to make the consequences visible before they happen. Three
/// rules shape it:
///
/// Unchanged rows are a count, not a list. "17 unchanged" is the number that
/// tells you the parse worked; seventeen identical rows would bury the three
/// that matter.
///
/// Removals are never ticked by default. A class the parser missed looks
/// exactly like a class you dropped, and the two have very different costs.
///
/// Low confidence is shown as what it is. A row the two parsers disagreed on
/// is marked, and the disagreement is named — "room uncertain" is actionable
/// where a percentage is not.
struct DiffReviewView: View {
    var result: ScheduleCapture.Result
    @Bindable var coordinator: ImportCoordinator
    var onDiagnostics: () -> Void
    var onApply: () -> Void

    private var diff: ScheduleDiff { coordinator.diff ?? result.diff }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Bell.Space.loose) {
                    header

                    if diff.isEmpty {
                        unchangedNotice
                    } else {
                        if !attentionChanges.isEmpty {
                            section("Worth checking", changes: attentionChanges)
                        }
                        if !routineChanges.isEmpty {
                            section("Changes", changes: routineChanges)
                        }
                    }

                    if !diff.unchanged.isEmpty {
                        Label("\(diff.unchanged.count) unchanged",
                              systemImage: "checkmark.circle")
                            .font(Bell.Type_.caption)
                            .foregroundStyle(Bell.Content.tertiary)
                    }

                    provenance
                }
                .padding(Bell.Space.gutter)
            }

            applyBar
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Bell.Space.tight) {
            Text(diff.summary)
                .font(Bell.Type_.title)

            if diff.needsAttention {
                Text("Some rows need a look before this is applied.")
                    .font(Bell.Type_.caption)
                    .foregroundStyle(Bell.Signal.urgent)
            }
        }
    }

    private var unchangedNotice: some View {
        VStack(alignment: .leading, spacing: Bell.Space.snug) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Bell.Signal.settled)
            Text("Your schedule already matches this.")
                .font(Bell.Type_.body)
            Text("Nothing to change.")
                .font(Bell.Type_.caption)
                .foregroundStyle(Bell.Content.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Bell.Space.loose)
    }

    // MARK: - Sections

    private var attentionChanges: [ScheduleDiff.Change] {
        diff.changes.filter { $0.kind.warrantsAttention || $0.confidence < 0.7 }
    }

    private var routineChanges: [ScheduleDiff.Change] {
        diff.changes.filter { !($0.kind.warrantsAttention || $0.confidence < 0.7) }
    }

    private func section(_ title: String, changes: [ScheduleDiff.Change]) -> some View {
        VStack(alignment: .leading, spacing: Bell.Space.snug) {
            Text(title)
                .font(Bell.Type_.micro)
                .foregroundStyle(Bell.Content.secondary)

            VStack(spacing: Bell.Space.snug) {
                ForEach(changes) { change in
                    ChangeRow(change: change) { accepted in
                        coordinator.setAccepted(accepted, forChangeID: change.id)
                    }
                    .transition(.bellRow)
                }
            }
        }
        .animation(Bell.Motion.standard, value: changes.count)
    }

    // MARK: - Provenance
    //
    // Saying how a result was produced is part of making it trustworthy. A
    // row that came from a calendar feed deserves more faith than one read off
    // a photograph, and the user can only weigh that if they're told.

    private var provenance: some View {
        VStack(alignment: .leading, spacing: Bell.Space.snug) {
            Label(result.method.summary,
                  systemImage: result.method.isApproximate ? "exclamationmark.circle" : "checkmark.seal")
                .foregroundStyle(result.method.isApproximate
                                 ? Bell.Signal.urgent : Bell.Content.tertiary)

            if let better = result.method.betterAlternative {
                Text(better).foregroundStyle(Bell.Content.secondary)
            }

            Button(action: onDiagnostics) {
                Label("Show what Bell read", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Bell.Signal.inferred)
            .padding(.top, Bell.Space.tight)

            if result.usedModel {
                Label("Cross-checked on device with Apple Intelligence.", systemImage: "sparkles")
                    .foregroundStyle(Bell.Content.tertiary)
            } else if let reason = result.modelUnavailableReason {
                Label(reason, systemImage: "info.circle")
                    .foregroundStyle(Bell.Content.tertiary)
            }
        }
        .font(Bell.Type_.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Bell.Space.snug)
    }

    // MARK: - Apply

    private var applyBar: some View {
        VStack(spacing: Bell.Space.snug) {
            if diff.changes.contains(where: { !$0.isAccepted }) {
                Button("Select all") { coordinator.acceptAll() }
                    .font(Bell.Type_.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Bell.Signal.inferred)
            }

            Button(action: onApply) {
                Text(applyLabel)
                    .font(Bell.Type_.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Bell.Space.base)
            }
            .buttonStyle(.borderedProminent)
            .disabled(diff.acceptedChanges.isEmpty && !diff.isEmpty)
        }
        .padding(Bell.Space.gutter)
        .background(.bar)
    }

    private var applyLabel: String {
        if diff.isEmpty { return "Done" }
        let count = diff.acceptedChanges.count
        return count == 0 ? "Nothing selected" : "Apply \(count) change\(count == 1 ? "" : "s")"
    }
}

// MARK: - Row

private struct ChangeRow: View {
    var change: ScheduleDiff.Change
    var onToggle: (Bool) -> Void

    private var event: ClassEvent { change.event }

    var body: some View {
        Button {
            onToggle(!change.isAccepted)
        } label: {
            HStack(alignment: .top, spacing: Bell.Space.base) {
                Image(systemName: change.isAccepted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(change.isAccepted ? Bell.Signal.settled : Bell.Content.tertiary)
                    .contentTransition(.symbolEffect(.replace))

                VStack(alignment: .leading, spacing: Bell.Space.tight) {
                    HStack(spacing: Bell.Space.snug) {
                        Label(change.kind.label, systemImage: change.kind.symbol)
                            .font(Bell.Type_.micro)
                            .foregroundStyle(tint)

                        if change.confidence < 0.7 {
                            Text(uncertaintyNote)
                                .font(Bell.Type_.micro)
                                .foregroundStyle(Bell.Signal.urgent)
                        }
                    }

                    Text(event.course).font(Bell.Type_.headline)

                    Text(detail)
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Content.secondary)

                    if let was = previousValue {
                        Text(was)
                            .font(Bell.Type_.caption)
                            .foregroundStyle(Bell.Content.tertiary)
                            .strikethrough()
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(Bell.Space.roomy)
            .background {
                RoundedRectangle(cornerRadius: Bell.Radius.large, style: .continuous)
                    .fill(Bell.Surface.raised)
                    .overlay {
                        RoundedRectangle(cornerRadius: Bell.Radius.large, style: .continuous)
                            .strokeBorder(tint.opacity(change.isAccepted ? 0.3 : 0.12),
                                          lineWidth: Bell.Stroke.hair)
                    }
            }
            .opacity(change.isAccepted ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .animation(Bell.Motion.snap, value: change.isAccepted)
    }

    private var tint: Color {
        if change.kind.warrantsAttention { return Bell.Signal.conflict }
        if change.confidence < 0.7 { return Bell.Signal.urgent }
        return Bell.Signal.settled
    }

    private var uncertaintyNote: String {
        if change.confidence < 0.6 { return "unverified" }
        return "check the details"
    }

    private var detail: String {
        var parts: [String] = [Self.dayName(event.dayIndex)]
        parts.append("\(Self.clock(event.startSecond))–\(Self.clock(event.endSecond))")
        if !event.room.isEmpty { parts.append(event.room) }
        return parts.joined(separator: " · ")
    }

    private var previousValue: String? {
        switch change.kind {
        case .relocated(let from):
            return from.isEmpty ? nil : "was \(from)"
        case .retimed(let start, let end):
            return "was \(Self.clock(start))–\(Self.clock(end))"
        case .moved(let day, let start):
            return "was \(Self.dayName(day)) \(Self.clock(start))"
        case .added, .removed:
            return nil
        }
    }

    private static func dayName(_ index: Int) -> String {
        ["Monday", "Tuesday", "Wednesday", "Thursday",
         "Friday", "Saturday", "Sunday"][max(0, min(6, index))]
    }

    private static func clock(_ seconds: Int) -> String {
        let hour = seconds / 3600
        let minute = (seconds % 3600) / 60
        let display = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d%@", display, minute, hour < 12 ? "am" : "pm")
    }
}

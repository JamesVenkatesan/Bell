import Foundation
import SwiftUI

/// Drives one import from start to finish.
///
/// Modelled as an explicit state machine because the alternative — a handful
/// of booleans for "is picking", "is parsing", "has error" — permits states
/// that make no sense, like parsing and showing an error at once. With one
/// enum those combinations can't be represented, so the UI never has to guess
/// which flag wins.
@MainActor
@Observable
final class ImportCoordinator {

    enum Phase {
        case idle
        case extracting
        case reading
        case reviewing(ScheduleCapture.Result)
        case applying
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .extracting, .reading, .applying: true
            default: false
            }
        }

        /// Worth being specific: "Reading the page" and "Understanding the
        /// schedule" are different waits, and saying which one you're in is
        /// most of what makes a multi-second operation tolerable.
        var message: String? {
            switch self {
            case .extracting: "Reading the page"
            case .reading: "Understanding the schedule"
            case .applying: "Updating your schedule"
            default: nil
            }
        }
    }

    var phase: Phase = .idle
    var diff: ScheduleDiff?

    /// Skips review and writes whatever was read. For when you already know
    /// the incoming schedule is the right one.
    var replaceOutright = false

    /// The raw extracted text of the last import, kept so the diagnostics
    /// screen can show exactly what Bell saw. When a parse goes wrong, this is
    /// the only thing that distinguishes a bad reader from bad extraction.
    private(set) var lastExtractedText: String = ""
    private(set) var lastMethod: ScheduleCapture.Result.Method?

    /// Set by the review screen as the user ticks and unticks rows.
    func setAccepted(_ accepted: Bool, forChangeID id: UUID) {
        guard var diff else { return }
        guard let index = diff.changes.firstIndex(where: { $0.id == id }) else { return }
        diff.changes[index].isAccepted = accepted
        self.diff = diff
        Haptic.tick.play()
    }

    func acceptAll() {
        guard var diff else { return }
        for index in diff.changes.indices { diff.changes[index].isAccepted = true }
        self.diff = diff
        Haptic.select.play()
    }

    func reset() {
        phase = .idle
        diff = nil
    }

    // MARK: - Running an import

    func importFile(at url: URL, store: BellStore) async {
        await run(source: .pdf) {
            self.phase = .extracting
            let pages = try await TextExtraction.pages(from: url)

            self.phase = .reading
            return await ScheduleCapture.capture(pages: pages,
                                                 against: store.timetable.events)
        }
    }

    func importImage(data: Data, source: CaptureSource, store: BellStore) async {
        await run(source: source) {
            self.phase = .extracting
            let page = try await TextExtraction.fromImageData(data)

            self.phase = .reading
            return await ScheduleCapture.capture(pages: [page],
                                                 against: store.timetable.events)
        }
    }

    func importSubscription(store: BellStore) async {
        await run(source: .subscription) {
            self.phase = .reading
            let timetable = try await Subscription.fetch()

            // A calendar feed is exact, so every row comes in at full
            // confidence and there's nothing to reconcile.
            let parsed = timetable.events.map { ParsedEvent(event: $0, confidence: 1) }

            return ScheduleCapture.Result(
                diff: ScheduleDiff.between(current: store.timetable.events, incoming: parsed),
                sourceText: "",
                method: .calendarFeed,
                usedModel: false,
                modelUnavailableReason: nil)
        }
    }

    private func run(source: CaptureSource,
                     _ work: @escaping () async throws -> ScheduleCapture.Result) async {
        do {
            let result = try await work()

            guard result.parsedCount > 0 else {
                phase = .failed("No classes found. If it's a photo, try again with the "
                                + "schedule filling the frame and the page flat.")
                Haptic.reject.play()
                return
            }

            lastExtractedText = result.sourceText
            lastMethod = result.method

            diff = result.diff
            phase = .reviewing(result)
            Haptic.confirm.play()
        } catch {
            phase = .failed(error.localizedDescription)
            Haptic.reject.play()
        }
    }

    // MARK: - Applying

    func apply(source: CaptureSource, store: BellStore) async {
        guard let diff else { return }
        phase = .applying

        var updated = store.timetable
        updated.events = diff.resolved(from: store.timetable.events)

        store.replaceSchedule(with: updated,
                              source: source,
                              summary: diff.summary)

        Haptic.confirm.play()
        reset()
    }
}

// MARK: - Diagnostics

extension ImportCoordinator {

    /// Everything Bell saw, as plain text.
    ///
    /// When an import comes out wrong there are two very different causes:
    /// the text was extracted badly, or it was extracted fine and read badly.
    /// Guessing between them wastes time. This shows the extraction verbatim,
    /// so the answer takes one look.
    var diagnosticReport: String {
        var report = "Bell import diagnostics\n"
        report += String(repeating: "=", count: 32) + "\n\n"

        if let lastMethod {
            report += "Reader used: \(lastMethod)\n"
            report += "\(lastMethod.summary)\n\n"
        } else {
            report += "Reader used: none — nothing was parsed\n\n"
        }

        if let diff {
            report += "Parsed \(diff.changes.count + diff.unchanged.count) meetings\n\n"
            for change in diff.changes {
                let event = change.event
                report += "  [\(change.kind.label)] \(event.course) | day \(event.dayIndex) "
                report += "| \(event.startSecond)-\(event.endSecond) | room '\(event.room)' "
                report += "| confidence \(String(format: "%.2f", change.confidence))\n"
            }
            report += "\n"
        }

        report += "Extracted text\n"
        report += String(repeating: "-", count: 32) + "\n"
        report += lastExtractedText.isEmpty ? "(none)" : lastExtractedText

        return report
    }
}

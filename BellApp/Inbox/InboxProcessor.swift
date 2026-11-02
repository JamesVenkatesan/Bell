import Photos
import SwiftUI

/// Turns captured text and images into inbox items.
///
/// One path for every way in: the share sheet's queue, a pasted message, a
/// screenshot. Each becomes text, the text is read twice, the readings are
/// merged, and the AI Override rule decides whether the result goes straight
/// in or waits for review.
@MainActor
@Observable
final class InboxProcessor {

    /// Off in tests that need the same answer on every machine: whether the
    /// on-device model runs depends on the Mac the simulator is on.
    @ObservationIgnored var usesModel = true

    private(set) var isWorking = false
    private(set) var lastError: String?

    /// Items added automatically in the last run, so the inbox can say so
    /// the moment it opens rather than leaving the user to notice.
    private(set) var justAutoAdded: [UUID] = []

    @discardableResult
    func process(text: String, source: CaptureSource, store: BellStore, now: Date = .now) async -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let courses = store.timetable.courses
        let detector = EventTextReader.read(trimmed, courses: courses, now: now)
        let model = usesModel ? await InboxModelReader.read(trimmed, courses: courses, now: now) : nil
        let result = InboxAgreement.merge(detector: detector, model: model, text: trimmed)

        let id = store.addInboxItem(result, source: source, rawText: trimmed)
        if case .add = AIOverride.decide(result, now: now) {
            store.accept(inboxID: id, automatic: true)
            justAutoAdded.append(id)
            Haptic.confirm.play()
        }
        return id
    }

    func process(imageData: Data, source: CaptureSource, store: BellStore) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let page = try await TextExtraction.fromImageData(imageData)
            let text = page.rows().map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
            await process(text: text, source: source, store: store)
            lastError = nil
        } catch {
            lastError = "Couldn't read any text in that image."
            Haptic.reject.play()
        }
    }

    /// Everything the share extension queued since last time.
    func drain(_ queue: CaptureQueue?, store: BellStore) async {
        guard let queue else { return }
        let pending = queue.pending()
        guard !pending.isEmpty else { return }

        isWorking = true
        defer { isWorking = false }
        for capture in pending {
            let source = CaptureSource(rawValue: capture.source) ?? .shareSheet
            if let data = queue.imageData(for: capture) {
                await process(imageData: data, source: source, store: store)
            } else if let text = capture.text {
                await process(text: text, source: source, store: store)
            }
            // Removed only once it's in the inbox. If processing crashed
            // above, the capture is still queued for next launch.
            queue.remove(capture)
        }
    }

    func clearJustAutoAdded() { justAutoAdded = [] }
}

// MARK: - Latest screenshot

/// The most recent screenshot in the photo library.
///
/// This is the substitute for reading Messages, which no iOS app can do: no
/// public API exposes SMS or iMessage content to third parties. Screenshot
/// the message, tap one button, and Bell reads it on device.
enum LatestScreenshot {

    enum Failure: Error, Equatable { case denied, none }

    static func load() async -> Result<Data, Failure> {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return .failure(.denied) }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0",
                                        PHAssetMediaSubtype.photoScreenshot.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else {
            return .failure(.none)
        }

        return await withCheckedContinuation { continuation in
            let request = PHImageRequestOptions()
            request.isNetworkAccessAllowed = true
            request.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: request) { data, _, _, _ in
                continuation.resume(returning: data.map { .success($0) } ?? .failure(.none))
            }
        }
    }
}

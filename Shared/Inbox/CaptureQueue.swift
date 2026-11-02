import Foundation

/// Things shared into Bell that haven't been read yet.
///
/// The share extension writes here and does nothing else. Reading text out of
/// an image and running the language model both happen in the app, because
/// a share extension is held to a tight memory ceiling and killed past it;
/// a Vision pass plus a model session on a large screenshot is exactly the
/// kind of work that gets an extension killed halfway, losing what was shared.
///
/// One JSON file per capture, plus the image beside it, written atomically.
/// A capture is either fully there or not there at all, and two processes
/// never edit the same file.
struct PendingCapture: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case text, url, image }

    var id: UUID = UUID()
    var capturedAt: Date = .now
    var kind: Kind
    var text: String?
    var imageFile: String?
    /// "shareSheet", "screenshot" or "photo": maps onto `CaptureSource`.
    var source: String
}

struct CaptureQueue {

    let directory: URL

    /// The queue both processes agree on. Nil when the App Group isn't
    /// provisioned, in which case sharing into Bell can't work at all and
    /// the extension says so rather than pretending it saved something.
    static var shared: CaptureQueue? {
        guard let base = AppGroup.containerURL else { return nil }
        return CaptureQueue(directory: base.appendingPathComponent("Inbox", isDirectory: true))
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // Its own coders rather than the app's `.bell` ones: those live beside
    // the snapshot code, and the share extension compiles only this file and
    // AppGroup. Fractional seconds, not ISO 8601, because ISO drops the
    // fraction and two shares in the same second came back in either order.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: - Writing (either process)

    @discardableResult
    func enqueue(text: String, kind: PendingCapture.Kind = .text, source: String = "shareSheet") throws -> PendingCapture {
        let capture = PendingCapture(kind: kind, text: text, source: source)
        try write(capture)
        return capture
    }

    @discardableResult
    func enqueue(imageData: Data, text: String? = nil, source: String = "shareSheet") throws -> PendingCapture {
        var capture = PendingCapture(kind: .image, text: text, source: source)
        let name = "\(capture.id.uuidString).img"
        // Image first: a capture file that points at a missing image is the
        // one half-written state worth ruling out.
        try imageData.write(to: directory.appendingPathComponent(name), options: .atomic)
        capture.imageFile = name
        try write(capture)
        return capture
    }

    private func write(_ capture: PendingCapture) throws {
        let data = try Self.encoder.encode(capture)
        try data.write(to: directory.appendingPathComponent("\(capture.id.uuidString).json"), options: .atomic)
    }

    // MARK: - Reading (app)

    /// Oldest first, so items land in the inbox in the order they were shared.
    func pending() -> [PendingCapture] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(PendingCapture.self, from: Data(contentsOf: $0)) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    func imageData(for capture: PendingCapture) -> Data? {
        guard let name = capture.imageFile else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// Called only after the capture has become an inbox item. Removing first
    /// and processing second would lose the capture if processing crashed.
    func remove(_ capture: PendingCapture) {
        let fm = FileManager.default
        try? fm.removeItem(at: directory.appendingPathComponent("\(capture.id.uuidString).json"))
        if let name = capture.imageFile {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

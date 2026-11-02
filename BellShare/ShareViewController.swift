import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The "Bell" row in the share sheet.
///
/// Takes what was shared, drops it in the App Group queue, says so, and
/// gets out of the way. No editing, no reading: the user is in the middle of
/// something else, and the honest promise is "it's in your inbox", which the
/// app keeps the next time it opens.
final class ShareViewController: UIViewController {

    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onClose = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ShareConfirmation(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { await capture() }
    }

    private func capture() async {
        guard let queue = CaptureQueue.shared else {
            model.state = .failed("Bell can't receive shares on this device: its shared storage isn't set up.")
            return
        }

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        // The share sheet's own text field, e.g. a Mail selection, comes as
        // attributedContentText alongside the attachments.
        let caption = items.compactMap { $0.attributedContentText?.string }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let providers = items.flatMap { $0.attachments ?? [] }

        do {
            var saved = false
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let data = try await loadData(provider, type: .image) {
                    try queue.enqueue(imageData: data, text: caption.isEmpty ? nil : caption)
                    saved = true
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                          let url = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    let text = [caption, url.absoluteString].filter { !$0.isEmpty }.joined(separator: "\n")
                    try queue.enqueue(text: text, kind: .url)
                    saved = true
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    try queue.enqueue(text: [caption, text].filter { !$0.isEmpty }.joined(separator: "\n"))
                    saved = true
                }
            }
            if !saved, !caption.isEmpty {
                try queue.enqueue(text: caption)
                saved = true
            }
            model.state = saved ? .saved : .failed("There was nothing Bell could read in that.")
        } catch {
            model.state = .failed("Couldn't save that: \(error.localizedDescription)")
        }

        if model.state == .saved {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            try? await Task.sleep(for: .milliseconds(900))
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
    }

}

@MainActor
@Observable
final class ShareModel {
    enum State: Equatable { case saving, saved, failed(String) }
    var state: State = .saving
    @ObservationIgnored var onClose: () -> Void = {}
}

/// A small card, not a full screen: the share sheet is a detour and should
/// feel like one. Uses system styling rather than Bell's tokens because the
/// extension deliberately doesn't link the design system.
private struct ShareConfirmation: View {
    var model: ShareModel

    var body: some View {
        VStack(spacing: 12) {
            switch model.state {
            case .saving:
                ProgressView()
                Text("Saving to Bell").font(.headline)
            case .saved:
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 34))
                    .symbolEffect(.bounce, options: .nonRepeating)
                Text("In Bell's inbox").font(.headline)
                Text("Open Bell to check what it found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("Close") { model.onClose() }
                .buttonStyle(.glass)
            }
        }
        .padding(28)
        .frame(maxWidth: 320)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.state)
    }
}

import PhotosUI
import SwiftUI
import VisionKit

/// Where an import starts.
///
/// Four routes, ordered by how good the result will be rather than by how
/// prominent they'd normally be. The subscription is first because it's exact
/// and keeps working; a photo is last because it's the one most likely to need
/// correcting. Putting the best option first is the cheapest quality
/// improvement available.
struct ImportView: View {
    @Environment(BellStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var coordinator = ImportCoordinator()
    @State private var isPickingFile = false
    @State private var isScanning = false
    @State private var photoItem: PhotosPickerItem?
    @State private var subscriptionURL = ""
    @State private var isEnteringURL = false
    @State private var isConfirmingClear = false
    @State private var isShowingDiagnostics = false

    var body: some View {
        NavigationStack {
            Group {
                switch coordinator.phase {
                case .reviewing(let result):
                    DiffReviewView(result: result,
                                   coordinator: coordinator,
                                   onDiagnostics: { isShowingDiagnostics = true }) {
                        Task {
                            await coordinator.apply(source: .pdf, store: store)
                            dismiss()
                        }
                    }
                    .task {
                        guard coordinator.replaceOutright else { return }
                        coordinator.acceptAll()
                        await coordinator.apply(source: .pdf, store: store)
                        dismiss()
                    }
                default:
                    sourceList
                }
            }
            .background(Bell.Surface.canvas)
            .navigationTitle("Update schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        coordinator.reset()
                        dismiss()
                    }
                }
            }
            .overlay { if coordinator.phase.isBusy { BusyOverlay(phase: coordinator.phase) } }
        }
        .fileImporter(isPresented: $isPickingFile,
                      allowedContentTypes: [.pdf, .image, .timetableExport, .data]) { result in
            guard case .success(let url) = result else { return }
            Task { await coordinator.importFile(at: url, store: store) }
        }
        .fullScreenCover(isPresented: $isScanning) {
            DocumentScanner { data in
                Task { await coordinator.importImage(data: data, source: .photo, store: store) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await coordinator.importImage(data: data, source: .screenshot, store: store)
            }
        }
        .confirmationDialog("Clear your schedule?",
                            isPresented: $isConfirmingClear,
                            titleVisibility: .visible) {
            Button("Clear schedule", role: .destructive) {
                store.clearSchedule()
                Haptic.warn.play()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every class. Term dates and breaks are kept, and this can be "
                 + "undone from the import history.")
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            DiagnosticsView(report: coordinator.diagnosticReport)
        }
        .alert("Couldn't read that", isPresented: .constant({
            if case .failed = coordinator.phase { return true }; return false
        }())) {
            Button("OK") { coordinator.reset() }
        } message: {
            if case .failed(let message) = coordinator.phase { Text(message) }
        }
    }

    // MARK: - Sources

    private var sourceList: some View {
        ScrollView {
            VStack(spacing: Bell.Space.base) {

                Toggle(isOn: $coordinator.replaceOutright) {
                    VStack(alignment: .leading, spacing: Bell.Space.tight) {
                        Text("Replace everything").font(Bell.Type_.headline)
                        Text("Skip the review and apply what's read straight away. "
                             + "Use when you know the incoming schedule is the right one.")
                            .font(Bell.Type_.caption)
                            .foregroundStyle(Bell.Content.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Bell.Space.roomy)
                .background {
                    RoundedRectangle(cornerRadius: Bell.Radius.card, style: .continuous)
                        .fill(Bell.Surface.raised)
                }

                if !store.timetable.events.isEmpty {
                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        Label("Clear schedule", systemImage: "trash")
                            .font(Bell.Type_.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Bell.Space.roomy)
                            .background {
                                RoundedRectangle(cornerRadius: Bell.Radius.card,
                                                 style: .continuous)
                                    .fill(Bell.Surface.raised)
                            }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Bell.Signal.conflict)
                }

                SourceCard(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Subscribe to your schedule",
                    detail: Subscription.isActive
                        ? "Connected to \(Subscription.displayName ?? "your calendar"). Updates on its own."
                        : "The best option. Your registrar's calendar link keeps Bell current without you doing anything.",
                    emphasis: true) {
                        if Subscription.isActive {
                            Task { await coordinator.importSubscription(store: store) }
                        } else {
                            isEnteringURL = true
                        }
                    }

                SourceCard(
                    symbol: "doc.text",
                    title: "Open a PDF",
                    detail: "The printable schedule from your student portal.") {
                        isPickingFile = true
                    }

                PhotosPicker(selection: $photoItem, matching: .images) {
                    SourceCardBody(
                        symbol: "photo",
                        title: "Choose a screenshot",
                        detail: "A screenshot of your schedule from any app.",
                        emphasis: false)
                }
                .buttonStyle(.plain)

                SourceCard(
                    symbol: "camera",
                    title: "Photograph it",
                    detail: "Point at a printed schedule. Works best on a flat page in good light.") {
                        isScanning = true
                    }

                if !IntelligentParser.isAvailable, let reason = IntelligentParser.unavailableReason {
                    Label(reason, systemImage: "info.circle")
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Content.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Bell.Space.snug)
                }
            }
            .padding(Bell.Space.gutter)
        }
        .alert("Calendar link", isPresented: $isEnteringURL) {
            TextField("https://…", text: $subscriptionURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Connect") {
                guard let url = URL(string: subscriptionURL.trimmingCharacters(in: .whitespaces))
                else { return }
                Subscription.url = url
                Task { await coordinator.importSubscription(store: store) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In UniTime, open your schedule, choose Export, then Export iCalendar. "
                 + "Paste that link here. It stays on this device.")
        }
    }
}

// MARK: - Pieces

private struct SourceCard: View {
    var symbol: String
    var title: String
    var detail: String
    var emphasis: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            SourceCardBody(symbol: symbol, title: title, detail: detail, emphasis: emphasis)
        }
        .buttonStyle(.plain)
    }
}

private struct SourceCardBody: View {
    var symbol: String
    var title: String
    var detail: String
    var emphasis: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Bell.Space.base) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(emphasis ? Bell.Signal.inferred : Bell.Content.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: Bell.Space.tight) {
                Text(title).font(Bell.Type_.headline)
                Text(detail)
                    .font(Bell.Type_.caption)
                    .foregroundStyle(Bell.Content.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(Bell.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Bell.Radius.card, style: .continuous)
                .fill(Bell.Surface.raised)
                .overlay {
                    RoundedRectangle(cornerRadius: Bell.Radius.card, style: .continuous)
                        .strokeBorder(emphasis ? Bell.Signal.inferred.opacity(0.35)
                                               : Bell.Surface.hairline,
                                      lineWidth: emphasis ? 1 : Bell.Stroke.hair)
                }
        }
    }
}

private struct BusyOverlay: View {
    var phase: ImportCoordinator.Phase

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: Bell.Space.base) {
                ProgressView()
                if let message = phase.message {
                    Text(message)
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Content.secondary)
                        .transition(.opacity)
                }
            }
        }
        .animation(Bell.Motion.standard, value: phase.message)
    }
}

// MARK: - Camera

/// VisionKit's scanner rather than a raw camera: it finds the page edges,
/// corrects perspective and thresholds the image, which is most of what makes
/// OCR on a photographed page work at all.
private struct DocumentScanner: UIViewControllerRepresentable {
    var onScan: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScanner

        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            if scan.pageCount > 0, let data = scan.imageOfPage(at: 0).pngData() {
                parent.onScan(data)
            }
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}

// MARK: - Diagnostics
//
// Not hidden behind a developer flag. When an import goes wrong the useful
// question is "what did it actually see", and the answer should be one tap
// away rather than something only the author can get at.

struct DiagnosticsView: View {
    var report: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Bell.Space.gutter)
            }
            .background(Bell.Surface.canvas)
            .navigationTitle("What Bell read")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: report) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
    }
}

import SwiftUI
import UIKit
import VisionKit

/// The camera with no shutter. Point it at a confirmation on a monitor and it
/// takes the picture itself, the way a QR scanner locks on.
///
/// Pressing a button was the awkward part of the old flow: you are holding the
/// phone up to a screen at arm's length, and the hand that steadies it is the
/// hand that has to reach the shutter. `ScanLock` waits for the frame to be
/// worth it instead.
///
/// Falls back to the shutter when there is no scanner to be had — the
/// simulator has no camera, and `CameraPicker` already knows to offer the
/// library in that case, which is what makes this screen testable at all.
struct BookingScanner: View {

    let onCapture: (Data) -> Void

    @State private var isReading = false
    @Environment(\.dismiss) private var dismiss

    private var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        if canScan {
            ZStack {
                LockOnScanner(isReading: $isReading, onCapture: onCapture)
                    .ignoresSafeArea()
                chrome
            }
            .background(.black)
        } else {
            CameraPicker(onCapture: onCapture).ignoresSafeArea()
        }
    }

    /// White on a scrim rather than the app's palette: this sits over a camera
    /// feed of an unknown wall, and nothing else on screen is ours to match.
    private var chrome: some View {
        VStack {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: .capsule)
                Spacer()
            }
            Spacer()
            // A viewfinder with no shutter reads as a broken camera unless it
            // says what it is doing, and the tap is invisible until named —
            // which is the whole reason it is named here rather than drawn as
            // a button competing with the aiming.
            Text(isReading ? "Reading the booking…" : "Point at the confirmation, or tap to capture")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.black.opacity(0.55), in: .capsule)
                .animation(.easeInOut(duration: 0.2), value: isReading)
        }
        .padding(20)
    }
}

/// `DataScannerViewController` doing live text recognition, with the shutter
/// wired to `ScanLock` instead of to a finger.
private struct LockOnScanner: UIViewControllerRepresentable {

    @Binding var isReading: Bool
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> ScannerHost {
        // Accurate rather than fast: the text is small, several metres of
        // pixels away on somebody else's monitor, and a fast reading of a desk
        // id is a misreading of a desk id. Multiple items because a table
        // arrives as one recognised block per row.
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        let host = ScannerHost(scanner: scanner)
        host.onTap = { [weak scanner] in
            guard let scanner else { return }
            context.coordinator.captureNow(from: scanner)
        }
        return host
    }

    // SwiftUI hands the coordinator a fresh binding and dismiss action here;
    // the ones captured when it was made belong to a view that no longer
    // exists.
    func updateUIViewController(_ host: ScannerHost, context: Context) {
        context.coordinator.onReading = { isReading = $0 }
        context.coordinator.onFinish = { dismiss() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {

        private let onCapture: (Data) -> Void
        var onReading: (Bool) -> Void = { _ in }
        var onFinish: () -> Void = {}
        private var lock = ScanLock()

        init(onCapture: @escaping (Data) -> Void) {
            self.onCapture = onCapture
        }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            consider(allItems, in: scanner)
        }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            consider(allItems, in: scanner)
        }

        /// Every recognised item joined line by line, so a desk id sitting in
        /// one block and the word that corroborates it sitting in another
        /// still meet. The newline keeps them separate tokens — joined without
        /// one, two innocent blocks could spell a desk id between them.
        private func consider(_ items: [RecognizedItem], in scanner: DataScannerViewController) {
            let text = items.compactMap { item in
                if case .text(let text) = item { return text.transcript } else { return nil }
            }.joined(separator: "\n")

            guard lock.observe(text) != nil else { return }
            capture(from: scanner)
        }

        /// The user tapped rather than waiting. Whatever is in front of the
        /// lens goes to the model as it stands — a frame the lock would have
        /// refused is still a frame the review sheet stands in front of.
        func captureNow(from scanner: DataScannerViewController) {
            guard lock.lockNow() else { return }
            capture(from: scanner)
        }

        private func capture(from scanner: DataScannerViewController) {
            // Stop first: recognition carries on over the shutter otherwise,
            // and the frames it reports while the photo is being taken are of
            // a booking already on its way to being read.
            scanner.stopScanning()
            onReading(true)

            Task {
                do {
                    let photo = try await scanner.capturePhoto()
                    // Near-lossless here for the same reason the picker is —
                    // `PhotoImport` does the real downsizing, and two lossy
                    // passes over small text is one too many. `jpegData` also
                    // bakes in the orientation, so a phone held sideways
                    // arrives upright.
                    guard let data = photo.jpegData(compressionQuality: CameraPicker.quality)
                    else { throw CaptureError.unreadableImage }
                    onCapture(data)
                    onFinish()
                } catch {
                    // The frame was lost, not the booking. Going back to
                    // looking costs the user nothing; dismissing to an error
                    // sheet for a dropped frame would cost them the aim they
                    // were holding.
                    onReading(false)
                    lock.reset()
                    try? scanner.startScanning()
                }
            }
        }
    }
}

/// Holds the scanner as a child so that scanning can start when there is a
/// camera preview to scan through and stop when there is not.
///
/// A child rather than a subclass because `DataScannerViewController` is not
/// open, and the timing has to come from somewhere: `startScanning` throws if
/// the view is not on screen yet, which is exactly what
/// `updateUIViewController` cannot promise.
final class ScannerHost: UIViewController {

    /// The user tapped instead of waiting for the lock.
    var onTap: () -> Void = {}

    private let scanner: DataScannerViewController

    init(scanner: DataScannerViewController) {
        self.scanner = scanner
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not loaded from a nib.") }

    override func loadView() {
        let view = TapToCaptureView()
        view.onActivate = { [weak self] in self?.onTap() }
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)

        // On the host rather than on the scanner's own view, and passing the
        // touches on rather than swallowing them, so that pinch-to-zoom and
        // whatever else the scanner listens for still get what they expect.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc private func tapped() {
        onTap()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        try? scanner.startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stopScanning()
    }
}

/// The viewfinder as one large button, because a gesture recogniser is not an
/// accessibility element: without this the tap that captures exists only for
/// people who can see where to put a finger.
private final class TapToCaptureView: UIView {

    var onActivate: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Capture the booking now"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not loaded from a nib.") }

    override func accessibilityActivate() -> Bool {
        onActivate()
        return true
    }
}

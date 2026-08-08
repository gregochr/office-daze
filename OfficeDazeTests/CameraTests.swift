import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
import VisionKit
@testable import OfficeDaze

/// The two camera wrappers, driven from the side a simulator can reach.
///
/// Neither of these can be tested end to end anywhere but on a phone: there is
/// no camera here, `DataScannerViewController.isSupported` is false, and
/// `capturePhoto()` has nothing to photograph. What that leaves is still most
/// of the code — the delegate callbacks, the frame that becomes JPEG bytes, the
/// lock deciding when to fire, the accessibility of a viewfinder that is
/// otherwise a gesture recogniser, and the cancellation rule that stops a
/// shutter in flight calling back into a screen the user has already dismissed.
/// Those are driven directly with constructed inputs, which is why the shutter
/// itself is an injectable closure.
@Suite("The camera")
@MainActor
struct CameraTests {

    // MARK: The picker

    /// Cropping is the user saying which part of the confirmation matters. The
    /// original is the fallback, not the preference — sending the uncropped
    /// frame after someone has framed the row they wanted read is sending the
    /// model the table they just excluded.
    @Test("A cropped frame is the one that is sent, and the original only stands in for it")
    func theEditedFrameIsPreferredOverTheOriginal() throws {
        let picked = Picked()
        let coordinator = CameraPicker.Coordinator(
            quality: CameraPicker.quality,
            onCapture: { picked.capture($0) },
            onFinish: { picked.finish() }
        )

        coordinator.imagePickerController(
            UIImagePickerController(),
            didFinishPickingMediaWithInfo: [
                .editedImage: try image(width: 100, height: 50),
                .originalImage: try image(width: 200, height: 80),
            ]
        )

        let sent = try #require(picked.images.first)
        let size = try #require(TestImage.dimensions(sent))
        #expect(size.width == 100 && size.height == 50, "the crop, not what it was cut from")
        #expect(picked.finished == 1, "and the picker closes behind it")
    }

    @Test("An uncropped pick sends the frame as it was taken")
    func theOriginalIsSentWhenNothingWasCropped() throws {
        let picked = Picked()
        let coordinator = CameraPicker.Coordinator(
            quality: CameraPicker.quality,
            onCapture: { picked.capture($0) },
            onFinish: { picked.finish() }
        )

        coordinator.imagePickerController(
            UIImagePickerController(),
            didFinishPickingMediaWithInfo: [.originalImage: try image(width: 200, height: 80)]
        )

        let sent = try #require(picked.images.first)
        let size = try #require(TestImage.dimensions(sent))
        #expect(size.width == 200 && size.height == 80)
        #expect(picked.finished == 1)
    }

    /// The negative of the two above. A callback with no image in it at all is
    /// not something the camera does, but it is what a movie pick or a future
    /// media type would deliver, and `onCapture(Data())` there would open the
    /// capture sheet on zero bytes and spend the API call that refuses them.
    /// Closing is still right: the picker is finished either way.
    @Test("A pick with no image behind it captures nothing and still closes the picker")
    func aPickWithNoImageCapturesNothing() {
        let picked = Picked()
        let coordinator = CameraPicker.Coordinator(
            quality: CameraPicker.quality,
            onCapture: { picked.capture($0) },
            onFinish: { picked.finish() }
        )

        coordinator.imagePickerController(
            UIImagePickerController(), didFinishPickingMediaWithInfo: [:]
        )

        #expect(picked.images.isEmpty)
        #expect(picked.finished == 1, "and the sheet does not stay up with nothing to do")
    }

    @Test("Cancelling the picker closes it without capturing anything")
    func cancellingCapturesNothing() {
        let picked = Picked()
        let coordinator = CameraPicker.Coordinator(
            quality: CameraPicker.quality,
            onCapture: { picked.capture($0) },
            onFinish: { picked.finish() }
        )

        coordinator.imagePickerControllerDidCancel(UIImagePickerController())

        #expect(picked.images.isEmpty)
        #expect(picked.finished == 1)
    }

    /// The quality is near-lossless on purpose: `PhotoImport` does the real
    /// downsizing, and two lossy passes over a desk id photographed off a
    /// monitor is one too many. Asserted by comparing the same frame encoded
    /// both ways rather than by reading the constant back — a coordinator that
    /// ignored the number it was given and hardcoded one would pass that.
    @Test("The frame is encoded at the quality the picker asked for")
    func theQualityGivenIsTheQualityUsed() throws {
        let frame = try #require(
            UIImage(data: TestImage.make(width: 200, height: 200, type: .png, noisy: true))
        )
        let hard = Picked()
        let light = Picked()
        CameraPicker.Coordinator(quality: 0.1, onCapture: { hard.capture($0) }, onFinish: {})
            .imagePickerController(
                UIImagePickerController(), didFinishPickingMediaWithInfo: [.originalImage: frame]
            )
        CameraPicker.Coordinator(
            quality: CameraPicker.quality, onCapture: { light.capture($0) }, onFinish: {}
        ).imagePickerController(
            UIImagePickerController(), didFinishPickingMediaWithInfo: [.originalImage: frame]
        )

        let compressed = try #require(hard.images.first).count
        let asShipped = try #require(light.images.first).count
        #expect(compressed < asShipped, "the argument reaches the encoder")
        #expect(
            CameraPicker.quality > 0.9,
            "and what the app ships with is the near-lossless end of that range"
        )
    }

    // MARK: The scanner screen

    /// The fallback is what makes this screen usable at all off a device, and
    /// the reason it exists is drawn from the same fact this whole file works
    /// around: with no scanner to be had, a viewfinder is a black rectangle.
    @Test("With no scanner available the screen falls back to the picker rather than a black view")
    func theScannerFallsBackToThePicker() throws {
        #expect(
            DataScannerViewController.isSupported == false,
            "the host has no camera, which is the branch being taken below"
        )

        let host = UIHostingController(rootView: BookingScanner(onCapture: { _ in }))
        let window = ArrivalPreviewRenderTests.renderWindow()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        let picker = try #require(
            Self.descendant(of: host, as: UIImagePickerController.self),
            "the else branch put a real picker on screen"
        )
        #expect(
            UIImagePickerController.isSourceTypeAvailable(picker.sourceType),
            "and pointed it at a source this device actually has"
        )
        #expect(picker.delegate is CameraPicker.Coordinator, "wired to the coordinator")
    }

    /// A viewfinder with no shutter reads as a broken camera unless it says
    /// what it is doing. Both strings, because the one that matters is the one
    /// that appears after the lock fires — the cue that makes someone who did
    /// not mean to capture reach for Cancel.
    @Test("The viewfinder says whether it is looking or reading")
    func theViewfinderNamesWhatItIsDoing() {
        #expect(
            BookingScanner.prompt(isReading: false)
                == "Point at the confirmation, or tap to capture"
        )
        #expect(BookingScanner.prompt(isReading: true) == "Reading the booking…")
    }

    // MARK: The scanner host

    /// Without this the tap that captures exists only for people who can see
    /// where to put a finger: a `UITapGestureRecognizer` is not an
    /// accessibility element and VoiceOver has nothing to offer.
    @Test("The viewfinder is one large button for anyone who cannot see where to tap")
    func theViewfinderIsAButton() throws {
        let host = ScannerHost(scanner: Self.scanner())
        let tapped = Counter()
        host.onTap = { tapped.count += 1 }
        host.loadViewIfNeeded()

        #expect(host.view.isAccessibilityElement)
        #expect(host.view.accessibilityLabel == "Capture the booking now")
        #expect(host.view.accessibilityTraits.contains(.button))
        #expect(host.view.accessibilityActivate())
        #expect(tapped.count == 1, "and activating it fires the shutter")
    }

    /// A child rather than a subclass, because `DataScannerViewController` is
    /// not open. The containment has to be complete — a scanner added as a
    /// subview without `addChild`/`didMove` never receives the appearance
    /// callbacks its own camera session is started from.
    @Test("The scanner is contained as a child and made to fill the host")
    func theScannerIsContainedProperly() throws {
        let scanner = Self.scanner()
        let host = ScannerHost(scanner: scanner)
        host.loadViewIfNeeded()

        #expect(host.children.count == 1)
        #expect(host.children.first === scanner, "added as a child, not just as a subview")
        #expect(scanner.view.superview === host.view)
        #expect(scanner.parent === host)
        #expect(scanner.view.autoresizingMask == [.flexibleWidth, .flexibleHeight])

        let tap = try #require(
            host.view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first
        )
        #expect(
            tap.cancelsTouchesInView == false,
            "the touches go on to the scanner, or pinch-to-zoom stops working"
        )
    }

    /// `startScanning` throws when there is nothing to scan through, which is
    /// every run of this suite. The assertion is that the screen survives it:
    /// a `try!` here — or a scanner left believing it is running — would take
    /// the whole capture flow down on any device without a camera.
    @Test("A host that cannot start scanning comes up anyway and goes away quietly")
    func appearingWithoutACameraDoesNotCrash() {
        let scanner = Self.scanner()
        let host = ScannerHost(scanner: scanner)
        host.loadViewIfNeeded()

        host.viewDidAppear(false)
        #expect(scanner.isScanning == false, "it could not start, and did not pretend to")

        host.viewWillDisappear(false)
        #expect(scanner.isScanning == false)
    }

    // MARK: The lock-on coordinator

    /// The whole feature: three frames holding the same desk id, alongside a
    /// word only a booking document carries, and the shutter goes off by
    /// itself. Asserted as "not before the third", because a lock that fired on
    /// the first frame would fire mid-pan on whatever happened to be sharp.
    @Test("The shutter fires itself once the same booking has held still for three frames")
    func theLockFiresTheShutterOnceTheFrameSettles() async throws {
        let seen = Shots()
        let coordinator = coordinator(capturing: seen, returning: try image(width: 120, height: 60))
        let scanner = Self.scanner()
        let frame = "CONFIRMED\nDesk CO03C117\nColeman Street"

        coordinator.consider(text: frame, in: scanner)
        coordinator.consider(text: frame, in: scanner)
        #expect(seen.shutters == 0, "two frames is a pan, not an aim")
        #expect(seen.reading.isEmpty)

        coordinator.consider(text: frame, in: scanner)
        #expect(
            seen.reading == [true],
            "the third settles it, and the viewfinder says so before the shutter opens"
        )

        try await seen.wait { seen.captured.count == 1 }
        #expect(seen.shutters == 1)
        let photograph = try #require(seen.captured.first)
        let size = try #require(TestImage.dimensions(photograph))
        #expect(size.width == 120 && size.height == 60, "the frame in front of the lens")
        #expect(seen.finished == 1, "which dismisses the scanner")

        // The debounce is a latch, not a cooldown: frames keep arriving while
        // the shutter is open and each one would be another billed call.
        coordinator.consider(text: frame, in: scanner)
        coordinator.consider(text: frame, in: scanner)
        #expect(seen.shutters == 1, "one lock, one call")
    }

    /// A tap is the way out of a document whose wording none of the lock's cues
    /// match — a viewfinder that never goes off, with only Cancel out of it.
    /// Whatever is in front of the lens goes as it stands.
    @Test("A tap captures a frame the lock itself would have refused")
    func aTapCapturesWhatTheLockWouldNot() async throws {
        let seen = Shots()
        let coordinator = coordinator(capturing: seen, returning: try image(width: 90, height: 30))
        let scanner = Self.scanner()

        coordinator.consider(text: "Nothing here looks like a booking", in: scanner)
        #expect(seen.shutters == 0, "the lock refuses it")

        coordinator.captureNow(from: scanner)

        #expect(seen.reading == [true])
        try await seen.wait { seen.captured.count == 1 }
        #expect(seen.shutters == 1)
        let photograph = try #require(seen.captured.first)
        let size = try #require(TestImage.dimensions(photograph))
        #expect(size.width == 90 && size.height == 30)

        coordinator.captureNow(from: scanner)
        #expect(seen.shutters == 1, "and a second tap on a locked scanner spends nothing")
    }

    /// The delegate callbacks themselves, with the only frame that can be built
    /// outside the framework: an empty one. `RecognizedItem.Text` has no
    /// initializer, so a recognised frame is unconstructible — but an empty
    /// `allItems` is a real thing the scanner reports, and firing on it would
    /// mean a call for a wall.
    @Test("A frame with nothing recognised in it fires nothing")
    func anEmptyFrameFiresNothing() {
        let seen = Shots()
        let coordinator = coordinator(capturing: seen, returning: UIImage())
        let scanner = Self.scanner()

        coordinator.dataScanner(scanner, didAdd: [], allItems: [])
        coordinator.dataScanner(scanner, didUpdate: [], allItems: [])

        #expect(seen.shutters == 0)
        #expect(seen.reading.isEmpty, "and the viewfinder never claims to be reading")
    }

    /// The frame was lost, not the booking. Dismissing to an error sheet for a
    /// dropped frame would cost the user the aim they were holding, so the
    /// scanner goes back to looking — and the lock has to be released with it,
    /// or it is a viewfinder that has quietly stopped scanning for good.
    @Test("A shutter that fails puts the viewfinder back rather than ending the scan")
    func aFailedShutterResumesLooking() async throws {
        let seen = Shots()
        let coordinator = LockOnScanner.Coordinator(onCapture: { seen.capture($0) })
        coordinator.onReading = { seen.read($0) }
        coordinator.onFinish = { seen.finish() }
        coordinator.takePhoto = { _ in
            seen.shutter()
            throw CaptureError.unreadableImage
        }
        let scanner = Self.scanner()
        let frame = "BOOKING\nCO03C117"

        for _ in 0..<3 { coordinator.consider(text: frame, in: scanner) }

        try await seen.wait { seen.reading.count == 2 }
        #expect(seen.reading == [true, false], "reading, then looking again")
        #expect(seen.captured.isEmpty, "nothing was sent")
        #expect(seen.finished == 0, "and the screen stayed up")

        // The lock was released, so the next three frames can fire again. That
        // is the assertion that `reset()` ran: without it this scanner is dead.
        for _ in 0..<3 { coordinator.consider(text: frame, in: scanner) }
        try await seen.wait { seen.reading.count == 4 }
        #expect(seen.shutters == 2, "the lock was released, so the frame can settle again")
        #expect(seen.reading == [true, false, true, false])
    }

    /// The same failure with the screen already gone. The catch is the worse
    /// half of the two: it calls `startScanning()` on a dismissed controller
    /// and puts "Point at the confirmation" back through a binding into a view
    /// that no longer exists, with the failure swallowed by `try?` so nothing
    /// says so.
    @Test("A shutter that fails after the screen went does not restart the scan")
    func aCancelledShutterThatFailsRestartsNothing() async throws {
        let seen = Shots()
        let release = AsyncStream<Void>.makeStream()
        let coordinator = LockOnScanner.Coordinator(onCapture: { seen.capture($0) })
        coordinator.onReading = { seen.read($0) }
        coordinator.onFinish = { seen.finish() }
        coordinator.takePhoto = { _ in
            seen.shutter()
            for await _ in release.stream { break }
            seen.returned()
            throw CaptureError.unreadableImage
        }

        coordinator.captureNow(from: Self.scanner())
        try await seen.wait { seen.shutters == 1 }

        coordinator.cancelShot()
        release.continuation.yield()
        try await seen.wait { seen.returns == 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(seen.reading == [true], "no viewfinder put back on a controller that has gone")
        #expect(seen.captured.isEmpty)
        #expect(seen.finished == 0)
    }

    /// The rule the shutter's cancellation exists for. `capturePhoto()` is not
    /// cancellable and resolves whether or not the screen is still there, so
    /// without the check a photograph the user walked away from opens the
    /// capture sheet on the home screen and spends a billed model call. Held
    /// open at the shutter rather than timed, because a race cancelled at an
    /// unpredictable point is a test that passes for the wrong reason.
    @Test("A shutter cancelled with the screen never calls back into it")
    func aCancelledShutterCallsBackIntoNothing() async throws {
        let seen = Shots()
        let release = AsyncStream<Void>.makeStream()
        let coordinator = LockOnScanner.Coordinator(onCapture: { seen.capture($0) })
        coordinator.onReading = { seen.read($0) }
        coordinator.onFinish = { seen.finish() }
        let photo = try image(width: 40, height: 40)
        coordinator.takePhoto = { _ in
            seen.shutter()
            for await _ in release.stream { break }
            seen.returned()
            return photo
        }

        coordinator.captureNow(from: Self.scanner())
        try await seen.wait { seen.shutters == 1 }

        coordinator.cancelShot()
        release.continuation.yield()
        try await seen.wait { seen.returns == 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(seen.captured.isEmpty, "no capture sheet for a photograph nobody wanted")
        #expect(seen.finished == 0, "and no dismiss sent to a screen already gone")
        #expect(seen.reading == [true], "nor a viewfinder put back on a dismissed controller")
    }

    /// The same shutter, left alone. Without this the test above is satisfied
    /// by a coordinator that never captures anything at all.
    @Test("A shutter nobody cancelled hands the photograph over")
    func anUncancelledShutterDelivers() async throws {
        let seen = Shots()
        let release = AsyncStream<Void>.makeStream()
        let coordinator = LockOnScanner.Coordinator(onCapture: { seen.capture($0) })
        coordinator.onReading = { seen.read($0) }
        coordinator.onFinish = { seen.finish() }
        let photo = try image(width: 40, height: 40)
        coordinator.takePhoto = { _ in
            seen.shutter()
            for await _ in release.stream { break }
            seen.returned()
            return photo
        }

        coordinator.captureNow(from: Self.scanner())
        try await seen.wait { seen.shutters == 1 }
        release.continuation.yield()

        try await seen.wait { seen.captured.count == 1 }
        #expect(seen.finished == 1)
        let photograph = try #require(seen.captured.first)
        let size = try #require(TestImage.dimensions(photograph))
        #expect(size.width == 40 && size.height == 40)
    }

    /// And the production trigger for that cancellation: SwiftUI is finished
    /// with the representable, which is what a dismissed `fullScreenCover`
    /// amounts to. Chosen over `viewWillDisappear`, which also fires for things
    /// that are not a teardown — so this is the callback that has to be wired,
    /// and wiring it to nothing would leave the whole rule above unreachable.
    @Test("Tearing the scanner down cancels a shutter still in flight")
    func dismantlingCancelsTheShutter() async throws {
        let seen = Shots()
        let release = AsyncStream<Void>.makeStream()
        let coordinator = LockOnScanner.Coordinator(onCapture: { seen.capture($0) })
        coordinator.onReading = { seen.read($0) }
        coordinator.onFinish = { seen.finish() }
        let photo = try image(width: 40, height: 40)
        coordinator.takePhoto = { _ in
            seen.shutter()
            for await _ in release.stream { break }
            seen.returned()
            return photo
        }
        let scanner = Self.scanner()
        let host = ScannerHost(scanner: scanner)

        coordinator.captureNow(from: scanner)
        try await seen.wait { seen.shutters == 1 }

        LockOnScanner.dismantleUIViewController(host, coordinator: coordinator)
        release.continuation.yield()
        try await seen.wait { seen.returns == 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(seen.captured.isEmpty)
        #expect(seen.finished == 0)
    }

    // MARK: Helpers

    private func coordinator(capturing seen: Shots, returning photo: UIImage)
        -> LockOnScanner.Coordinator {
        let coordinator = LockOnScanner.Coordinator(onCapture: { seen.capture($0) })
        coordinator.onReading = { seen.read($0) }
        coordinator.onFinish = { seen.finish() }
        coordinator.takePhoto = { _ in
            seen.shutter()
            return photo
        }
        return coordinator
    }

    /// A scanner to hand to the delegate methods. Constructed rather than
    /// stubbed because `DataScannerViewController` is not a protocol anywhere —
    /// it is only ever asked to stop and start here, which it will do
    /// (unsuccessfully, and without complaint) on a host with no camera.
    private static func scanner() -> DataScannerViewController {
        DataScannerViewController(
            recognizedDataTypes: [.text()], qualityLevel: .accurate,
            recognizesMultipleItems: true, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: false, isHighlightingEnabled: true
        )
    }

    /// A real image of a known size, so what came out of the encoder can be
    /// told apart from what went in rather than merely counted.
    private func image(width: Int, height: Int) throws -> UIImage {
        try #require(UIImage(data: TestImage.make(width: width, height: height, type: .png)))
    }

    /// The first descendant of this controller of a given type, wherever
    /// SwiftUI decided to put it.
    private static func descendant<T: UIViewController>(
        of controller: UIViewController, as type: T.Type
    ) -> T? {
        if let match = controller as? T { return match }
        for child in controller.children {
            if let match = descendant(of: child, as: type) { return match }
        }
        return controller.presentedViewController.flatMap { descendant(of: $0, as: type) }
    }

    /// What the picker's coordinator handed on, so the double is answerable for
    /// its arguments rather than merely for having been called.
    final class Picked {
        private(set) var images: [Data] = []
        private(set) var finished = 0

        func capture(_ data: Data) { images.append(data) }
        func finish() { finished += 1 }
    }

    final class Counter {
        var count = 0
    }

    /// Everything the scanner's coordinator did, in order — including how many
    /// times it opened the shutter, which is the number a billed call is
    /// attached to.
    final class Shots {
        private(set) var captured: [Data] = []
        private(set) var reading: [Bool] = []
        private(set) var finished = 0
        private(set) var shutters = 0
        private(set) var returns = 0

        func capture(_ data: Data) { captured.append(data) }
        func read(_ isReading: Bool) { reading.append(isReading) }
        func finish() { finished += 1 }
        func shutter() { shutters += 1 }
        func returned() { returns += 1 }

        /// Waits for the shutter's task to land, and gives up rather than
        /// hanging the suite — the assertion after the wait is what reports the
        /// failure, and it reports the state instead of a timeout.
        func wait(for condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}

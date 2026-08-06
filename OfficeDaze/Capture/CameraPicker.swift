import SwiftUI
import UIKit

/// The system camera, handing back the frame as JPEG.
///
/// `UIImagePickerController` rather than anything newer because SwiftUI still
/// has no camera of its own — `PhotosPicker` reads the library and nothing
/// else. This is the smallest wrapper that takes one picture and stops.
///
/// The frame is never written to the photo library. Photographing a monitor to
/// read a desk number off it should not leave a picture of a monitor in your
/// camera roll, and not saving it is also why no library permission is needed.
struct CameraPicker: UIViewControllerRepresentable {

    /// Near-lossless. The real downsizing is `PhotoImport`'s job, and
    /// compressing hard here would mean two lossy passes over the small text
    /// the model has to read.
    static let quality = 0.95

    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Falls back to the library rather than presenting a black screen —
        // the simulator has no camera, and neither does an iPad without one.
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera
            : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(quality: Self.quality, onCapture: onCapture, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let quality: Double
        let onCapture: (Data) -> Void
        let onFinish: () -> Void

        init(quality: Double, onCapture: @escaping (Data) -> Void, onFinish: @escaping () -> Void) {
            self.quality = quality
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // `jpegData` bakes in the orientation, so a picture taken sideways
            // arrives upright rather than relying on EXIF surviving the trip.
            let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage
            if let data = image?.jpegData(compressionQuality: quality) {
                onCapture(data)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}

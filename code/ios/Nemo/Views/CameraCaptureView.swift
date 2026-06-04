import SwiftUI
import UIKit

struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void
    let onError: (CameraCaptureError) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraCaptureView

        init(parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.onError(.missingImage)
                return
            }

            guard let imageData = image.jpegData(compressionQuality: 0.84) else {
                parent.onError(.imageConversionFailed)
                return
            }

            parent.onCapture(imageData)
        }
    }
}

enum CameraCaptureError: LocalizedError {
    case unavailable
    case missingImage
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Camera is not available on this device."
        case .missingImage:
            return "The camera did not return a photo."
        case .imageConversionFailed:
            return "Could not prepare the captured photo."
        }
    }
}

import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO

extension SessionTab {
    func importPhotos(_ items: [PhotosPickerItem]) {
        guard !importing, !sending, !closed else { return }
        importing = true; mediaError = nil
        importTask = Task {
            defer { importing = false; importTask = nil }
            do {
                for item in items {
                    try Task.checkCancellation()
                    guard !closed, attachments.count < MediaStore.maximumAttachments else { throw MediaStore.InvalidImage() }
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw MediaStore.InvalidImage() }
                    try await appendImage(data)
                }
            } catch {
                if !closed { mediaError = "Could not add every image. Use JPEG, HEIC or PNG images up to 32 MiB; eight attachments maximum. Existing images are retained." }
            }
        }
    }
    func importCameraImage(_ image: UIImage) {
        guard !importing, !sending, !closed, attachments.count < MediaStore.maximumAttachments else { return }
        importing = true; mediaError = nil
        importTask = Task {
            defer { importing = false; importTask = nil }
            do {
                guard let data = image.jpegData(compressionQuality: 0.9) else { throw MediaStore.InvalidImage() }
                try await appendImage(data)
            } catch { if !closed { mediaError = "Could not add this photo. Try again or choose an image from your library." } }
        }
    }
}

struct AttachmentStrip: View {
    @ObservedObject var tab: SessionTab
    @State private var preview: DraftAttachment?
    var body: some View {
        VStack(alignment:.leading, spacing:4) {
            if tab.importing { ProgressView("Adding images…").font(.caption) }
            if let message = tab.mediaError { Text(message).font(.caption).foregroundStyle(.red) }
            if !tab.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(tab.attachments.enumerated()),id:\.element.id) { index, attachment in
                            VStack(spacing:2) {
                                Button { preview = attachment } label: {
                                    if let image = tab.thumbnails[attachment.id] {
                                        Image(uiImage:image).resizable().scaledToFill().frame(width:64,height:64).clipped().clipShape(RoundedRectangle(cornerRadius:8))
                                    } else { Image(systemName:"photo").frame(width:64,height:64) }
                                }.accessibilityLabel("Preview image \(index + 1)")
                                Button { tab.removeImage(attachment) } label: { Image(systemName:"xmark.circle.fill") }
                                    .accessibilityLabel("Remove image \(index + 1)").disabled(tab.sending || tab.importing)
                            }
                        }
                    }
                }.accessibilityIdentifier("composer.attachments")
            }
        }.sheet(item:$preview) { attachment in
            NavigationStack {
                if let data = try? tab.media.data(for: attachment), let image = UIImage(data:data) {
                    Image(uiImage:image).resizable().scaledToFit().padding()
                        .toolbar { Button("Done") { preview = nil } }
                } else {
                    Text("This local image is unavailable.").toolbar { Button("Done") { preview = nil } }
                }
            }
        }
    }
}

struct PhotoActions: View {
    @ObservedObject var tab: SessionTab
    @State private var selected: [PhotosPickerItem] = []
    @State private var camera = false
    @State private var asking = false
    var body: some View {
        HStack(spacing: 16) {
            Button {
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else { tab.mediaError = "Camera is unavailable here. Choose photos from your library."; return }
                asking = true
                Task {
                    let allowed = await AVCaptureDevice.requestAccess(for:.video)
                    asking = false
                    guard !tab.closed else { return }
                    if allowed { camera = true }
                    else { tab.mediaError = "Camera access is off. Enable it for Chadmux in iPhone Settings, or choose library images." }
                }
            } label: { Image(systemName:"camera") }.accessibilityLabel("Take photo")
            PhotosPicker(selection:$selected, maxSelectionCount:max(1,MediaStore.maximumAttachments-tab.attachments.count), matching:.images) {
                Image(systemName:"photo.on.rectangle")
            }.accessibilityLabel("Choose photos")
        }.disabled(tab.sending || tab.importing || asking || tab.attachments.count >= MediaStore.maximumAttachments)
            .onChange(of:selected) { _, items in
                guard !items.isEmpty else { return }
                selected = []; tab.importPhotos(items)
            }
            .fullScreenCover(isPresented:$camera) {
                CameraCapture { image in camera = false; if let image { tab.importCameraImage(image) } }.ignoresSafeArea()
            }
    }
}

struct CameraCapture: UIViewControllerRepresentable {
    var finished: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished:finished) }
    func makeUIViewController(context:Context) -> UIImagePickerController {
        let camera = UIImagePickerController(); camera.sourceType = .camera; camera.delegate = context.coordinator
        return camera
    }
    func updateUIViewController(_ uiViewController:UIImagePickerController, context:Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finished: (UIImage?) -> Void
        init(finished:@escaping (UIImage?) -> Void) { self.finished = finished }
        func imagePickerControllerDidCancel(_ picker:UIImagePickerController) { finished(nil) }
        func imagePickerController(_ picker:UIImagePickerController, didFinishPickingMediaWithInfo info:[UIImagePickerController.InfoKey:Any]) {
            finished(info[.originalImage] as? UIImage)
        }
    }
}

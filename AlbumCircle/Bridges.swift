import SwiftUI
import PhotosUI
import CloudKit

struct PhotoPicker: UIViewControllerRepresentable {
    var completion: ([String]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: ([String]) -> Void
        init(_ completion: @escaping ([String]) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let ids = results.compactMap(\.assetIdentifier)
            picker.dismiss(animated: true) {
                self.completion(ids)
                if ids.count != results.count {
                    Task { @MainActor in CloudStore.shared.errorMessage = "一部の写真の原本にアクセスできませんでした。写真へのアクセス許可を確認してください。" }
                }
            }
        }
    }
}
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    var onChange: () -> Void
    var onError: (Error) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onChange, onError: onError) }
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: CloudStore.shared.container)
        controller.availablePermissions = [.allowPrivate, .allowReadOnly, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}
    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onChange: () -> Void
        let onError: (Error) -> Void
        init(_ onChange: @escaping () -> Void, onError: @escaping (Error) -> Void) {
            self.onChange = onChange; self.onError = onError
        }
        func itemTitle(for csc: UICloudSharingController) -> String? { csc.share?[CKShare.SystemFieldKey.title] as? String }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            onError(error)
        }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { onChange() }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { onChange() }
    }
}
struct FileExportView: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

struct ShareManagementView: View {
    let share: CKShare
    @State private var message: String?
    var body: some View {
        CloudSharingView(share: share, onChange: {
            Task { await CloudStore.shared.refresh() }
        }, onError: { error in message = error.localizedDescription })
        .alert("共有設定を保存できませんでした", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }
}

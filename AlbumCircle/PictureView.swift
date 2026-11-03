import SwiftUI
import CloudKit
import UIKit

/// One presentation item carries both the tapped photo and a stable paging snapshot.
/// Its identity is independent of read-state/filter updates in the album underneath.
struct PhotoPreviewSelection: Identifiable {
    let id = UUID()
    let pictures: [Picture]
    let initialID: CKRecord.ID

    init(picture: Picture, pictures: [Picture]) {
        initialID = picture.id
        // A refresh may remove the tapped item from the current filtered list.
        self.pictures = pictures.contains(where: { $0.id == picture.id }) ? pictures : [picture] + pictures
    }
}

struct PictureView: View {
    let pictures: [Picture]
    let album: Album
    let editable: Bool
    @ObservedObject private var store = CloudStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int
    @State private var displayID: CKRecord.ID?
    @State private var display: UIImage?
    @State private var working = false
    @State private var remove = false
    @State private var message: String?
    @State private var editing = false
    @State private var savedRotations: [CKRecord.ID: Int] = [:]
    @State private var draftRotations: [CKRecord.ID: Int] = [:]
    @State private var rotationRequestVersion = 0
    @State private var details = false
    init(pictures: [Picture], initialID: CKRecord.ID, album: Album, editable: Bool) {
        self.pictures = pictures
        self.album = album
        self.editable = editable
        _selection = State(initialValue: pictures.firstIndex { $0.id == initialID } ?? 0)
    }
    private var current: Picture? { pictures.indices.contains(selection) ? pictures[selection] : nil }
    private var rotations: [CKRecord.ID: Int] {
        savedRotations.merging(draftRotations) { _, draft in draft }
    }
    private func savedRotation(for picture: Picture) -> Int {
        savedRotations[picture.id] ?? picture.rotationQuarterTurns
    }
    private func rotation(for picture: Picture) -> Int {
        draftRotations[picture.id] ?? savedRotation(for: picture)
    }
    var body: some View {
        NavigationStack {
            if let picture = current {
                PhotoPager(pictures: pictures, selection: $selection,
                           originalPreview: displayID == picture.id ? display : nil,
                           rotationOverrides: rotations,
                           interactionsEnabled: !working && !remove && !editing,
                           onClose: { dismiss() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        if editable && editing {
                            HStack(spacing: 15) {
                                Button("左に90度回転", systemImage: "rotate.left") { rotate(picture, by: -1) }
                                Button("180°") { rotate(picture, by: 2) }
                                    .font(.subheadline.weight(.semibold))
                                    .accessibilityLabel("180度回転")
                                Button("右に90度回転", systemImage: "rotate.right") { rotate(picture, by: 1) }
                                Button("元の向き", systemImage: "arrow.uturn.backward") {
                                    draftRotations[picture.id] = 0
                                }
                                .disabled(rotation(for: picture) == 0)
                                if rotation(for: picture) != savedRotation(for: picture) {
                                    Button("保存") { Task { await saveRotation(for: picture) } }
                                    .font(.subheadline.weight(.semibold))
                                }
                            }
                            .font(.title3)
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(.black.opacity(0.75), in: Capsule())
                            .padding(.bottom, 50)
                            .disabled(working)
                        }
                    }
                    .accessibilityHint("左右のスワイプで前後の写真、下へのスワイプで閉じます。拡大中はダブルタップで戻してから操作できます。")
                .navigationTitle(picture.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if editing {
                            Button("編集をキャンセル", systemImage: "xmark") { cancelEditing(picture) }.disabled(working)
                        } else {
                            Button("閉じる", systemImage: "xmark") { dismiss() }.disabled(working)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        FavoritePhotoButton(picture: picture, album: album).disabled(working)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("写真の詳細", systemImage: "info.circle") { details = true }.disabled(working)
                    }
                    if editable {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                if editing {
                                    Button("編集を終了", systemImage: "xmark") { cancelEditing(picture) }
                                } else {
                                    Button("編集", systemImage: "slider.horizontal.3") { editing = true }
                                }
                                Button("削除", systemImage: "trash", role: .destructive) {
                                    if editing { cancelEditing(picture) }
                                    remove = true
                                }.disabled(store.busy)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("写真のメニュー")
                            .disabled(working)
                        }
                    }
                }
                .sheet(isPresented: $details) { PhotoDetailsView(picture: picture, album: album) }
                .task(id: picture.id) {
                    NewPhotoTracker.shared.markRead([picture.id.recordName], scope: store.newPhotoScope(for: album))
                    await loadDisplay(for: picture)
                }
                .task(id: picture.id) { await refreshRotation(for: picture) }
                .alert(album.storage == .device ? "本体の写真を削除しますか？" : "写真を全員から削除しますか？", isPresented: $remove) {
                    Button("キャンセル", role: .cancel) {}
                    Button("削除", role: .destructive) {
                        Task {
                            working = true
                            defer { working = false }
                            do {
                                try await store.delete(picture, album: album)
                                store.revision = UUID()
                                dismiss()
                            } catch { message = error.localizedDescription }
                        }
                    }
                } message: {
                    Text("このアルバムの原本を削除します。表紙に使っていた場合は未設定の表示になります。メンバーが端末へ保存した写真は削除されません。")
                }
            } else {
                ContentUnavailableView("写真がありません", systemImage: "photo")
                Button("閉じる") { dismiss() }
            }
        }
        .tint(.albumAccent)
        .interactiveDismissDisabled(working || editing)
        .alert("お知らせ", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .onChange(of: store.accountEpoch) { _, _ in
            if album.storage == .iCloud { display = nil; dismiss() }
        }
        .onChange(of: store.revision) { _, _ in
            if !store.albums.contains(where: { $0.id == album.id }) { display = nil; dismiss() }
        }
        .onChange(of: store.contentsRevision) { _, _ in
            Task { await adoptUpdatedRotation() }
        }
    }
    private func cancelEditing(_ picture: Picture) {
        draftRotations.removeValue(forKey: picture.id)
        editing = false
    }
    private func rotate(_ picture: Picture, by step: Int) {
        draftRotations[picture.id] = (rotation(for: picture) + step + 4) % 4
    }
    private func saveRotation(for picture: Picture) async {
        let turns = rotation(for: picture)
        guard turns != savedRotation(for: picture), !working else { return }
        rotationRequestVersion += 1
        working = true
        defer { working = false }
        do {
            try await store.setRotation(turns, for: picture, in: album)
            savedRotations[picture.id] = turns
            draftRotations.removeValue(forKey: picture.id)
            editing = false
        } catch { message = error.localizedDescription }
    }
    private func refreshRotation(for picture: Picture) async {
        guard album.storage == .iCloud else { return }
        let version = rotationRequestVersion
        guard let turns = try? await store.refreshRotation(for: picture, in: album),
              !Task.isCancelled, version == rotationRequestVersion,
              current?.id == picture.id else { return }
        savedRotations[picture.id] = turns
    }
    private func adoptUpdatedRotation() async {
        guard album.storage == .iCloud, let picture = current,
              let contents = try? await store.contents(in: album),
              let updated = contents.pictures.first(where: { $0.id == picture.id }),
              current?.id == picture.id else { return }
        savedRotations[picture.id] = updated.rotationQuarterTurns
    }
    private func loadDisplay(for picture: Picture) async {
        guard !Task.isCancelled, current?.id == picture.id else { return }
        display = nil
        displayID = nil
        let key = album.id + "/" + picture.id.recordName
        if let cached = HighResPhotoCache.shared.image(forKey: key) {
            display = cached
            displayID = picture.id
            return
        }
        let epoch = store.accountEpoch
        do {
            let original = try await store.download(picture, album: album)
            defer { original.clean() }
            try Task.checkCancellation()
            try store.checkAccount(epoch, for: album)
            let decoded = await Task.detached(priority: .userInitiated) {
                Original.displayImage(original.urls[0])
            }.value
            try Task.checkCancellation()
            try store.checkAccount(epoch, for: album)
            guard current?.id == picture.id else { return }
            if let decoded {
                HighResPhotoCache.shared.insert(decoded, forKey: key)
                display = decoded
                displayID = picture.id
            }
        } catch is CancellationError {
            // A quick swipe or dismissal leaves the next photo free to load.
        } catch {
            if !Task.isCancelled, current?.id == picture.id { message = "原本を表示できませんでした。\n" + error.localizedDescription }
        }
    }
}

// Integrated from PhotoPager.swift
/// Native horizontal paging; the inner scroll view owns pinch/zoom and vertical dismissal.
@MainActor
struct PhotoPager: UIViewControllerRepresentable {
    let pictures: [Picture]
    @Binding var selection: Int
    var originalPreview: UIImage?
    var rotationOverrides: [CKRecord.ID: Int]
    var interactionsEnabled: Bool
    var onClose: () -> Void
    func rotation(for index: Int) -> Int {
        let picture = pictures[index]
        return rotationOverrides[picture.id] ?? picture.rotationQuarterTurns
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let view = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        context.coordinator.controller = view
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        if pictures.indices.contains(selection) {
            view.setViewControllers([context.coordinator.page(selection)], direction: .forward, animated: false)
        }
        return view
    }
    func updateUIViewController(_ view: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if let page = view.viewControllers?.first as? PhotoPageController {
            if page.index != selection && !coordinator.transitioning && pictures.indices.contains(selection) {
                coordinator.transitioning = true
                view.setViewControllers([coordinator.page(selection)], direction: selection > page.index ? .forward : .reverse, animated: false) { _ in
                    coordinator.transitioning = false
                    coordinator.updatePaging()
                }
            } else if page.index == selection {
                page.photo.setRotation(rotation(for: selection))
                if let originalPreview { page.photo.setImage(originalPreview) }
            }
        }
        coordinator.updatePaging()
    }
    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoPager
        weak var controller: UIPageViewController?
        var transitioning = false
        init(_ parent: PhotoPager) { self.parent = parent }
        func page(_ index: Int) -> PhotoPageController {
            let page = PhotoPageController(index: index, picture: parent.pictures[index])
            page.loadViewIfNeeded()
            page.photo.setRotation(parent.rotation(for: index))
            page.photo.onClose = { [weak self] in
                guard let self, self.parent.interactionsEnabled, !self.transitioning else { return }
                self.parent.onClose()
            }
            page.photo.onZoom = { [weak self] _ in self?.updatePaging() }
            if index == parent.selection, let image = parent.originalPreview { page.photo.setImage(image) }
            return page
        }
        func updatePaging() {
            guard let controller, let page = controller.viewControllers?.first as? PhotoPageController else { return }
            page.photo.allowsDismiss = parent.interactionsEnabled && !transitioning
            let enabled = parent.interactionsEnabled && page.photo.zoomScale <= 1.01 && !page.photo.isZooming
            for scroll in controller.view.subviews.compactMap({ $0 as? UIScrollView }) {
                scroll.panGestureRecognizer.maximumNumberOfTouches = 1
                scroll.isScrollEnabled = enabled
            }
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PhotoPageController, page.index > 0 else { return nil }
            return self.page(page.index - 1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PhotoPageController, page.index + 1 < parent.pictures.count else { return nil }
            return self.page(page.index + 1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true
            updatePaging()
        }
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            if completed, let page = pageViewController.viewControllers?.first as? PhotoPageController {
                parent.selection = page.index
                for previous in previousViewControllers.compactMap({ $0 as? PhotoPageController }) { previous.photo.setZoomScale(1, animated: false) }
            }
            updatePaging()
        }
    }
}

final class PhotoPageController: UIViewController {
    let index: Int
    let picture: Picture
    let photo = PhotoScrollView()
    private var previewTask: Task<Void, Never>?
    init(index: Int, picture: Picture) {
        self.index = index
        self.picture = picture
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = photo
        photo.backgroundColor = .black
        photo.accessibilityLabel = picture.name
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        let data = picture.preview, key = picture.id.recordName
        previewTask = Task { [weak self] in
            guard let data else { return }
            let image = await Task.detached(priority: .userInitiated) { ThumbnailCache.shared.image(key: key, data: data) }.value
            guard !Task.isCancelled, let self, let image else { return }
            // Do not replace an already supplied original preview with a small thumbnail.
            self.photo.setInitialImage(image)
        }
    }
    deinit { previewTask?.cancel() }
}

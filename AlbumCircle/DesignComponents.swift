import SwiftUI
import UIKit

enum AlbumBackground: String, CaseIterable, Identifiable {
    case standard, blue, sage, rose
    static let settingKey = "albumBackgroundColor"
    static var current: AlbumBackground {
        AlbumBackground(rawValue: UserDefaults.standard.string(forKey: settingKey) ?? "") ?? .standard
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "標準"
        case .blue: return "ブルー"
        case .sage: return "セージ"
        case .rose: return "ローズ"
        }
    }
    var swatch: Color {
        switch self {
        case .standard: return Color(red: 0.92, green: 0.93, blue: 0.95)
        case .blue: return Color(red: 0.77, green: 0.85, blue: 0.98)
        case .sage: return Color(red: 0.76, green: 0.88, blue: 0.78)
        case .rose: return Color(red: 0.96, green: 0.80, blue: 0.85)
        }
    }
    var color: Color {
        switch self {
        case .standard: return Color(uiColor: .systemGroupedBackground)
        case .blue: return Self.adaptive(light: UIColor(red: 0.92, green: 0.95, blue: 0.99, alpha: 1),
                                  dark: UIColor(red: 0.07, green: 0.10, blue: 0.17, alpha: 1))
        case .sage: return Self.adaptive(light: UIColor(red: 0.92, green: 0.96, blue: 0.93, alpha: 1),
                                  dark: UIColor(red: 0.08, green: 0.14, blue: 0.11, alpha: 1))
        case .rose: return Self.adaptive(light: UIColor(red: 0.99, green: 0.94, blue: 0.96, alpha: 1),
                                  dark: UIColor(red: 0.17, green: 0.09, blue: 0.14, alpha: 1))
        }
    }
    var accent: Color {
        switch self {
        case .standard: return Self.adaptive(light: UIColor(red: 0.08, green: 0.40, blue: 0.41, alpha: 1),
                                      dark: UIColor(red: 0.43, green: 0.83, blue: 0.80, alpha: 1))
        case .blue: return Self.adaptive(light: UIColor(red: 0.10, green: 0.33, blue: 0.72, alpha: 1),
                                  dark: UIColor(red: 0.56, green: 0.74, blue: 1.0, alpha: 1))
        case .sage: return Self.adaptive(light: UIColor(red: 0.13, green: 0.42, blue: 0.31, alpha: 1),
                                  dark: UIColor(red: 0.53, green: 0.82, blue: 0.63, alpha: 1))
        case .rose: return Self.adaptive(light: UIColor(red: 0.62, green: 0.20, blue: 0.42, alpha: 1),
                                  dark: UIColor(red: 0.95, green: 0.62, blue: 0.75, alpha: 1))
        }
    }
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
    }
}

extension Color {
    static var albumAccent: Color { AlbumBackground.current.accent }
}

struct InlineNotice: View {
    let text: String
    var symbol = "info.circle"
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
            .font(.footnote).foregroundStyle(.secondary)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
struct ImportProgressView: View {
    @ObservedObject var store = CloudStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProgressView()
                Text(store.progress).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                if store.importCanStop {
                    Button(store.stopRequested ? "停止待ち" : "停止") { store.requestStop() }
                        .disabled(store.stopRequested).frame(minWidth: 44, minHeight: 44)
                }
            }
            if store.importCanStop {
                Text(store.stopRequested ? "処理中の写真が終わったら停止します。元の写真は削除しません。" : "画面を閉じても保存を続け、必要に応じて再開します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 18).padding(.vertical, 10).background(.regularMaterial)
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.totalCostLimit = 32 * 1024 * 1024 }
    func image(key: String, data: Data) -> UIImage? {
        if let image = cache.object(forKey: key as NSString) { return image }
        guard let image = UIImage(data: data) else { return nil }
        let decoded = image.preparingForDisplay() ?? image
        cache.setObject(decoded, forKey: key as NSString, cost: Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4))
        return decoded
    }
    func removeAll() { cache.removeAllObjects() }
}

/// Reuse decoded display images when returning to a photo; originals remain on disk only while decoding.
final class HighResPhotoCache: @unchecked Sendable {
    static let shared = HighResPhotoCache()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.totalCostLimit = 96 * 1024 * 1024 }
    func image(forKey key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func insert(_ image: UIImage, forKey key: String) {
        let cost = image.cgImage.map { $0.width * $0.height * 4 } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
    func removeAll() { cache.removeAllObjects() }
}
struct PictureThumbnail: View {
    let picture: Picture
    var aspect: CGFloat = 1
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.albumAccent.opacity(0.08)
                if let image {
                    let sideways = picture.rotationQuarterTurns % 2 != 0
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: sideways ? geometry.size.height : geometry.size.width,
                               height: sideways ? geometry.size.width : geometry.size.height)
                        .rotationEffect(.degrees(Double(picture.rotationQuarterTurns * 90)))
                }
                else { Image(systemName: "photo").font(.title2).foregroundStyle(Color.albumAccent) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: picture.id.recordName + (picture.preview == nil ? "/waiting" : "/ready")) {
            image = nil
            guard let data = picture.preview else { return }
            let key = picture.id.recordName
            let decoded = await Task.detached(priority: .userInitiated) { ThumbnailCache.shared.image(key: key, data: data) }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

/// Owns temporary original files until the preview AND any export sheet release them.
final class PreviewFiles: ObservableObject {
    @Published var original: Original?
    func clear() { original?.clean(); original = nil }
    deinit { original?.clean() }
}

struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> PhotoScrollView { PhotoScrollView() }
    func updateUIView(_ view: PhotoScrollView, context: Context) { view.setImage(image) }
}
final class PhotoScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onClose: (() -> Void)?
    var onZoom: ((Bool) -> Void)?
    var allowsDismiss = true
    private var closePan: UIPanGestureRecognizer!
    private let imageContainer = UIView()
    private let photo = UIImageView()
    private var lastBounds = CGSize.zero
    private var rotationQuarterTurns = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        photo.contentMode = .scaleAspectFit
        photo.isAccessibilityElement = true
        photo.accessibilityLabel = "写真のプレビュー"
        addSubview(imageContainer)
        imageContainer.addSubview(photo)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        panGestureRecognizer.isEnabled = false
        closePan = UIPanGestureRecognizer(target: self, action: #selector(closeGesture(_:)))
        closePan.maximumNumberOfTouches = 1
        closePan.delegate = self
        addGestureRecognizer(closePan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setInitialImage(_ image: UIImage) { if photo.image == nil { setImage(image) } }
    func setImage(_ image: UIImage) {
        guard photo.image !== image else { return }
        photo.image = image
        lastBounds = .zero
        setNeedsLayout()
    }
    func setRotation(_ quarterTurns: Int) {
        let normalized = (quarterTurns % 4 + 4) % 4
        guard rotationQuarterTurns != normalized else { return }
        rotationQuarterTurns = normalized
        lastBounds = .zero
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBounds, bounds.width > 0, bounds.height > 0, let image = photo.image {
            lastBounds = bounds.size
            setZoomScale(1, animated: false)
            let sideways = rotationQuarterTurns % 2 != 0
            let width = sideways ? image.size.height : image.size.width
            let height = sideways ? image.size.width : image.size.height
            let ratio = min(bounds.width / max(width, 1), bounds.height / max(height, 1))
            imageContainer.frame = CGRect(origin: .zero, size: CGSize(width: width * ratio, height: height * ratio))
            photo.transform = .identity
            photo.bounds = CGRect(origin: .zero, size: CGSize(width: image.size.width * ratio, height: image.size.height * ratio))
            photo.center = CGPoint(x: imageContainer.bounds.midX, y: imageContainer.bounds.midY)
            photo.transform = CGAffineTransform(rotationAngle: CGFloat(rotationQuarterTurns) * .pi / 2)
            contentSize = imageContainer.frame.size
        }
        centerPhoto()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageContainer }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerPhoto()
        let zoomed = zoomScale > 1.01
        if panGestureRecognizer.isEnabled != zoomed { panGestureRecognizer.isEnabled = zoomed }
        onZoom?(zoomed)
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // Re-enable page gestures after UIKit has cleared its isZooming flag.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onZoom?(self.zoomScale > 1.01)
        }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === closePan {
            let v = closePan.velocity(in: window)
            return allowsDismiss && zoomScale <= 1.01 && v.y > 0 && v.y > abs(v.x) * 1.4
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === closePan || other === closePan
    }
    @objc private func closeGesture(_ gesture: UIPanGestureRecognizer) {
        let distance = max(0, gesture.translation(in: window).y)
        switch gesture.state {
        case .began, .changed:
            transform = CGAffineTransform(translationX: 0, y: distance)
            alpha = max(0.45, 1 - distance / max(bounds.height, 1))
        case .ended:
            if allowsDismiss && (distance > 100 || (distance > 35 && gesture.velocity(in: window).y > 900)) { onClose?() }
            resetDrag()
        case .cancelled, .failed: resetDrag()
        default: break
        }
    }
    private func resetDrag() {
        UIView.animate(withDuration: 0.2) { self.transform = .identity; self.alpha = 1 }
    }
    private func centerPhoto() {
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let target = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != target { contentInset = target }
    }
    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 { setZoomScale(1, animated: true); return }
        let point = gesture.location(in: imageContainer)
        let rect = CGRect(x: point.x - bounds.width / 6, y: point.y - bounds.height / 6,
                          width: bounds.width / 3, height: bounds.height / 3)
        zoom(to: rect, animated: true)
    }
}

/// Fixed three-column layout on iPhone and iPad, including larger text settings.
let albumGridColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10), count: 3)

struct FolderSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(12.0, w * 0.10), tab = min(12.0, h * 0.08)
        var p = Path()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: w * 0.27, y: 0))
        p.addQuadCurve(to: CGPoint(x: w * 0.34, y: tab * 0.4), control: CGPoint(x: w * 0.31, y: 0))
        p.addLine(to: CGPoint(x: w * 0.41, y: tab))
        p.addLine(to: CGPoint(x: w - r, y: tab))
        p.addQuadCurve(to: CGPoint(x: w, y: tab + r), control: CGPoint(x: w, y: tab))
        p.addLine(to: CGPoint(x: w, y: h - r))
        p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: r, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero)
        p.closeSubpath()
        return p
    }
}

struct FolderCard: View {
    let title: String
    let count: Int?
    var cover: Picture?
    var symbol = "folder"
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let cover { PictureThumbnail(picture: cover, aspect: 1.45) }
                else {
                    Rectangle().fill(Color.albumAccent.opacity(0.10))
                        .overlay { Image(systemName: "photo").font(.title2).foregroundStyle(Color.albumAccent.opacity(0.6)) }
                        .aspectRatio(1.45, contentMode: .fit)
                }
            }.padding(.top, 10).padding(.horizontal, 3)
            VStack(alignment: .leading, spacing: 4) {
                ScrollingTitle(title: title)
                HStack(spacing: 3) {
                    Text(count.map { "\($0)枚" } ?? "—枚").font(.caption)
                    Spacer(minLength: 0)
                    Image(systemName: symbol).font(.caption2)
                }.foregroundStyle(.secondary)
            }.padding(.horizontal, 9).padding(.vertical, 9)
        }
        .foregroundStyle(.primary)
        .background(LinearGradient(colors: [Color(uiColor: .tertiarySystemFill), Color(uiColor: .secondarySystemGroupedBackground)], startPoint: .top, endPoint: .bottom))
        .clipShape(FolderSilhouette())
        .contentShape(Rectangle())
        .overlay { FolderSilhouette().stroke(Color.primary.opacity(0.10), lineWidth: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + "、" + (count.map { "\($0)枚" } ?? "読み込み中") + (detail.map { "、" + $0 } ?? ""))
        .accessibilityHint("フォルダを開きます")
    }
}

/// Starts a horizontal marquee only when a long title becomes visible in a lazy grid.
struct ScrollingTitle: View {
    let title: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var offset: CGFloat = 0
    private let gap: CGFloat = 28
    private var font: UIFont {
        UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
    }
    private var textWidth: CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width) + 2
    }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: gap) {
                titleText
                if textWidth > geometry.size.width + 4 {
                    titleText.accessibilityHidden(true)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: -offset)
            .frame(width: geometry.size.width, alignment: .leading)
            .clipped()
            .onAppear { start(width: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, value in start(width: value) }
            .onChange(of: title) { _, _ in start(width: geometry.size.width) }
            .onChange(of: dynamicTypeSize) { _, _ in start(width: geometry.size.width) }
            .onDisappear { withAnimation(nil) { offset = 0 } }
        }
        .frame(height: font.lineHeight + 2)
        // Clipping alone does not limit the hit region of the animated text.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
    private var titleText: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
    private func start(width: CGFloat) {
        withAnimation(nil) { offset = 0 }
        guard width > 0, textWidth > width + 4 else { return }
        let distance = textWidth + gap
        withAnimation(.linear(duration: max(4, Double(distance / 28))).repeatForever(autoreverses: false)) {
            offset = distance
        }
    }
}

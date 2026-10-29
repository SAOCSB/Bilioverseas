import SwiftUI
import UIKit
import Photos

/// What `DynamicCardView` presents in its full-screen image viewer.
struct DynamicImageViewerPayload: Identifiable {
    let id = UUID()
    let urls: [String]
    let index: Int
}

/// Full-screen image viewer: horizontal paging, pinch / double-tap zoom, single tap closes,
/// 「保存」 to the photo library.
struct DynamicImageViewer: View {
    let urls: [String]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(urls: [String], startIndex: Int) {
        self.urls = urls
        _index = State(initialValue: min(max(startIndex, 0), max(urls.count - 1, 0)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                    DynamicZoomableImage(url: url, onSingleTap: { dismiss() })
                        .ignoresSafeArea()
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.35), in: Circle())
                }
                Spacer()
                if urls.count > 1 {
                    Text("\(index + 1)/\(urls.count)")
                        .font(.subheadline.monospacedDigit())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.35), in: Capsule())
                }
                Spacer()
                Button {
                    if urls.indices.contains(index) { DynamicImageSaver.save(url: urls[index]) }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.35), in: Circle())
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .statusBarHidden(true)
    }
}

/// Loads the full-size image and adds it to the photo library (add-only permission).
enum DynamicImageSaver {
    @MainActor
    static func save(url: String) {
        Task { @MainActor in
            guard let image = await ImagePipeline.shared.image(for: url.biliHTTPS) else {
                ToastCenter.shared.show("图片加载失败")
                return
            }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    Task { @MainActor in ToastCenter.shared.show("没有相册访问权限") }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }, completionHandler: { ok, _ in
                    Task { @MainActor in ToastCenter.shared.show(ok ? "已保存到相册" : "保存失败") }
                })
            }
        }
    }
}

/// One zoomable page (UIScrollView based: pinch, double tap, pan when zoomed).
struct DynamicZoomableImage: UIViewRepresentable {
    let url: String
    var onSingleTap: () -> Void

    func makeUIView(context: Context) -> DynamicZoomScrollView {
        let view = DynamicZoomScrollView(frame: .zero)
        view.onSingleTap = onSingleTap
        view.load(url)
        return view
    }

    func updateUIView(_ view: DynamicZoomScrollView, context: Context) {
        view.onSingleTap = onSingleTap
        if view.currentURL != url { view.load(url) }
    }

    static func dismantleUIView(_ view: DynamicZoomScrollView, coordinator: ()) {
        view.cancelLoad()
    }
}

final class DynamicZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?
    private(set) var currentURL = ""

    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var loadTask: Task<Void, Never>?
    private var lastBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(_ url: String) {
        currentURL = url
        loadTask?.cancel()
        imageView.image = nil
        zoomScale = 1
        spinner.startAnimating()
        setNeedsLayout()
        let original = url.biliHTTPS
        // A large webp first (fast on overseas links), the original if that fails.
        let preferred = Fmt.thumb(original, width: 2048)
        loadTask = Task { @MainActor [weak self] in
            var image = await ImagePipeline.shared.image(for: preferred)
            if image == nil, preferred != original, !Task.isCancelled {
                image = await ImagePipeline.shared.image(for: original)
            }
            guard let self, !Task.isCancelled, self.currentURL == url else { return }
            self.spinner.stopAnimating()
            self.imageView.image = image
            self.zoomScale = 1
            self.layoutImage(force: true)
        }
    }

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: contentOffset.x + bounds.width / 2, y: contentOffset.y + bounds.height / 2)
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            zoomScale = 1
            layoutImage(force: true)
        } else {
            layoutImage(force: false)
        }
    }

    /// At zoom 1 the image fits the screen (very long images fit the width and scroll vertically).
    private func layoutImage(force: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if zoomScale == 1, force || imageView.frame.size == .zero {
            let fitted = fittedSize()
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            if fitted.height > bounds.height { contentOffset = .zero }
        }
        centerImage()
    }

    private func fittedSize() -> CGSize {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return bounds.size }
        let widthScale = bounds.width / image.size.width
        let heightScale = bounds.height / image.size.height
        let isLong = image.size.height / image.size.width > 3 * (bounds.height / bounds.width) / 2
        let scale = isLong ? widthScale : min(widthScale, heightScale)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func centerImage() {
        let insetX = max((bounds.width - contentSize.width) / 2, 0)
        let insetY = max((bounds.height - contentSize.height) / 2, 0)
        imageView.center = CGPoint(x: contentSize.width / 2 + insetX, y: contentSize.height / 2 + insetY)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale = min(maximumZoomScale, 2.5)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }
}

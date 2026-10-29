import SwiftUI
import UIKit

/// Memory + disk cached image loader for hdslb covers / avatars.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    func cached(_ url: String) -> UIImage? { memory.object(forKey: url as NSString) }

    func image(for url: String) async -> UIImage? {
        guard !url.isEmpty, let u = URL(string: url) else { return nil }
        if let img = cached(url) { return img }
        lock.lock()
        if let t = inflight[url] { lock.unlock(); return await t.value }
        let task = Task<UIImage?, Never> { [session] in
            var req = URLRequest(url: u)
            req.setValue(BiliHTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            guard let (data, _) = try? await session.data(for: req), let img = UIImage(data: data) else { return nil }
            return img.preparingForDisplay() ?? img
        }
        inflight[url] = task
        lock.unlock()
        let img = await task.value
        lock.lock(); inflight[url] = nil; lock.unlock()
        if let img {
            let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
            memory.setObject(img, forKey: url as NSString, cost: cost)
        }
        return img
    }
}

/// Async image with placeholder. `width` (points) requests a resized variant from the CDN.
struct RemoteImage: View {
    let url: String
    var width: CGFloat? = nil
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    private var resolvedURL: String {
        guard let width, AppSettings.shared.general.compactImages else { return url.biliHTTPS }
        let px = Int(width * UIScreen.main.scale)
        return Fmt.thumb(url, width: min(max(px, 80), 1280))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color(.secondarySystemFill))
            }
        }
        .task(id: resolvedURL) {
            let u = resolvedURL
            if let c = ImagePipeline.shared.cached(u) { image = c; return }
            image = nil
            image = await ImagePipeline.shared.image(for: u)
        }
    }
}

/// Circular avatar.
struct AvatarView: View {
    let url: String
    var size: CGFloat = 36

    var body: some View {
        RemoteImage(url: url, width: size)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(.separator), lineWidth: 0.5))
    }
}

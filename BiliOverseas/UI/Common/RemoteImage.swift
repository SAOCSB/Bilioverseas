import SwiftUI
import UIKit

/// Memory + disk cached image loader for hdslb covers / avatars.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let diskCache: URLCache
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        let cfg = URLSessionConfiguration.default
        diskCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        cfg.urlCache = diskCache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    func cached(_ url: String) -> UIImage? { memory.object(forKey: url as NSString) }

    /// Bytes the cover/avatar disk cache currently uses.
    var diskUsage: Int64 { Int64(diskCache.currentDiskUsage) }

    /// Drops every cached image (memory and disk).
    func clearCache() {
        memory.removeAllObjects()
        diskCache.removeAllCachedResponses()
    }

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
        // Cache before dropping the in-flight entry, so a request arriving in between neither misses
        // both nor starts a second download.
        if let img {
            let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
            memory.setObject(img, forKey: url as NSString, cost: cost)
        }
        lock.lock(); inflight[url] = nil; lock.unlock()
        return img
    }
}

/// Async image with placeholder. `width` (points) requests a resized variant from the CDN.
struct RemoteImage: View {
    let url: String
    var width: CGFloat? = nil
    var contentMode: ContentMode = .fill

    /// The image together with the URL it was loaded for.
    private struct Loaded {
        let url: String
        let image: UIImage
    }

    @State private var loaded: Loaded?

    private var resolvedURL: String {
        guard let width, AppSettings.shared.general.compactImages else { return url.biliHTTPS }
        let px = Int(width * UIScreen.main.scale)
        return Fmt.thumb(url, width: min(max(px, 80), 1280))
    }

    var body: some View {
        let u = resolvedURL
        // A memory-cached image shows in the very first frame (no placeholder flash when a row is
        // rebuilt), and an image already loaded for this URL stays even if the cache evicted it.
        let shown = loaded?.url == u ? loaded?.image : ImagePipeline.shared.cached(u)
        ZStack {
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color(.secondarySystemFill))
            }
        }
        .task(id: u) {
            if loaded?.url == u { return }
            if let c = ImagePipeline.shared.cached(u) {
                loaded = Loaded(url: u, image: c)
                return
            }
            guard let img = await ImagePipeline.shared.image(for: u), !Task.isCancelled else { return }
            loaded = Loaded(url: u, image: img)
        }
        // Lazy stacks keep off-screen rows alive; without this every row ever shown would pin its
        // decoded bitmap. Coming back on screen it renders from the memory cache in the first frame.
        .onDisappear { loaded = nil }
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

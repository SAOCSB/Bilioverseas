import Foundation

/// What starting a video did, in a small file that can be read off the phone: the Simulator says little about a phone on
/// its own network. Hosts and error codes at most, never URLs, which carry signatures.
enum PlaybackTrace {
    private static let queue = DispatchQueue(label: "playback-trace", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// About 3000 lines, half of them when it was last cut.
    private static let maxBytes = 400_000

    static func log(_ line: String) {
        let now = Date()
        queue.async {
            guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let url = dir.appendingPathComponent("playback-trace.txt")
            let new = Data("\(formatter.string(from: now)) \(line)\n".utf8)
            if let file = try? FileHandle(forWritingTo: url) {
                defer { try? file.close() }
                if let size = try? file.seekToEnd(), size < maxBytes {
                    try? file.write(contentsOf: new)
                    return
                }
            }
            var kept = ((try? Data(contentsOf: url)) ?? Data()).suffix(maxBytes / 2)
            if let lineEnd = kept.firstIndex(of: 10) { kept = kept[(lineEnd + 1)...] }
            try? (kept + new).write(to: url, options: .atomic)
        }
    }

    /// An error as its domain and code, and those of the error under it.
    static func describe(_ error: Error?) -> String {
        guard let error else { return "no error" }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError { text += " < \(under.domain) \(under.code)" }
        return text
    }

    /// The stream a video plays, and the host it comes from.
    static func describe(_ choice: PlayerStreamChoice?) -> String {
        guard let choice else { return "no choice" }
        let host = URL(string: choice.video.baseURL)?.host ?? "?"
        return "qn=\(choice.video.id) \(choice.video.codecFamily) \(choice.video.width)x\(choice.video.height) "
            + "kbps=\(choice.video.bandwidth / 1000) audio=\(choice.audio?.id ?? 0) host=\(host)"
    }
}

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

    static func log(_ line: String) {
        let now = Date()
        queue.async {
            guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let url = dir.appendingPathComponent("playback-trace.txt")
            var kept = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if kept.count > 60_000 { kept = String(kept.suffix(30_000)) }
            try? (kept + "\(formatter.string(from: now)) \(line)\n").write(to: url, atomically: true, encoding: .utf8)
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
        return "qn=\(choice.video.id) \(choice.video.codecFamily) \(choice.video.width)x\(choice.video.height) host=\(host)"
    }
}

import Foundation
import Compression

/// One chat line from the live danmaku socket.
struct LiveDanmakuMessage: Identifiable, Hashable {
    enum Kind: Hashable {
        case danmaku
        /// 醒目留言 (Super Chat).
        case superChat
    }

    /// Sequential per socket (assigned on delivery).
    var id: Int = 0
    var kind: Kind = .danmaku
    var uid: Int64 = 0
    var name: String = ""
    var text: String = ""
    /// 0xRRGGBB.
    var color: UInt32 = 0xFFFFFF
    /// Super Chat price (CNY).
    var price: Int = 0
}

/// What the socket reports to its owner (always on the main actor).
enum LiveDanmakuEvent {
    case connecting
    case connected
    /// `reason` nil = transient (reconnecting); non-nil = gave up.
    case disconnected(reason: String?)
    case message(LiveDanmakuMessage)
    /// `WATCHED_CHANGE` text, e.g. "1.2万人看过".
    case watched(String)
    /// `LIVE`: the anchor started streaming.
    case liveStarted
    /// `PREPARING`: the stream ended.
    case liveEnded
    /// `ROOM_CHANGE`: new room title.
    case titleChanged(String)
}

/// Decoded frames / commands (built off the main actor).
enum LiveDanmakuFrame {
    case authReply(ok: Bool)
    case heartbeatReply
    case event(LiveDanmakuEvent)
}

/// Bilibili live broadcast packet format (api-lists.md §10.6): 16-byte big-endian header
/// `u32 total length | u16 header length (16) | u16 protover | u32 op | u32 seq`, then the body.
/// protover 0/1 = raw JSON, 2 = zlib (holds more packets back to back), 3 = brotli (not requested).
enum LiveDanmakuPacket {
    static let headerLength = 16

    enum Op {
        static let heartbeat: UInt32 = 2
        static let heartbeatReply: UInt32 = 3
        static let message: UInt32 = 5
        static let auth: UInt32 = 7
        static let authReply: UInt32 = 8
    }

    static func encode(op: UInt32, body: Data, seq: UInt32 = 1, protover: UInt16 = 1) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerLength + body.count)
        bytes.append(contentsOf: be32(UInt32(headerLength + body.count)))
        bytes.append(contentsOf: be16(UInt16(headerLength)))
        bytes.append(contentsOf: be16(protover))
        bytes.append(contentsOf: be32(op))
        bytes.append(contentsOf: be32(seq))
        bytes.append(contentsOf: body)
        return Data(bytes)
    }

    /// op 7: `{"uid","roomid","protover":2,"platform":"web","type":2,"key"}` (+ `buvid` when known).
    static func authPacket(roomId: Int64, uid: Int64, token: String, buvid: String?) -> Data {
        var obj: [String: Any] = [
            "uid": uid, "roomid": roomId, "protover": 2, "platform": "web", "type": 2, "key": token,
        ]
        if let buvid, !buvid.isEmpty { obj["buvid"] = buvid }
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return encode(op: Op.auth, body: body, seq: 1)
    }

    static func heartbeatPacket(seq: UInt32) -> Data {
        encode(op: Op.heartbeat, body: Data(), seq: seq)
    }

    /// Splits a WebSocket message into packets (inflating zlib bodies) and decodes them.
    static func frames(from data: Data) -> [LiveDanmakuFrame] {
        var out: [LiveDanmakuFrame] = []
        split([UInt8](data), depth: 0, into: &out)
        return out
    }

    private static func split(_ bytes: [UInt8], depth: Int, into out: inout [LiveDanmakuFrame]) {
        var offset = 0
        while offset + headerLength <= bytes.count {
            let total = Int(readU32(bytes, offset))
            let headerLen = Int(readU16(bytes, offset + 4))
            let ver = readU16(bytes, offset + 6)
            let op = readU32(bytes, offset + 8)
            guard headerLen >= headerLength, total >= headerLen, offset + total <= bytes.count else { break }
            let body = Array(bytes[(offset + headerLen)..<(offset + total)])
            switch op {
            case Op.authReply:
                var ok = true
                if let json = try? JSON(data: Data(body)), let code = json["code"].int { ok = code == 0 }
                out.append(.authReply(ok: ok))
            case Op.heartbeatReply:
                out.append(.heartbeatReply)
            case Op.message:
                if ver == 2 {
                    if depth < 3, let inflated = inflateZlib(body) { split(inflated, depth: depth + 1, into: &out) }
                } else if ver == 0 || ver == 1 {
                    if let e = parseCommand(Data(body)) { out.append(.event(e)) }
                }
                // ver 3 (brotli) is never sent because the auth packet asks for protover 2.
            default:
                break
            }
            offset += total
        }
    }

    /// One `cmd` JSON body.
    static func parseCommand(_ body: Data) -> LiveDanmakuEvent? {
        guard let json = try? JSON(data: body) else { return nil }
        let cmd = json["cmd"].stringValue
        if cmd.hasPrefix("DANMU_MSG") {
            let info = json["info"]
            let text = info[1].stringValue
            guard !text.isEmpty else { return nil }
            let user = info[0][15]["user"]
            var name = info[2][1].stringValue
            if name.isEmpty { name = user["base"]["name"].stringValue }
            var uid = info[2][0].int64Value
            if uid == 0 { uid = user["uid"].int64Value }
            let rawColor = info[0][3].int64Value
            let color = rawColor > 0 ? UInt32(truncatingIfNeeded: rawColor) & 0xFFFFFF : 0xFFFFFF
            return .message(LiveDanmakuMessage(kind: .danmaku, uid: uid, name: name, text: text, color: color))
        }
        let data = json["data"]
        switch cmd {
        case "SUPER_CHAT_MESSAGE":
            let text = data["message"].stringValue
            guard !text.isEmpty else { return nil }
            return .message(LiveDanmakuMessage(kind: .superChat, uid: data["uid"].int64Value,
                                               name: data["user_info"]["uname"].stringValue, text: text,
                                               color: 0xFFFFFF, price: data["price"].intValue))
        case "WATCHED_CHANGE":
            let t = data["text_large"].stringValue
            return t.isEmpty ? nil : .watched(t)
        case "LIVE":
            return .liveStarted
        case "PREPARING":
            return .liveEnded
        case "ROOM_CHANGE":
            let t = data["title"].stringValue
            return t.isEmpty ? nil : .titleChanged(t)
        default:
            return nil
        }
    }

    /// zlib (RFC 1950) → bytes. Apple's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951), so the 2-byte
    /// zlib header and the 4-byte Adler-32 trailer are stripped first.
    static func inflateZlib(_ input: [UInt8]) -> [UInt8]? {
        var src = input
        if src.count > 6, (src[0] & 0x0F) == 8, ((UInt16(src[0]) << 8) | UInt16(src[1])) % 31 == 0 {
            // FDICT (preset dictionary) is never used by Bilibili; such a stream cannot be inflated.
            if (src[1] & 0x20) != 0 { return nil }
            src = Array(src[2..<(src.count - 4)])
        }
        guard !src.isEmpty else { return nil }
        var capacity = max(src.count * 8, 64 * 1024)
        while capacity <= 64 * 1024 * 1024 {
            var dst = [UInt8](repeating: 0, count: capacity)
            let cap = capacity
            let written: Int = dst.withUnsafeMutableBufferPointer { d in
                src.withUnsafeBufferPointer { s in
                    guard let dBase = d.baseAddress, let sBase = s.baseAddress else { return 0 }
                    return compression_decode_buffer(dBase, cap, sBase, s.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written == 0 { return nil }
            // A completely full buffer may mean truncated output: retry with more room.
            if written < cap { return Array(dst[0..<written]) }
            capacity *= 4
        }
        return nil
    }

    // MARK: Byte helpers

    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func be16(_ v: UInt16) -> [UInt8] {
        [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    static func readU16(_ b: [UInt8], _ o: Int) -> UInt16 {
        (UInt16(b[o]) << 8) | UInt16(b[o + 1])
    }
}

/// Live danmaku WebSocket (`wss://<host>:<wss_port>/sub`): auth, 30 s heartbeat, host rotation and
/// exponential-backoff reconnects. Events are delivered on the main actor through `onEvent`.
/// No cookies are sent (ephemeral session); the uid / token / buvid go in the auth body.
@MainActor
final class LiveDanmakuSocket {
    var onEvent: ((LiveDanmakuEvent) -> Void)?

    private let roomId: Int64
    private let uid: Int64
    private let info: LiveDanmuInfo
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var generation = 0
    private var hostIndex = 0
    private var failures = 0
    private var nextMessageId = 0
    private(set) var isRunning = false

    private static let maxFailures = 6

    init(roomId: Int64, uid: Int64, info: LiveDanmuInfo) {
        self.roomId = roomId
        self.uid = uid
        self.info = info
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        failures = 0
        connect()
    }

    func stop() {
        isRunning = false
        generation += 1
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Manual 重连 after the socket gave up.
    func restart() {
        stop()
        start()
    }

    private func connect() {
        guard isRunning else { return }
        generation += 1
        let gen = generation
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)

        let hosts = info.hosts
        guard !hosts.isEmpty, let url = URL(string: hosts[hostIndex % hosts.count].wssURL) else {
            onEvent?(.disconnected(reason: "弹幕服务器不可用"))
            isRunning = false
            return
        }
        var request = URLRequest(url: url)
        request.setValue(BiliHTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = 16 * 1024 * 1024
        task = ws
        onEvent?(.connecting)
        ws.resume()

        let auth = LiveDanmakuPacket.authPacket(roomId: roomId, uid: uid, token: info.token,
                                                buvid: BiliHTTP.shared.cookie(named: "buvid3"))
        receiveTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await ws.send(.data(auth))
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    let data: Data
                    switch message {
                    case .data(let d): data = d
                    case .string(let s): data = Data(s.utf8)
                    @unknown default: continue
                    }
                    let frames = LiveDanmakuPacket.frames(from: data)
                    if frames.isEmpty { continue }
                    guard let self else { return }
                    await self.deliver(frames, generation: gen)
                }
            } catch {
                guard let self else { return }
                await self.connectionLost(generation: gen)
            }
        }
    }

    private func deliver(_ frames: [LiveDanmakuFrame], generation gen: Int) {
        guard gen == generation, isRunning else { return }
        for frame in frames {
            switch frame {
            case .authReply(let ok):
                if ok {
                    failures = 0
                    onEvent?(.connected)
                    startHeartbeat(generation: gen)
                } else {
                    // A token bound to another account / expired: rotate hosts and retry (backoff).
                    connectionLost(generation: gen)
                    return
                }
            case .heartbeatReply:
                break
            case .event(let event):
                if case .message(var m) = event {
                    nextMessageId += 1
                    m.id = nextMessageId
                    onEvent?(.message(m))
                } else {
                    onEvent?(event)
                }
            }
        }
    }

    private func startHeartbeat(generation gen: Int) {
        heartbeatTask?.cancel()
        guard let ws = task else { return }
        heartbeatTask = Task { [weak self] in
            var seq: UInt32 = 2
            while !Task.isCancelled {
                guard self?.isCurrent(gen) == true else { return }
                try? await ws.send(.data(LiveDanmakuPacket.heartbeatPacket(seq: seq)))
                seq &+= 1
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        isRunning && gen == generation
    }

    private func connectionLost(generation gen: Int) {
        guard isCurrent(gen) else { return }
        generation += 1
        let next = generation
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failures += 1
        hostIndex += 1
        if failures > LiveDanmakuSocket.maxFailures {
            isRunning = false
            onEvent?(.disconnected(reason: "弹幕连接失败"))
            return
        }
        onEvent?(.disconnected(reason: nil))
        let delay = min(30.0, pow(2.0, Double(failures - 1)))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.isCurrent(next) else { return }
            self.connect()
        }
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fallback upstream client on URLSession (proxy-ports spec §6.3 (b)): K separate ephemeral sessions ("lanes",
/// round-robin per request), each with its own connection pool, so HTTP/2 multiplexing at worst collapses one
/// lane's requests onto one connection instead of all of them. Prefer `H1MediaClient`, which guarantees one TCP
/// connection per request.
///
/// Same stream contract as `H1MediaClient` (head first, ordered data, demand-driven back-pressure by suspending
/// the data task, cancellation cancels the task). Redirects are not followed (the 3xx head is returned, like the
/// HTTP/1.1 client). No cookies, no cache, `Accept-Encoding: identity`.
///
/// `openConnectionCount` reports in-flight tasks (URLSession doesn't expose its sockets); `preconnect` is a no-op.
final class URLSessionMediaClient: MediaHTTPClient {
    let userAgent: String
    private let lanes: [URLSessionMediaLane]
    private let lock = NSLock()
    private var nextLane = 0

    init(lanes: Int = 8, userAgent: String = BiliHTTP.webUserAgent) {
        self.userAgent = userAgent
        self.lanes = (0 ..< max(1, lanes)).map { URLSessionMediaLane(index: $0) }
    }

    deinit {
        for lane in lanes { lane.session.invalidateAndCancel() }
    }

    var openConnectionCount: Int { lanes.reduce(0) { $0 + $1.inFlightCount } }

    /// Negotiated protocol names seen so far ("http/1.1", "h2", …) with counts — to measure the h1/h2 split.
    var negotiatedProtocols: [String: Int] {
        lanes.reduce(into: [:]) { acc, lane in
            for (k, v) in lane.protocolCounts { acc[k, default: 0] += v }
        }
    }

    func get(_ url: URL, range: ByteRange, highPriority: Bool) -> AsyncThrowingStream<MediaFetchEvent, Error> {
        let pipe = MediaEventPipe()
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty, range.start >= 0, range.end >= range.start else {
            pipe.finish(throwing: MediaFetchError.invalidURL)
            return pipe.makeStream()
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for field in H1RequestSerializer.mediaHeaderFields(range: range, userAgent: userAgent) {
            request.setValue(field.value, forHTTPHeaderField: field.name)
        }
        #if canImport(Darwin)
        request.networkServiceType = highPriority ? .responsiveData : .default
        #endif
        lock.lock()
        let lane = lanes[nextLane % lanes.count]
        nextLane &+= 1
        lock.unlock()
        lane.start(request, highPriority: highPriority, pipe: pipe)
        return pipe.makeStream()
    }

    func preconnect(hosts: [String]) {}

    func closeIdleConnections() {
        #if canImport(Darwin)
        // "Ensures that future requests occur on a new TCP connection" — drops the lanes' idle sockets.
        for lane in lanes { lane.session.flush {} }
        #endif
    }
}

/// One URLSession plus its delegate. The session retains the lane until `invalidateAndCancel()`.
final class URLSessionMediaLane: NSObject, URLSessionDataDelegate {
    final class TaskState {
        let task: URLSessionDataTask
        let pipe: MediaEventPipe
        let lock = NSLock()
        var suspended = false
        var gotResponse = false
        var received: Int64 = 0
        var expected: Int64 = -1
        init(task: URLSessionDataTask, pipe: MediaEventPipe) {
            self.task = task
            self.pipe = pipe
        }

        /// Consumer drained the buffer: resume a task we suspended for back-pressure.
        func resumeIfSuspended() {
            lock.lock()
            defer { lock.unlock() }
            guard suspended else { return }
            suspended = false
            task.resume()
        }
    }

    let index: Int
    private(set) var session: URLSession!
    private let lock = NSLock()
    private var tasks: [Int: TaskState] = [:]
    private var protocols: [String: Int] = [:]

    init(index: Int) {
        self.index = index
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 64
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        cfg.timeoutIntervalForRequest = 30 // idle backstop; BTR's own timers are shorter
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "bili.urlsession-media-lane-\(index)"
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
    }

    var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    var protocolCounts: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return protocols
    }

    func start(_ request: URLRequest, highPriority: Bool, pipe: MediaEventPipe) {
        let task = session.dataTask(with: request)
        task.priority = highPriority ? URLSessionTask.highPriority : URLSessionTask.defaultPriority
        let state = TaskState(task: task, pipe: pipe)
        lock.lock()
        tasks[task.taskIdentifier] = state
        lock.unlock()
        pipe.setHandlers(
            onDemand: { [weak state] in state?.resumeIfSuspended() },
            onCancel: { [weak task] in task?.cancel() }
        )
        task.resume()
    }

    private func state(for task: URLSessionTask) -> TaskState? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[task.taskIdentifier]
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = state(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            state.pipe.finish(throwing: MediaFetchError.malformedResponse("not an HTTP response"))
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            let name = String(describing: key).lowercased()
            let v = String(describing: value)
            if let existing = headers[name] { headers[name] = existing + ", " + v } else { headers[name] = v }
        }
        state.lock.lock()
        state.gotResponse = true
        state.expected = http.expectedContentLength
        state.lock.unlock()
        state.pipe.push(.head(status: http.statusCode, headers: headers))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask) else { return }
        // Hold the state lock across push + suspend so a concurrent onDemand can't slip in between and be lost.
        state.lock.lock()
        state.received += Int64(data.count)
        if !state.pipe.push(.data(data)), !state.suspended, !state.pipe.isCancelled {
            state.suspended = true
            dataTask.suspend()
        }
        state.lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // deliver the 3xx itself; signed CDN URLs must not wander to other hosts
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = tasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }
        state.lock.lock()
        let gotResponse = state.gotResponse
        let short = state.expected >= 0 && state.received < state.expected
        state.lock.unlock()
        if let error {
            state.pipe.finish(throwing: Self.map(error, gotResponse: gotResponse))
        } else if short {
            state.pipe.finish(throwing: MediaFetchError.connectionClosed)
        } else {
            state.pipe.finish()
        }
    }

    #if canImport(Darwin)
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let name = metrics.transactionMetrics.last?.networkProtocolName else { return }
        lock.lock()
        protocols[name, default: 0] += 1
        lock.unlock()
    }
    #endif

    static func map(_ error: Error, gotResponse: Bool) -> MediaFetchError {
        if let e = error as? MediaFetchError { return e }
        let ns = error as NSError
        let detail = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        guard let urlError = error as? URLError else {
            return gotResponse ? .connectionClosed : .connectFailed(detail)
        }
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .badURL, .unsupportedURL:
            return .invalidURL
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return .tls(detail)
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData:
            return .malformedResponse(detail)
        default:
            return gotResponse ? .connectionClosed : .connectFailed(detail)
        }
    }
}

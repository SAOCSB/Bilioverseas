import Foundation

// Port of Bilibili-thread-ripper `assignPrimaries` (idm-downloader.js, MIT) — smooth weighted round-robin of a
// range's pieces over its nodes by measured speed, with trials for unmeasured nodes (BTR spec §7.5) — and of the
// desktop client's `inTurns` single-piece rotation (transport.js).

/// Which node each piece of a range tries first. One per downloader; thread-safe.
final class BTRAssigner: @unchecked Sendable {
    private final class TrialState {
        weak var owner: AnyObject?
        var waited = 0
        var cursor = 0
        var inTurns = 0
        init(owner: AnyObject) { self.owner = owner }
    }

    private let lock = NSLock()
    private var turn = 0
    // Trials are counted per resolver: video and audio take turns on one downloader, and a shared count could
    // leave a track without a trial for good.
    private var states: [ObjectIdentifier: TrialState] = [:]

    private func stateLocked(_ source: AnyObject) -> TrialState {
        let id = ObjectIdentifier(source)
        if let s = states[id], s.owner === source { return s }
        if states.count > 256 { states = states.filter { $0.value.owner != nil } }
        let s = TrialState(owner: source)
        states[id] = s
        return s
    }

    /// `count` primaries for `urls`: nodes slower than 1/12 of the best get none; unmeasured nodes get "trial"
    /// pieces at the end (≤ min(2 × unknown, count / 4), or one every 4th small range); the measured ones share the
    /// rest in turns, weighted by speed (floor 5 % of the best). Each range opens one node further on.
    func assignPrimaries(_ input: [String], source: BTRAssignmentSource, count inputCount: Int) -> [String] {
        guard !input.isEmpty, inputCount > 0 else { return [] }
        if input.count == 1 { return Array(repeating: input[0], count: inputCount) }
        lock.lock()
        defer { lock.unlock() }
        let turn = self.turn
        self.turn = (self.turn + 1) % 4096
        var urls = input
        var count = inputCount
        let measure = { (url: String) -> Double in max(0, source.speed(url)) }
        var known = urls.map(measure)
        if !known.contains(where: { $0 > 0 }) {
            return (0..<count).map { urls[($0 + turn) % urls.count] }
        }
        let top = known.max() ?? 0
        let eligibleIdx = known.indices.filter { known[$0] == 0 || known[$0] >= top / 12 }
        if !eligibleIdx.isEmpty && eligibleIdx.count < urls.count {
            urls = eligibleIdx.map { urls[$0] }
            known = eligibleIdx.map { known[$0] }
        }
        let unknown = urls.indices.filter { known[$0] == 0 }.map { urls[$0] }
        var trials = min(unknown.count * 2, count / 4)
        let state = stateLocked(source)
        // Small segments never have a piece to spare; every fourth one gives its last piece to a trial.
        if trials == 0 && !unknown.isEmpty && count >= 2 {
            state.waited += 1
            if state.waited >= 4 { trials = 1 }
        }
        if trials > 0 { state.waited = 0 }
        if !unknown.isEmpty {
            let measuredIdx = urls.indices.filter { known[$0] > 0 }
            urls = measuredIdx.map { urls[$0] }
            known = measuredIdx.map { known[$0] }
            count -= trials
        }
        let weights = known.map { max($0, top * 0.05) }
        let total = weights.reduce(0, +)
        var primaries: [String] = []
        primaries.reserveCapacity(inputCount)
        var credit = [Double](repeating: 0, count: urls.count)
        let order = urls.indices.map { ($0 + turn) % urls.count }
        for _ in 0..<max(0, count) {
            var best = order[0]
            for u in order {
                credit[u] += weights[u]
                if credit[u] > credit[best] { best = u }
            }
            credit[best] -= total
            primaries.append(urls[best])
        }
        for i in 0..<trials { primaries.append(unknown[(i + state.cursor) % unknown.count]) }
        state.cursor = (state.cursor + trials) % 4096
        return primaries
    }

    /// Desktop `inTurns`: a single-piece range's first node is picked in turns from the range candidates (nodes
    /// under 1/12 of the best left out), so a run of small audio requests does not all queue on the fastest node.
    func inTurnsCandidates(_ source: BTRAssignmentSource) -> [String] {
        let all = source.rangeCandidates()
        let speeds = all.map { source.speed($0) }
        let best = max(0, speeds.max() ?? 0)
        let usable = all.indices.filter { speeds[$0] == 0 || speeds[$0] >= best / 12 }.map { all[$0] }
        let list = usable.isEmpty ? all : usable
        guard !list.isEmpty else { return list }
        lock.lock()
        let state = stateLocked(source)
        let pick = list[state.inTurns % list.count]
        state.inTurns = (state.inTurns + 1) % 1_000_000
        lock.unlock()
        return [pick]
    }

    /// The piece's preferred list: its primary first, then the rest of the range's URLs.
    static func preferredFor(_ primary: String?, _ urls: [String]) -> [String] {
        guard let primary else { return urls }
        return [primary] + urls.filter { $0 != primary }
    }
}

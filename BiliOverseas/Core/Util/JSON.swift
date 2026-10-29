import Foundation

/// Lenient JSON value used for all Bilibili API parsing.
///
/// Bilibili responses are inconsistent (the same field can be an Int, a numeric String,
/// "--", or missing depending on the endpoint), so models are built from `JSON` with
/// forgiving accessors instead of strict `Codable`. Integers keep full 64-bit precision.
enum JSON: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    static let empty = JSON.null

    init(data: Data) throws {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = JSON(any: obj)
    }

    init(string: String) throws {
        try self.init(data: Data(string.utf8))
    }

    init(any value: Any?) {
        guard let value else { self = .null; return }
        switch value {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            self = JSON.from(number: n)
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map { JSON(any: $0) })
        case let d as [String: Any]:
            var out: [String: JSON] = [:]
            out.reserveCapacity(d.count)
            for (k, v) in d { out[k] = JSON(any: v) }
            self = .object(out)
        case let b as Bool:
            self = .bool(b)
        case let i as Int:
            self = .int(Int64(i))
        case let i as Int64:
            self = .int(i)
        case let d as Double:
            self = .double(d)
        case let j as JSON:
            self = j
        default:
            self = .null
        }
    }

    private static func from(number n: NSNumber) -> JSON {
        #if canImport(Darwin)
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
        if CFNumberIsFloatType(n) {
            let d = n.doubleValue
            if d.rounded() == d, abs(d) < 9.0e15 { return .int(Int64(d)) }
            return .double(d)
        }
        return .int(n.int64Value)
        #else
        let type = String(cString: n.objCType)
        if type == "c" || type == "B" { return .bool(n.boolValue) }
        if type == "d" || type == "f" { return .double(n.doubleValue) }
        return .int(n.int64Value)
        #endif
    }

    // MARK: - Subscripts

    subscript(key: String) -> JSON {
        if case .object(let d) = self { return d[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSON {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    /// Follows a dotted path, e.g. `json[path: "data.dash.video"]`. Numeric components index arrays.
    subscript(path path: String) -> JSON {
        var cur = self
        for comp in path.split(separator: ".") {
            let key = String(comp)
            if case .array = cur, let i = Int(key) { cur = cur[i] } else { cur = cur[key] }
        }
        return cur
    }

    // MARK: - Lenient accessors

    var exists: Bool { if case .null = self { return false }; return true }
    var isNull: Bool { !exists }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return d.rounded() == d && abs(d) < 9.0e18 ? String(Int64(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var stringValue: String { string ?? "" }

    var int64: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return JSON.safeInt64(d)
        case .bool(let b): return b ? 1 : 0
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int64(t) { return i }
            if let d = Double(t) { return JSON.safeInt64(d) }
            return JSON.parseChineseCount(t)
        default: return nil
        }
    }
    var int64Value: Int64 { int64 ?? 0 }
    var int: Int? { int64.map { Int(truncatingIfNeeded: $0) } }
    var intValue: Int { int ?? 0 }

    var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
    var doubleValue: Double { double ?? 0 }

    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no", "": return false
            default: return nil
            }
        default: return nil
        }
    }
    var boolValue: Bool { bool ?? false }

    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var arrayValue: [JSON] { array ?? [] }

    var object: [String: JSON]? { if case .object(let d) = self { return d }; return nil }
    var objectValue: [String: JSON] { object ?? [:] }

    /// Converts back to Foundation objects (for re-serialisation / debugging).
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let d): return d.mapValues { $0.anyValue }
        }
    }

    func rawData() -> Data? {
        let any = anyValue
        guard JSONSerialization.isValidJSONObject(any) else { return nil }
        return try? JSONSerialization.data(withJSONObject: any)
    }

    /// `Int64(d)` traps for NaN, ±inf and |d| ≥ 2^63; server values can be anything.
    static func safeInt64(_ d: Double) -> Int64? {
        guard d.isFinite, abs(d) < 9.0e18 else { return nil }
        return Int64(d)
    }

    /// Parses counts such as "1.2万", "3亿", "12,345".
    static func parseChineseCount(_ s: String) -> Int64? {
        var t = s.replacingOccurrences(of: ",", with: "")
        var mul: Double = 1
        if t.hasSuffix("万") { mul = 1e4; t.removeLast() } else if t.hasSuffix("亿") { mul = 1e8; t.removeLast() }
        guard mul != 1, let d = Double(t) else { return nil }
        return safeInt64(d * mul)
    }
}

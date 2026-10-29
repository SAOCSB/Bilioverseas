import SwiftUI
import UIKit

// Small building blocks shared by the settings screens (SettingsView, AccelerationSettingsView,
// PlayerSettingsView, AboutView). Names are prefixed with `Settings` to stay unique in the target.

/// Row label like the official settings list: white SF Symbol on a coloured rounded square, the
/// title, an optional subtitle under it and an optional trailing value.
struct SettingsIconLabel: View {
    let title: String
    let systemImage: String
    let tint: Color
    let subtitle: String?
    let detail: String?

    init(_ title: String, systemImage: String, tint: Color = .biliPink, subtitle: String? = nil, detail: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.subtitle = subtitle
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One option of a single-choice list (radio row): title, optional explanation, checkmark when selected.
struct SettingsChoiceRow: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.biliPink)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Toggle whose label has a secondary explanation line.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Menu picker over preset values. A stored value that is not one of the presets (older builds,
/// hand-edited defaults) is listed too, so the picker never shows an empty selection.
struct SettingsValuePicker<Value: Hashable & Comparable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        Picker(selection: $selection) {
            ForEach(displayedOptions, id: \.self) { value in
                Text(verbatim: label(value)).tag(value)
            }
        } label: {
            Text(verbatim: title)
        }
        .pickerStyle(.menu)
    }

    private var displayedOptions: [Value] {
        options.contains(selection) ? options : (options + [selection]).sorted()
    }
}

/// Inline warning / hint line inside a settings section.
struct SettingsNoticeRow: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        Label {
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}

enum SettingsFormat {
    /// 1 → "1.0x", 0.75 → "0.75x", 1.5 → "1.5x".
    static func speed(_ value: Double) -> String {
        var s = String(format: "%.2f", value)
        if s.hasSuffix("0") { s.removeLast() }
        return s + "x"
    }

    /// 10 → "10 秒", 90 → "90 秒".
    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) 秒" : String(format: "%.1f 秒", value)
    }
}

/// Image caches the 「存储」 section measures and clears: `URLCache.shared` plus the private
/// URLCache / memory cache of `ImagePipeline` (covers, avatars).
enum SettingsImageCache {
    /// `ImagePipeline` keeps its session and memory cache private, so they are read reflectively.
    /// Both are `let` properties (read-only, race-free) and `descendant` stops at the requested
    /// label, so `inflight` is never touched. If the properties are renamed this degrades to
    /// clearing `URLCache.shared` only. TODO: replace with an `ImagePipeline` clear API.
    private static var pipelineSession: URLSession? {
        Mirror(reflecting: ImagePipeline.shared).descendant("session") as? URLSession
    }

    private static var pipelineMemory: NSCache<NSString, UIImage>? {
        Mirror(reflecting: ImagePipeline.shared).descendant("memory") as? NSCache<NSString, UIImage>
    }

    static func urlCaches() -> [URLCache] {
        var caches: [URLCache] = [URLCache.shared]
        if let cache = pipelineSession?.configuration.urlCache, !caches.contains(where: { $0 === cache }) {
            caches.append(cache)
        }
        return caches
    }

    /// Bytes on disk used by the caches.
    static func diskUsage() -> Int64 {
        urlCaches().reduce(Int64(0)) { $0 + Int64($1.currentDiskUsage) }
    }

    static func clear() {
        for cache in urlCaches() {
            cache.removeAllCachedResponses()
        }
        pipelineMemory?.removeAllObjects()
    }
}

import SwiftUI
import SafariServices

/// Global lightweight toast ("已投币", "已跳过广告" …). `ToastWindowHost` (App/ToastWindow.swift) shows it above
/// everything the app presents (sheets, full-screen covers, the fullscreen player), so calling `show` from anywhere
/// is enough.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var actionTitle: String?
        var action: (() -> Void)?
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    @Published var current: Toast? {
        didSet { windowLayer?(current != nil) }
    }
    /// True once a window layer is attached; the in-view `ToastOverlay` copies then draw nothing.
    @Published private(set) var isHostedInWindow = false
    private var windowLayer: ((_ visible: Bool) -> Void)?
    private var hideTask: Task<Void, Never>?

    /// `ToastWindowHost`: told whenever a toast appears or goes away, so it can show / hide its window.
    func attachWindowLayer(_ visibilityChanged: @escaping (_ visible: Bool) -> Void) {
        windowLayer = visibilityChanged
        isHostedInWindow = true
    }

    func show(_ text: String, duration: TimeInterval = 2.0, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        current = Toast(text: text, actionTitle: actionTitle, action: action)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled { self?.current = nil }
        }
    }

    func show(error: Error) {
        show(error.localizedDescription)
    }
}

/// The toast capsule, 90 pt above the bottom safe area. `ToastWindowHost` hosts it in its pass-through window;
/// an in-view copy (`.overlay { ToastOverlay() }`) is only a fallback for the moment before that window exists.
struct ToastOverlay: View {
    @ObservedObject var center = ToastCenter.shared
    /// Set by the toast window: receives the frame (window coordinates) of a toast that has an action button, the
    /// only place the window takes touches; nil when there is none.
    var onInteractiveFrame: ((CGRect?) -> Void)? = nil

    var body: some View {
        if onInteractiveFrame == nil && center.isHostedInWindow {
            EmptyView()
        } else {
            layer
        }
    }

    private var layer: some View {
        VStack {
            Spacer()
            if let toast = center.current {
                HStack(spacing: 12) {
                    Text(toast.text).font(.subheadline).foregroundStyle(.white)
                    if let title = toast.actionTitle, let action = toast.action {
                        Button(title) { action(); center.current = nil }
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.black.opacity(0.78), in: Capsule())
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ToastInteractiveFrameKey.self,
                                           value: toast.action == nil ? nil : proxy.frame(in: .global))
                })
                .padding(.bottom, 90)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.current)
        .allowsHitTesting(center.current?.action != nil)
        .onPreferenceChange(ToastInteractiveFrameKey.self) { frame in onInteractiveFrame?(frame) }
    }
}

private struct ToastInteractiveFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// `.refreshable` whose work outlives the gesture. SwiftUI cancels the refresh action's task when the
    /// view redraws during the refresh, which the refresh itself causes (it publishes `isLoading`); the
    /// lists drop a cancelled request without a word, so a pull did nothing. The work runs in a task of
    /// its own, and the spinner still waits for it.
    func pullToRefresh(_ action: @escaping @MainActor () async -> Void) -> some View {
        refreshable { await Task { @MainActor in await action() }.value }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}

    /// `SFSafariViewController` raises (crashes the app) for anything but http / https.
    static func canOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// Destination of a `.web` route Safari cannot show (`bilibili://…`, relative links …): offers to
/// hand the link to the system instead.
struct ExternalLinkView: View {
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "link").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("此链接无法在应用内打开").font(.subheadline).foregroundStyle(.secondary)
            Text(verbatim: url.absoluteString)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("用其他应用打开") { openURL(url) }
                .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Centered error / empty placeholder with retry.
struct StateMessageView: View {
    let systemImage: String
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let retry { Button("重试", action: retry).buttonStyle(.bordered) }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Prompt shown on pages that need an account.
struct LoginRequiredView: View {
    var message: String = "登录后查看"
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(message).foregroundStyle(.secondary)
            NavigationLink(value: Route.login) {
                Text("扫码登录").frame(width: 140)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Color {
    /// Bilibili pink.
    static let biliPink = Color(red: 0.984, green: 0.447, blue: 0.6)
    static let biliBlue = Color(red: 0.0, green: 0.631, blue: 0.839)
}

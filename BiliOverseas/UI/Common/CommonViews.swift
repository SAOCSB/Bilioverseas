import SwiftUI
import SafariServices

/// Global lightweight toast ("已投币", "已跳过广告" …). Shown by `RootTabView`.
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

    @Published var current: Toast?
    private var hideTask: Task<Void, Never>?

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

struct ToastOverlay: View {
    @ObservedObject var center = ToastCenter.shared

    var body: some View {
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
                .padding(.bottom, 90)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.current)
        .allowsHitTesting(center.current?.action != nil)
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
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

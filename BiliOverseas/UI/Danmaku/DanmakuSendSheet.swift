import SwiftUI
import UIKit

/// 「发弹幕」 sheet. Present with `.sheet`; on success it calls `onSent` with the new danmaku
/// (`isSelf = true`) — pass it to `DanmakuOverlayView.insertLocal(_:)` — and dismisses itself.
struct DanmakuSendSheet: View {
    let aid: Int64
    let cid: Int64
    /// Current video position in seconds, read when the user taps send.
    let currentTime: () -> Double
    /// The uploader closed danmaku (segment `state == 1`).
    let isClosed: Bool
    let onSent: (DanmakuItem) -> Void

    init(aid: Int64, cid: Int64, currentTime: @escaping () -> Double, isClosed: Bool = false,
         onSent: @escaping (DanmakuItem) -> Void) {
        self.aid = aid
        self.cid = cid
        self.currentTime = currentTime
        self.isClosed = isClosed
        self.onSent = onSent
    }

    /// Official palette (white first).
    static let palette: [UInt32] = [
        0xFFFFFF, 0xFE0302, 0xFF7204, 0xFFAA02, 0xFFD302, 0xFFFF00, 0xA0EE00,
        0x00CD00, 0x019899, 0x4266BE, 0x89D5FF, 0xCC0273, 0x222222, 0x9B9B9B,
    ]
    static let maxLength = 100

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthService.shared
    @State private var text = ""
    @State private var color: UInt32 = 0xFFFFFF
    @State private var customColor: Color = .white
    @State private var mode = 1
    @State private var fontSize = 25
    @State private var sending = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if !(auth.isLoggedIn || BiliHTTP.shared.isLoggedIn) {
                    loginHint
                } else if isClosed {
                    StateMessageView(systemImage: "text.bubble", message: "UP主已关闭弹幕")
                } else {
                    form
                }
            }
            .navigationTitle("发弹幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var loginHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("登录后才能发送弹幕").foregroundStyle(.secondary)
            Text("请在「我的」页面扫码登录").font(.footnote).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var form: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 8) {
                    TextField("发个友善的弹幕见证当下", text: $text)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .foregroundColor(previewColor)
                    Text("\(text.count)/\(DanmakuSendSheet.maxLength)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }

            Section("弹幕样式") {
                Picker("弹幕样式", selection: $mode) {
                    Text("滚动").tag(1)
                    Text("顶部").tag(5)
                    Text("底部").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("弹幕字号") {
                Picker("弹幕字号", selection: $fontSize) {
                    Text("标准").tag(25)
                    Text("小").tag(18)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("弹幕颜色") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34, maximum: 44), spacing: 10)], spacing: 10) {
                    ForEach(DanmakuSendSheet.palette, id: \.self) { rgb in
                        DanmakuColorSwatch(rgb: rgb, selected: rgb == color)
                            .onTapGesture { color = rgb }
                    }
                }
                .padding(.vertical, 4)
                ColorPicker("自定义颜色", selection: $customColor, supportsOpacity: false)
            }

            Section {
                Button(action: send) {
                    HStack {
                        Spacer()
                        if sending {
                            ProgressView()
                        } else {
                            Text("发送").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(sending || trimmed.isEmpty)
            }
        }
        .onAppear { focused = true }
        .onChange(of: text) { newValue in
            if newValue.count > DanmakuSendSheet.maxLength {
                text = String(newValue.prefix(DanmakuSendSheet.maxLength))
            }
        }
        .onChange(of: customColor) { newValue in
            color = DanmakuSendSheet.rgb(of: newValue)
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var previewColor: Color {
        // Keep the text readable in the field: very light colours fall back to the primary colour.
        color == 0xFFFFFF ? .primary : DanmakuColorSwatch.color(color)
    }

    static func rgb(of color: Color) -> UInt32 {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0xFFFFFF }
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    private func send() {
        let msg = trimmed
        guard !msg.isEmpty, !sending else { return }
        sending = true
        errorText = nil
        let time = currentTime()
        let color = self.color, mode = self.mode, fontSize = self.fontSize
        Task { @MainActor in
            do {
                let dmid = try await DanmakuService.sendDanmaku(aid: aid, cid: cid, text: msg, time: time,
                                                                color: color, mode: mode, fontSize: fontSize)
                let mid = BiliHTTP.shared.mid ?? 0
                let item = DanmakuItem(id: dmid, time: time, mode: mode, fontSize: fontSize, color: color,
                                       midHash: mid > 0 ? DanmakuHash.midHash(mid: mid) : "", content: msg,
                                       ctime: Int64(Date().timeIntervalSince1970), weight: 11, isSelf: true)
                sending = false
                ToastCenter.shared.show("发送成功")
                onSent(item)
                dismiss()
            } catch {
                sending = false
                errorText = error.localizedDescription
            }
        }
    }
}

/// A round colour swatch.
struct DanmakuColorSwatch: View {
    let rgb: UInt32
    let selected: Bool

    static func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }

    var body: some View {
        Circle()
            .fill(DanmakuColorSwatch.color(rgb))
            .frame(width: 30, height: 30)
            .overlay(Circle().stroke(selected ? Color.biliPink : Color.secondary.opacity(0.35),
                                     lineWidth: selected ? 3 : 1))
            .padding(2)
            .contentShape(Circle())
            .accessibilityLabel(String(format: "颜色 %06X", rgb))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

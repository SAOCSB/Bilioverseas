import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 扫码登录. Web QR by default (gives the web refresh token for cookie refresh), TV QR as an
/// alternative (also yields an app `access_key`). Because the user is usually on the same iPhone,
/// the QR can be opened directly in the official app, saved to the album, or copied as a link;
/// pasting cookies is offered as an advanced fallback.
struct LoginView: View {
    @StateObject private var model = LoginQRViewModel()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCookieSheet = false
    @State private var cookieLoginSucceeded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                Picker("登录方式", selection: $model.mode) {
                    Text("网页扫码").tag(LoginQRViewModel.Mode.web)
                    Text("TV 扫码").tag(LoginQRViewModel.Mode.tv)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 32)

                Text(model.mode == .tv
                     ? "TV 扫码登录同时获得 access_key：首页使用 App 端个性化推荐，并支持点踩、不感兴趣等仅 App 端提供的功能"
                     : "网页扫码登录：只有网页登录时首页使用按账号个性化的网页端推荐；App 端推荐、点踩等功能需要 TV 扫码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                qrCard

                Text(model.phase.statusText)
                    .font(.subheadline)
                    .foregroundStyle(model.phase.statusColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                actions

                sameDeviceHint

                Button {
                    showCookieSheet = true
                } label: {
                    Label("Cookie 登录", systemImage: "key")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .padding(.vertical, 20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("登录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.mode) { _ in model.restart() }
        .onChange(of: scenePhase) { phase in
            LoginTrace.log("scene \(phase)")
            if phase == .active { model.pollNow() }
        }
        .onChange(of: model.didLogin) { done in
            if done { dismiss() }
        }
        .sheet(isPresented: $showCookieSheet, onDismiss: {
            if cookieLoginSucceeded { dismiss() }
        }) {
            LoginCookieSheet { cookieLoginSucceeded = true }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 6) {
            Text("扫描二维码登录")
                .font(.title3.bold())
            Text("登录后可同步历史记录、收藏、关注与大会员画质")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if auth.isLoggedIn {
                Text("当前已登录「\(auth.profile?.name ?? "账号")」，重新登录将切换账号")
                    .font(.caption)
                    .foregroundStyle(Color.biliPink)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal)
    }

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
            if let image = model.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .opacity(model.phase.dimsCode ? 0.08 : 1)
            }
            qrOverlay
        }
        .frame(width: 228, height: 228)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.phase.canRefresh { model.restart() }
        }
        .accessibilityLabel(Text(model.phase.statusText))
    }

    @ViewBuilder
    private var qrOverlay: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .waitingScan:
            EmptyView()
        case .scanned:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.biliPink)
                Text("已扫码").font(.headline).foregroundStyle(.black)
                Text("请在手机上确认").font(.caption).foregroundStyle(.gray)
            }
        case .expired, .failed:
            VStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.biliPink)
                Text(model.phase == .expired ? "二维码已失效" : "获取失败")
                    .font(.headline).foregroundStyle(.black)
                Text("点击刷新").font(.caption).foregroundStyle(.gray)
            }
        case .success:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.green)
                Text("登录成功").font(.headline).foregroundStyle(.black)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                model.openInBiliApp()
            } label: {
                Label("在哔哩哔哩 App 中打开", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.biliPink)

            HStack(spacing: 10) {
                Button {
                    model.saveToAlbum()
                } label: {
                    Label("保存二维码到相册", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                Button {
                    model.copyLink()
                } label: {
                    Label("复制登录链接", systemImage: "link")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .buttonStyle(.bordered)
            .tint(.biliPink)
            .font(.subheadline)
        }
        .labelStyle(.titleAndIcon)
        .disabled(!model.canUseCode)
        .padding(.horizontal, 24)
    }

    private var sameDeviceHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("在本机登录").font(.footnote.bold())
            Text("1. 点击「在哔哩哔哩 App 中打开」，在官方 App 内确认登录；")
            Text("2. 或「保存二维码到相册」，再打开哔哩哔哩 App 的「扫一扫」，从相册中选择该二维码；")
            Text("3. 用另一台设备上的哔哩哔哩 App 直接扫描屏幕上的二维码。")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 24)
    }
}

// MARK: - View model

@MainActor
final class LoginQRViewModel: ObservableObject {
    enum Mode: Hashable {
        case web, tv
    }

    enum Phase: Equatable {
        case loading
        case waitingScan
        case scanned
        case expired
        case success
        case failed(String)

        var statusText: String {
            switch self {
            case .loading: return "正在获取二维码…"
            case .waitingScan: return "请使用哔哩哔哩客户端扫码"
            case .scanned: return "已扫码，请在手机上确认"
            case .expired: return "二维码已失效，点击刷新"
            case .success: return "登录成功"
            case .failed(let msg): return "\(msg)，点击二维码刷新"
            }
        }

        var statusColor: Color {
            switch self {
            case .scanned: return .biliPink
            case .success: return .green
            case .failed: return .red
            default: return .secondary
            }
        }

        var dimsCode: Bool {
            switch self {
            case .waitingScan: return false
            default: return true
            }
        }

        var canRefresh: Bool {
            switch self {
            case .expired, .failed: return true
            default: return false
            }
        }
    }

    @Published var mode: Mode = .web
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var qrURL: String?
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var didLogin = false

    /// Web `qrcode_key` or TV `auth_code`.
    private var key: String?
    private var loopTask: Task<Void, Never>?
    /// Bumped on restart / stop / terminal states; stale loops and responses compare against it.
    private var session = 0
    private var polling = false
    private var issuedAt = Date()
    private var saver: LoginQRPhotoSaver?
    /// A fresh code is on its way for the official app (`openInBiliApp`).
    private var openWhenReady = false
    private var replacedUsedCode = false

    private static let pollInterval: UInt64 = 2_000_000_000
    /// The server expires codes after 180 s. Its answer is what counts; this is for when none comes.
    private static let lifetime: TimeInterval = 210
    /// A code said to be expired before this was not out of time: it was used (`codeExpired`).
    private static let usedBefore: TimeInterval = 170
    /// An older one is replaced before going to the official app, where the rest of its time would pass.
    private static let freshForOpening: TimeInterval = 120

    var canUseCode: Bool {
        qrURL != nil && (phase == .waitingScan || phase == .scanned)
    }

    func start() {
        guard loopTask == nil, !didLogin else { return }
        restart()
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        session += 1
        openWhenReady = false
    }

    func restart() {
        stop()
        guard !didLogin else { return }
        let s = session
        let m = mode
        phase = .loading
        qrURL = nil
        qrImage = nil
        key = nil
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.run(session: s, mode: m)
        }
    }

    /// Immediate poll, e.g. when returning from the official app.
    func pollNow() {
        guard loopTask != nil, phase == .waitingScan || phase == .scanned else { return }
        let s = session
        let m = mode
        Task { [weak self] in
            _ = await self?.pollOnce(session: s, mode: m)
        }
    }

    // MARK: Actions

    func openInBiliApp() {
        guard Date().timeIntervalSince(issuedAt) <= LoginQRViewModel.freshForOpening else {
            LoginTrace.log("open: code too old, replacing it")
            restart()
            openWhenReady = true
            return
        }
        openCodeInBiliApp()
    }

    private func openCodeInBiliApp() {
        LoginTrace.log("open in official app")
        guard let qrURL,
              let encoded = qrURL.addingPercentEncoding(withAllowedCharacters: BiliHTTP.uriComponentAllowed),
              let url = URL(string: "bilibili://browser?url=\(encoded)") else { return }
        // LSApplicationQueriesSchemes is not declared, so skip canOpenURL and rely on the result.
        UIApplication.shared.open(url, options: [:]) { ok in
            guard !ok else { return }
            Task { @MainActor in
                ToastCenter.shared.show("未能打开哔哩哔哩 App，请保存二维码到相册后在 App 中扫码", duration: 3.5)
            }
        }
    }

    func saveToAlbum() {
        guard let qrURL, let poster = LoginQRRenderer.posterImage(for: qrURL) else { return }
        let saver = LoginQRPhotoSaver { [weak self] error in
            Task { @MainActor in
                self?.saver = nil
                if error != nil {
                    ToastCenter.shared.show("保存失败，请在「设置」中允许本 App 添加照片", duration: 3)
                } else {
                    ToastCenter.shared.show("已保存，请在哔哩哔哩 App「扫一扫」中从相册选择", duration: 3.5)
                }
            }
        }
        self.saver = saver
        saver.save(poster)
    }

    func copyLink() {
        guard let qrURL else { return }
        UIPasteboard.general.string = qrURL
        ToastCenter.shared.show("已复制登录链接")
    }

    // MARK: Loop

    private func run(session s: Int, mode m: Mode) async {
        LoginTrace.log("new code \(m)")
        do {
            let url: String
            let code: String
            switch m {
            case .web:
                let r = try await LoginAPI.generateWebQR()
                url = r.url
                code = r.key
            case .tv:
                let r = try await LoginAPI.generateTVQR()
                url = r.url
                code = r.authCode
            }
            guard s == session, !Task.isCancelled else { return }
            key = code
            qrURL = url
            qrImage = LoginQRRenderer.image(for: url)
            issuedAt = Date()
            phase = .waitingScan
            if openWhenReady {
                openWhenReady = false
                openCodeInBiliApp()
            }
        } catch {
            guard s == session, !Task.isCancelled else { return }
            LoginTrace.log("new code failed: \(LoginQRViewModel.traceText(for: error))")
            openWhenReady = false
            phase = .failed(LoginQRViewModel.message(for: error))
            return
        }
        while !Task.isCancelled, s == session {
            try? await Task.sleep(nanoseconds: LoginQRViewModel.pollInterval)
            guard !Task.isCancelled, s == session else { return }
            if await pollOnce(session: s, mode: m) { return }
        }
    }

    /// One poll; returns `true` when polling is over (success, expiry or a hard error).
    private func pollOnce(session s: Int, mode m: Mode) async -> Bool {
        guard s == session, let key else { return true }
        guard !polling else { return false }
        // Only with the app in front. The server gives a login out once, then calls the code expired; a response that
        // arrives as iOS suspends the app is lost, and the user who confirmed in the official app comes back to
        // 「二维码已失效」. Coming back polls at once (`pollNow`).
        guard UIApplication.shared.applicationState == .active else { return false }
        polling = true
        defer { polling = false }
        do {
            // A success is completed even when this poll's session is stale (code refreshed, mode
            // switched or screen left while the request was in flight): the user has confirmed on the
            // phone, the code is consumed, and for web QR the response already stored the session
            // cookies via Set-Cookie. Dropping it would leave a half-applied login (cookies without
            // tokens / profile) or lose the TV access_key.
            switch m {
            case .web:
                let state = try await LoginAPI.pollWebQR(key: key)
                LoginTrace.log("poll web: \(LoginQRViewModel.traceText(for: state)), age \(age)")
                if case .success(let refreshToken, let crossDomainURL) = state {
                    end(.success)
                    await AuthService.shared.completeWebQRLogin(refreshToken: refreshToken, crossDomainURL: crossDomainURL)
                    finishLogin()
                    return true
                }
                guard s == session else { return true }
                switch state {
                case .waitingScan:
                    phase = .waitingScan
                case .scannedWaitingConfirm:
                    phase = .scanned
                case .expired:
                    codeExpired()
                    return true
                case .success:
                    return true
                }
            case .tv:
                let state = try await LoginAPI.pollTVQR(authCode: key)
                if case .success(let result) = state {
                    end(.success)
                    await AuthService.shared.completeTVLogin(result)
                    finishLogin()
                    return true
                }
                guard s == session else { return true }
                switch state {
                case .waitingScan:
                    phase = .waitingScan
                case .scannedWaitingConfirm:
                    phase = .scanned
                case .expired:
                    codeExpired()
                    return true
                case .success:
                    return true
                }
            }
        } catch let e as BiliError {
            LoginTrace.log("poll failed: \(LoginQRViewModel.traceText(for: e)), age \(age)")
            guard s == session else { return true }
            if case .api = e {
                end(.failed(LoginQRViewModel.message(for: e)))
                return true
            }
            // Transport hiccup: keep polling.
        } catch {
            // URLError etc.: keep polling.
            LoginTrace.log("poll failed: \(LoginQRViewModel.traceText(for: error)), age \(age)")
        }
        guard s == session else { return true }
        if Date().timeIntervalSince(issuedAt) > LoginQRViewModel.lifetime {
            end(.expired)
            return true
        }
        return false
    }

    /// Seconds since the code was made, for the trace.
    private var age: Int { Int(Date().timeIntervalSince(issuedAt)) }

    /// The server calls the code expired. One too young for that was used, and the answer that carried the login did not
    /// reach us (the network dropped): say what happened and put up a new code, once.
    private func codeExpired() {
        guard Date().timeIntervalSince(issuedAt) < LoginQRViewModel.usedBefore, !replacedUsedCode else {
            end(.expired)
            return
        }
        replacedUsedCode = true
        ToastCenter.shared.show("没有收到登录结果，已换新的二维码，请再确认一次", duration: 3.5)
        restart()
    }

    /// Terminal state: the loop and any in-flight poll stop acting.
    private func end(_ p: Phase) {
        session += 1
        loopTask = nil
        phase = p
    }

    private func finishLogin() {
        LoginTrace.log("login finished, signed in: \(BiliHTTP.shared.isLoggedIn)")
        ToastCenter.shared.show("登录成功")
        didLogin = true
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func traceText(for state: QRLoginState) -> String {
        if case .success = state { return "success" }
        return "\(state)"
    }

    /// Without the URL, which holds the code.
    private static func traceText(for error: Error) -> String {
        if let e = error as? URLError { return "URLError \(e.code.rawValue)" }
        if let e = error as? BiliError {
            if case .api(let code, _) = e { return "api \(code)" }
            return "BiliError"
        }
        return "other"
    }
}

/// What the login screen did, without codes or tokens, kept where it can be read off a phone
/// (`Library/Caches/login-trace.txt`): logging in has failed on and off, and only on phones.
enum LoginTrace {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    @MainActor static func log(_ line: String) {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("login-trace.txt")
        let state = UIApplication.shared.applicationState == .active ? "front" : "back"
        let text = "\(formatter.string(from: Date())) [\(state)] \(line)\n"
        var kept = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if kept.count > 20_000 { kept = String(kept.suffix(10_000)) }
        try? (kept + text).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - QR rendering

enum LoginQRRenderer {
    private static let context = CIContext()

    /// Crisp QR image (each module `scale` px, no smoothing).
    static func image(for string: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// Album version: the code on a white square with a generous quiet zone, so the official
    /// app's "scan from album" picks it up reliably.
    static func posterImage(for string: String, side: CGFloat = 900) -> UIImage? {
        guard let qr = image(for: string, scale: 16), let cg = qr.cgImage else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.cgContext.interpolationQuality = .none
            let inset = side * 0.12
            let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
            UIImage(cgImage: cg).draw(in: rect)
        }
    }
}

/// Target object for `UIImageWriteToSavedPhotosAlbum`'s completion selector.
final class LoginQRPhotoSaver: NSObject {
    private let completion: (Error?) -> Void
    /// UIKit does not promise to retain the completion target; a second tap replaces the model's
    /// reference, and the screen may go away before the callback. Stay alive until it arrives.
    private var keepAlive: LoginQRPhotoSaver?

    init(completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    func save(_ picture: UIImage) {
        keepAlive = self
        UIImageWriteToSavedPhotosAlbum(picture, self,
                                       #selector(LoginQRPhotoSaver.image(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        completion(error)
        keepAlive = nil
    }
}

// MARK: - Cookie login

/// 「Cookie 登录」: paste `SESSDATA=…; bili_jct=…; DedeUserID=…`.
struct LoginCookieSheet: View {
    var onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSubmitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 150)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("粘贴 Cookie")
                } footer: {
                    Text("格式：SESSDATA=…; bili_jct=…; DedeUserID=…\n可在电脑浏览器登录 bilibili.com 后从开发者工具中复制。Cookie 仅保存在本机钥匙串中。")
                }

                Section {
                    Button {
                        if let s = UIPasteboard.general.string { text = s }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Cookie 登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Cancelling mid-submit would not stop the login, only lose its "dismiss login" step.
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("登录") { submit() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func submit() {
        isSubmitting = true
        errorText = nil
        let value = text
        Task { @MainActor in
            do {
                try await AuthService.shared.loginWithCookieString(value)
                isSubmitting = false
                ToastCenter.shared.show("登录成功")
                onSuccess()
                dismiss()
            } catch {
                isSubmitting = false
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

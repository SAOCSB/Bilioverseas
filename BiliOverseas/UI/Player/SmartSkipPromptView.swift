// SmartSkip — native prompt for the Swift port of BiliSmartSkip by wzy403
// (https://github.com/wzy403/BiliSmartSkip), GPL-2.0. Re-implements the skip button of
// `scr/skipper.js` (black 70 % capsule, 1 px white 30 % border, 14 pt bold white text, right 24 pt /
// bottom 10 % of the player). Part of BiliOverseas (GPL-2.0-or-later).

import SwiftUI

/// The 「跳过广告」 capsule with a countdown ring and a dismiss ✕. Overlay it on the player:
///
/// ```swift
/// .overlay(alignment: .bottomTrailing) {
///     if let prompt = model.skipPrompt {
///         SmartSkipPromptView(segment: prompt.segment, remaining: prompt.remaining,
///                             total: Double(settings.smartSkip.countdownSeconds),
///                             onSkip: { model.smartSkipTapped(prompt.segment) },
///                             onDismiss: { model.smartSkipDismissed(prompt.segment) })
///             .padding(.trailing, 24)
///             .padding(.bottom, playerHeight * 0.1)
///             .transition(.move(edge: .trailing).combined(with: .opacity))
///     }
/// }
/// ```
struct SmartSkipPromptView: View {
    let segment: AdSegment
    /// Seconds left before the prompt hides by itself (`SmartSkipAction.showPrompt`).
    let remaining: Double
    /// Full countdown length, for the ring.
    var total: Double = 5
    let onSkip: () -> Void
    let onDismiss: () -> Void
    /// Pointer hover on iPad (pause the countdown: `tracker.setInteracting(_:now:)`).
    var onInteractionChanged: ((Bool) -> Void)? = nil

    private var seconds: Int { remaining.isFinite ? max(0, Int(remaining.rounded(.up))) : 0 }
    private var progress: Double { total > 0 && remaining.isFinite ? min(1, max(0, remaining / total)) : 0 }
    private var title: String { segment.requiresConfirmation ? "跳过疑似广告" : "跳过广告" }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSkip) {
                HStack(spacing: 8) {
                    countdownRing
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                    Text("\(seconds)s")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.75))
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(title)，\(seconds) 秒后隐藏"))

            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 1, height: 18)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("关闭跳过提示"))
        }
        .foregroundStyle(Color.white)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
        .clipShape(Capsule())
        .fixedSize()
        .onHover { hovering in onInteractionChanged?(hovering) }
    }

    private var countdownRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.biliPink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
            Image(systemName: "forward.end.fill")
                .font(.system(size: 8, weight: .bold))
        }
        .frame(width: 20, height: 20)
    }
}

import SwiftUI

/// 全屏 of a landscape video in the 短视频 feed, on the feed's own player: a tap shows the controls, a double tap pauses.
struct ShortVideoLandscapeView: View {
    @ObservedObject var playback: ShortVideoPlayback
    let title: String
    let onTogglePlay: () -> Void
    let onBack: () -> Void

    @State private var readyForDisplay = false
    @State private var controlsShown = true
    @State private var scrubbing: Double?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                ShortVideoSurface(player: playback.player, fill: false, readyForDisplay: $readyForDisplay)
                ShortVideoDanmakuLayer(playback: playback, landscape: true)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onTogglePlay)
                .onTapGesture {
                    controlsShown.toggle()
                    hideControlsLater()
                }
            if let scrubbing {
                PlayerPill { Text("\(PlayerFormat.time(scrubbing))/\(PlayerFormat.time(playback.duration))").monospacedDigit() }
                    .allowsHitTesting(false)
            } else if playback.isPaused {
                VerticalVideoPausedHint(time: "\(PlayerFormat.time(playback.position)) / \(PlayerFormat.time(playback.duration))")
            }
            if controlsShown { controls }
        }
        .foregroundColor(.white)
        .animation(.easeInOut(duration: 0.2), value: controlsShown)
        .onAppear { hideControlsLater() }
        .onDisappear { hideTask?.cancel() }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onBack) {
                    VerticalVideoBarIcon(systemName: "chevron.backward")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("返回"))
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button {
                    onTogglePlay()
                    hideControlsLater()
                } label: {
                    VerticalVideoBarIcon(systemName: playback.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(playback.isPaused ? "播放" : "暂停"))
                Text(PlayerFormat.time(scrubbing ?? playback.position))
                    .font(.system(size: 12).monospacedDigit())
                PlayerProgressBar(timeline: playback.timeline, chapters: [], segments: [], clips: [],
                                  onScrubBegan: { hideTask?.cancel() },
                                  onScrubChanged: { scrubbing = $0 },
                                  onScrubEnded: { target in
                                      scrubbing = nil
                                      playback.seek(to: target)
                                      hideControlsLater()
                                  },
                                  onScrubCancelled: {
                                      scrubbing = nil
                                      hideControlsLater()
                                  })
                Text(PlayerFormat.time(playback.duration))
                    .font(.system(size: 12).monospacedDigit())
            }
            .padding(.trailing, 12)
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
        .transition(.opacity)
    }

    private func hideControlsLater() {
        hideTask?.cancel()
        guard controlsShown else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { controlsShown = false }
        }
    }
}

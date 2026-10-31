import Foundation
import MediaPlayer
import UIKit

/// Lock screen / Control Center 「正在播放」 and remote commands for the video player. Several detail pages may exist
/// at once (related video pushed on top), so the controller that last started playback owns the commands.
@MainActor
final class PlayerNowPlayingCenter {
    static let shared = PlayerNowPlayingCenter()

    enum Command {
        case play, pause, toggle, skipForward, skipBackward, next, previous
        case seek(Double)
    }

    private weak var owner: PlayerController?
    private var commandsInstalled = false
    private var artwork: MPMediaItemArtwork?
    private var artworkURL = ""
    private var artworkTask: Task<Void, Never>?

    /// The controller started playing: it now owns Now Playing and the remote commands.
    func claim(_ controller: PlayerController) {
        installCommandsIfNeeded()
        if owner !== controller {
            let previous = owner
            owner = controller
            artwork = nil
            artworkURL = ""
            // One video at a time: the player that played before (a covered page still in PiP …) pauses.
            if let previous, previous.wantsToPlay { previous.pause() }
        }
        // A PiP window left over from a closed page ends (its controller then stops).
        PlayerPiPKeeper.stopOthers(than: controller)
        // …and so does a live room still playing in its own PiP window.
        LivePiPKeeper.yield(to: nil)
        setCommandsEnabled(true)
        refresh(controller)
        loadArtworkIfNeeded(controller)
    }

    /// A live room starts playing: the video that owns Now Playing pauses and leftover video PiP
    /// windows close, so live and video never play over each other.
    func pauseForLive() {
        if let owner, owner.wantsToPlay { owner.pause() }
        PlayerPiPKeeper.stopOthers(than: nil)
    }

    /// The 短视频 feed comes on screen. It plays by itself and has no Now Playing of its own, so a video page it
    /// covers gives up the commands: the lock screen or a headset would otherwise start that page's video over the
    /// feed. The page claims them again when it next plays. A video in Picture in Picture keeps them.
    func shortVideosAppeared() {
        if let owner, !owner.isPiPBusy { release(owner) }
    }

    func release(_ controller: PlayerController) {
        guard owner === controller else { return }
        owner = nil
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        artworkURL = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        setCommandsEnabled(false)
    }

    /// State changed (play / pause / seek / rate / new item): refresh if this controller owns Now Playing.
    func playbackChanged(_ controller: PlayerController) {
        guard owner === controller else { return }
        refresh(controller)
        loadArtworkIfNeeded(controller)
    }

    private func refresh(_ controller: PlayerController) {
        guard let item = controller.item else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.title
        if !item.subtitle.isEmpty { info[MPMediaItemPropertyAlbumTitle] = item.subtitle }
        if !item.ownerName.isEmpty { info[MPMediaItemPropertyArtist] = item.ownerName }
        if controller.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = controller.duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = controller.displayTime()
        // The rate AVPlayer really runs at (HLS is capped at 2×), so the lock-screen clock does not drift.
        info[MPNowPlayingInfoPropertyPlaybackRate] = controller.status == .playing ? Double(controller.playerRate) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = controller.rate
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = controller.hasNext
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = controller.hasPrevious
    }

    private func loadArtworkIfNeeded(_ controller: PlayerController) {
        guard let cover = controller.item?.cover, !cover.isEmpty else { return }
        let url = Fmt.thumb(cover, width: 640)
        guard url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let image = await ImagePipeline.shared.image(for: url), !Task.isCancelled else { return }
            guard let self, self.artworkURL == url, let owner = self.owner else { return }
            self.artwork = PlayerNowPlayingCenter.makeArtwork(image)
            self.refresh(owner)
        }
    }

    /// Built outside the main actor: MediaPlayer calls the request handler on its own queue.
    nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: Remote commands

    private func installCommandsIfNeeded() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in PlayerNowPlayingCenter.dispatch(.play) }
        center.pauseCommand.addTarget { _ in PlayerNowPlayingCenter.dispatch(.pause) }
        center.togglePlayPauseCommand.addTarget { _ in PlayerNowPlayingCenter.dispatch(.toggle) }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { _ in PlayerNowPlayingCenter.dispatch(.skipForward) }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { _ in PlayerNowPlayingCenter.dispatch(.skipBackward) }
        center.nextTrackCommand.addTarget { _ in PlayerNowPlayingCenter.dispatch(.next) }
        center.previousTrackCommand.addTarget { _ in PlayerNowPlayingCenter.dispatch(.previous) }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return PlayerNowPlayingCenter.dispatch(.seek(e.positionTime))
        }
    }

    private func setCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
        center.skipForwardCommand.isEnabled = enabled
        center.skipBackwardCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled
        center.nextTrackCommand.isEnabled = enabled && (owner?.hasNext ?? false)
        center.previousTrackCommand.isEnabled = enabled && (owner?.hasPrevious ?? false)
    }

    nonisolated static func dispatch(_ command: Command) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in PlayerNowPlayingCenter.shared.perform(command) }
        return .success
    }

    private func perform(_ command: Command) {
        guard let owner else { return }
        switch command {
        case .play: owner.play()
        case .pause: owner.pause()
        case .toggle: owner.togglePlay()
        case .skipForward: owner.seek(by: 10)
        case .skipBackward: owner.seek(by: -10)
        case .next: owner.onNext?()
        case .previous: owner.onPrevious?()
        case .seek(let t): owner.seek(to: t)
        }
    }
}

import Foundation
import MediaPlayer
import UIKit

/// Lock screen / Control Center 「正在播放」 and remote commands for the video player. Several detail pages may exist
/// at once (related video pushed on top), so the controller that last started playback owns the commands.
@MainActor
final class PlayerNowPlayingCenter {
    static let shared = PlayerNowPlayingCenter()

    enum Command {
        case play, pause, toggle, skipForward, skipBackward, next
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
            owner = controller
            artwork = nil
            artworkURL = ""
        }
        setCommandsEnabled(true)
        refresh(controller)
        loadArtworkIfNeeded(controller)
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
        center.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return PlayerNowPlayingCenter.dispatch(.seek(e.positionTime))
        }
        center.previousTrackCommand.isEnabled = false
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
        case .seek(let t): owner.seek(to: t)
        }
    }
}

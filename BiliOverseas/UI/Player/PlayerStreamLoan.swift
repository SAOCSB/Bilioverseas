import AVFoundation

/// A video playing on another screen, lent to its page as it is: the player itself, with its item and stream. The page goes
/// on with it rather than opening the video again, so nothing stops or starts over. It goes back when the page goes on to
/// something else or goes away (`PlayerController.endLoan`).
@MainActor
final class PlayerStreamLoan {
    let player: AVPlayer
    let playerItem: AVPlayerItem
    let session: PlaybackSession
    let info: PlayInfo
    let fetchedAt: Date
    let choice: PlayerStreamChoice
    let accelerated: Bool
    /// What the switches wanted for it when it was chosen (`PlayerController.accelerationWanted`).
    let accelerationWanted: Bool
    /// What the page knows of the video until it has its detail.
    let item: PlaybackItem
    let isPlaying: Bool
    /// `playing`: how it is left. `returning`: to that screen, which comes back on now and just goes on with it.
    let giveBack: (_ playing: Bool, _ returning: Bool) -> Void

    init(player: AVPlayer, playerItem: AVPlayerItem, session: PlaybackSession, info: PlayInfo, fetchedAt: Date,
         choice: PlayerStreamChoice, accelerated: Bool, accelerationWanted: Bool, item: PlaybackItem, isPlaying: Bool,
         giveBack: @escaping (Bool, Bool) -> Void) {
        self.player = player
        self.playerItem = playerItem
        self.session = session
        self.info = info
        self.fetchedAt = fetchedAt
        self.choice = choice
        self.accelerated = accelerated
        self.accelerationWanted = accelerationWanted
        self.item = item
        self.isPlaying = isPlaying
        self.giveBack = giveBack
    }
}

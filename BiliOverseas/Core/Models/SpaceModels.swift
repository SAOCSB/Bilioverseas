import Foundation

/// Header of a user's space (个人空间).
struct SpaceInfo: Hashable {
    /// mid, name, face, sign, level, vipLabel, isFollowed, fans.
    var user: UserBrief
    /// "男" / "女" / "保密".
    var sex: String = ""
    /// Official verification text (e.g. "bilibili 知名UP主"); empty when none.
    var officialTitle: String = ""
    /// -1 none, 0 personal, 1 organisation.
    var officialType: Int = -1
    /// Space banner (https).
    var topPhoto: String = ""
    /// 关注数.
    var following: Int64 = 0
    /// 粉丝数.
    var fans: Int64 = 0
    /// 获赞数 (0 when unknown).
    var likes: Int64 = 0
    /// 投稿数 (0 when unknown).
    var archiveCount: Int64 = 0
    /// The current user follows this UP.
    var isFollowed: Bool = false
    var liveRoomId: Int64 = 0
    /// 1 = 直播中.
    var liveStatus: Int = 0
    var liveTitle: String = ""
    var isSeniorMember: Bool = false

    init(user: UserBrief) { self.user = user }

    var mid: Int64 { user.mid }
    var name: String { user.name }
    var face: String { user.face }
    var sign: String { user.sign }
    var level: Int { user.level }
    var vipLabel: String { user.vipLabel }
    var isLive: Bool { liveStatus == 1 && liveRoomId != 0 }
}

/// Ordering of a UP's videos: 最新发布 / 最多播放 / 最多收藏.
enum SpaceVideoOrder: String, CaseIterable, Identifiable {
    case pubdate, click, stow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pubdate: return "最新发布"
        case .click: return "最多播放"
        case .stow: return "最多收藏"
        }
    }
}

/// `/x/relation/modify` act codes.
enum RelationAction: Int {
    case follow = 1, unfollow = 2, whisperFollow = 3, cancelWhisper = 4, block = 5, unblock = 6, removeFan = 7
}

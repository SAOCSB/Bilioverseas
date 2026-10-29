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

/// The signed-in user's relation to another user (`/x/relation?fid=`), shown on follow buttons.
enum UserRelationState: Hashable {
    case notFollowing, whisper, followed, mutual, special, blocked

    /// `attribute`: 0 未关注, 1 悄悄关注, 2 已关注, 4 / 6 互相关注, 128 已拉黑. `special == 1` (特别关注) wins
    /// over the other follow states.
    init(attribute: Int, special: Bool) {
        switch attribute {
        case 128: self = .blocked
        case 1: self = special ? .special : .whisper
        case 2: self = special ? .special : .followed
        case 4, 6: self = special ? .special : .mutual
        default: self = .notFollowing
        }
    }

    /// `/x/relation` `data`.
    init(json: JSON) {
        self.init(attribute: json["attribute"].intValue, special: json["special"].intValue == 1)
    }

    var isFollowing: Bool {
        switch self {
        case .whisper, .followed, .mutual, .special: return true
        case .notFollowing, .blocked: return false
        }
    }

    /// Follow-button text (official wording).
    var label: String {
        switch self {
        case .notFollowing: return "关注"
        case .whisper: return "悄悄关注"
        case .followed: return "已关注"
        case .mutual: return "已互关"
        case .special: return "特别关注"
        case .blocked: return "已拉黑"
        }
    }

    /// `/x/relation/modify` act that undoes this follow state. act 2 also ends a 悄悄关注 (PiliPlus unfollows every
    /// state with it); the documented act 4 is unverified, and a rejected act would leave the user stuck followed.
    var unfollowAction: RelationAction { .unfollow }
}

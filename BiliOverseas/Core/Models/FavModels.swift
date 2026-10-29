import Foundation

/// A favorites folder (收藏夹) or, in the collected list, a subscribed folder / 合集.
struct FavFolder: Identifiable, Hashable {
    /// `media_id` — what every folder API takes.
    var id: Int64
    var fid: Int64 = 0
    /// Owner mid.
    var mid: Int64 = 0
    var title: String = ""
    /// https cover (empty for an empty folder).
    var cover: String = ""
    /// Number of items (`media_count`).
    var count: Int = 0
    /// `attr` bit 0.
    var isPrivate: Bool = false
    /// 默认收藏夹 (`attr` bit 1 == 0).
    var isDefault: Bool = false
    var intro: String = ""
    var upperName: String = ""
    var upperMid: Int64 = 0
    var upperFace: String = ""
    /// `list-all` queried with a resource: the resource is already in this folder (`fav_state == 1`).
    var containsResource: Bool = false
    /// Collected-list entry that is a UGC 合集 (type 21) — open with `FavAPI.seasonContents`.
    var isSeason: Bool = false

    init(id: Int64) { self.id = id }

    var mediaId: Int64 { id }
}

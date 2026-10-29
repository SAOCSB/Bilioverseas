import SwiftUI
import UIKit

/// Sheets presented from the 简介 tab. 投币 / 收藏 carry the video they were opened for: they stay open when
/// auto-next replaces the page, and must not act on the new video then.
enum VideoIntroSheet: Identifiable {
    case coin(aid: Int64, maxCoins: Int, given: Int)
    case favorite(rid: Int64, type: Int)
    case parts, ugcSeason, pgcEpisodes, pgcInfo

    var id: String {
        switch self {
        case .coin(let aid, _, _): return "coin-\(aid)"
        case .favorite(let rid, let type): return "favorite-\(type)-\(rid)"
        case .parts: return "parts"
        case .ugcSeason: return "ugcSeason"
        case .pgcEpisodes: return "pgcEpisodes"
        case .pgcInfo: return "pgcInfo"
        }
    }
}

/// 简介 tab: UP / staff header, title + stats (expandable to desc, BV号, tags), banners, action row,
/// 分P / 合集 selectors and 相关推荐 — or, for PGC, the season header, episode lists and other seasons.
struct VideoIntroView: View {
    @ObservedObject var model: VideoDetailModel
    var onSeek: (Double) -> Void = { _ in }

    @EnvironmentObject private var router: TabRouter
    @State private var sheet: VideoIntroSheet?
    @State private var expanded = false
    @State private var unfollowMid: Int64?
    @State private var confirmUnblock = false

    var body: some View {
        ScrollView {
            if let season = model.season {
                pgcContent(season)
            } else if let detail = model.detail {
                ugcContent(detail)
            } else {
                VideoIntroSkeleton()
            }
        }
        .id(model.contentID)
        .overlay(alignment: .top) {
            if model.isSwitching {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.8)
                    Text("加载中…").font(.system(size: 12))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
            }
        }
        .sheet(item: $sheet) { item in
            sheetView(item)
        }
        .confirmationDialog("确定不再关注？", isPresented: unfollowBinding, titleVisibility: .visible,
                            presenting: unfollowMid) { mid in
            Button("不再关注", role: .destructive) {
                Task { await model.toggleFollow(mid: mid) }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("已将TA拉黑，解除拉黑后才能关注", isPresented: $confirmUnblock, titleVisibility: .visible) {
            Button("解除拉黑", role: .destructive) {
                Task { await model.unblockOwner() }
            }
            Button("取消", role: .cancel) {}
        }
        .environment(\.openURL, OpenURLAction { url in handle(url) })
        .onChange(of: model.contentID) { _ in
            expanded = false
        }
    }

    // MARK: UGC

    private func ugcContent(_ d: VideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if d.staff.count > 1 {
                    staffStrip(d)
                } else {
                    upHeader(d)
                }
                titleBlock(d)
                banners(d)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            actionRow
                .padding(.top, 4)

            if d.pages.count > 1 {
                partsSection(d)
            }
            if let ugc = d.ugcSeason, !ugc.allEpisodes.isEmpty {
                ugcSeasonSection(ugc, currentAid: d.aid)
            }
            Divider().padding(.top, 6)
            relatedSection
        }
        .padding(.bottom, 24)
    }

    private var actionRow: some View {
        VideoIntroActionRow(model: model,
                            requireLogin: { requireLogin() },
                            onCoin: { openCoin() },
                            onFavorite: { openFavorite() })
    }

    private func upHeader(_ d: VideoDetail) -> some View {
        HStack(spacing: 10) {
            Button {
                if d.owner.mid > 0 { router.push(.user(mid: d.owner.mid)) }
            } label: {
                HStack(spacing: 10) {
                    AvatarView(url: d.owner.face, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.owner.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(model.ownerIsVip ? .biliPink : .primary)
                            .lineLimit(1)
                        Text(fansLine)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if d.owner.mid > 0 && d.owner.mid != BiliHTTP.shared.mid {
                followButton(mid: d.owner.mid)
            }
        }
    }

    private var fansLine: String {
        var parts: [String] = []
        if model.ownerFans > 0 { parts.append("\(Fmt.count(model.ownerFans))粉丝") }
        if model.ownerArchiveCount > 0 { parts.append("\(Fmt.count(model.ownerArchiveCount))视频") }
        return parts.isEmpty ? " " : parts.joined(separator: "    ")
    }

    /// 「+ 关注」 / 已关注 / 悄悄关注 / 已互关 / 特别关注 / 已拉黑.
    private func followButton(mid: Int64) -> some View {
        let state = model.relationState(for: mid)
        let plain = state == .notFollowing
        return Button {
            followTapped(mid)
        } label: {
            Text(plain ? "+ 关注" : state.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(plain ? .white : .secondary)
                .frame(width: 72, height: 28)
                .background(plain ? Color.biliPink : Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(model.busy.contains(.follow))
    }

    private func followTapped(_ mid: Int64) {
        guard requireLogin() else { return }
        if model.relationState(for: mid) == .blocked {
            confirmUnblock = true
        } else if model.isFollowing(mid) {
            unfollowMid = mid
        } else {
            Task { await model.toggleFollow(mid: mid) }
        }
    }

    private var unfollowBinding: Binding<Bool> {
        Binding(get: { unfollowMid != nil }, set: { if !$0 { unfollowMid = nil } })
    }

    private func staffStrip(_ d: VideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("创作团队").font(.system(size: 14, weight: .medium))
                Text("\(d.staff.count)人").font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(d.staff) { staff in
                        staffItem(staff)
                    }
                }
            }
        }
    }

    private func staffItem(_ staff: VideoDetail.Staff) -> some View {
        let mid = staff.user.mid
        let following = model.isFollowing(mid)
        return VStack(spacing: 4) {
            Button {
                if mid > 0 { router.push(.user(mid: mid)) }
            } label: {
                AvatarView(url: staff.user.face, size: 40)
            }
            .buttonStyle(.plain)
            Text(staff.user.name)
                .font(.system(size: 11))
                .foregroundColor(staff.user.vipLabel.isEmpty ? .primary : .biliPink)
                .lineLimit(1)
            Text(staff.title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
            if mid > 0 && mid != BiliHTTP.shared.mid {
                Button {
                    followTapped(mid)
                } label: {
                    Text(following ? "已关注" : "关注")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(following ? .secondary : .white)
                        .frame(width: 44, height: 18)
                        .background(following ? Color(.secondarySystemFill) : Color.biliPink, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 62)
    }

    private func titleBadges(_ d: VideoDetail) -> [String] {
        var out: [String] = []
        if d.isUpowerExclusive { out.append("充电专属") }
        if d.rights.isSteinGate { out.append("互动视频") }
        return out
    }

    private func titleBlock(_ d: VideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let badges = titleBadges(d)
            if !badges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(badges, id: \.self) { BadgeLabel(text: $0) }
                }
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Text(d.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(expanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .padding(.top, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { copy(d.title, toast: "已复制标题") } label: { Label("复制标题", systemImage: "doc.on.doc") }
            }
            statsLine(d)
            if expanded {
                expandedInfo(d)
            }
        }
    }

    private func statsLine(_ d: VideoDetail) -> some View {
        VideoFlowLayout(spacing: 10, lineSpacing: 4) {
            Label(Fmt.count(model.counts.view), systemImage: "play.rectangle")
            Label(Fmt.count(model.counts.danmaku), systemImage: "text.bubble")
            if d.pubdate > 0 {
                Text(Fmt.relativeDate(d.pubdate))
            }
            if !d.bvid.isEmpty {
                Button { copy(d.bvid, toast: "已复制BV号") } label: { Text(d.bvid) }
                    .buttonStyle(.plain)
            }
            if let online = model.onlineText {
                Text("\(online)人在看")
            }
        }
        .labelStyle(CompactLabelStyle())
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    private func expandedInfo(_ d: VideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if d.copyright == 2 {
                    Text("转载")
                } else if d.rights.noReprint {
                    HStack(spacing: 2) {
                        Image(systemName: "nosign")
                        Text("未经作者授权，禁止转载")
                    }
                }
                if !d.tname.isEmpty { Text(d.tname) }
                if d.pubdate > 0 { Text(Fmt.dateTime(d.pubdate)) }
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            if !d.desc.isEmpty {
                VideoRichText.text(VideoRichText.segments(d.desc))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .tint(.biliBlue)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu {
                        Button { copy(d.desc, toast: "已复制简介") } label: { Label("复制简介", systemImage: "doc.on.doc") }
                    }
            }
            if !model.tags.isEmpty {
                VideoFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(model.tags.indices, id: \.self) { i in
                        tagChip(model.tags[i])
                    }
                }
            }
        }
        .transition(.opacity)
    }

    private func tagChip(_ tag: String) -> some View {
        Button {
            router.push(.search(keyword: tag))
        } label: {
            Text(tag)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func banners(_ d: VideoDetail) -> some View {
        if let honor = d.honorText {
            HStack(spacing: 4) {
                Image(systemName: "trophy.fill")
                Text(honor).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundColor(Color(red: 0.92, green: 0.55, blue: 0.1))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
        if !d.argueText.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "exclamationmark.circle")
                Text(d.argueText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundColor(Color(.systemOrange))
        }
    }

    // MARK: Parts (分P)

    private func partsSection(_ d: VideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("选集").font(.system(size: 14, weight: .medium))
                Text("(\(d.pages.count))").font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Button {
                    sheet = .parts
                } label: {
                    HStack(spacing: 2) {
                        Text("全部 \(d.pages.count) 个")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(d.pages) { part in
                            partChip(part).id(part.cid)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onAppear { proxy.scrollTo(model.currentCid, anchor: .center) }
                .onChange(of: model.currentCid) { cid in
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(cid, anchor: .center) }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func partChip(_ part: VideoPart) -> some View {
        let selected = part.cid == model.currentCid
        return Button {
            model.selectPart(part)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("P\(part.page)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(selected ? .biliPink : .secondary)
                Text(part.part.isEmpty ? "P\(part.page)" : part.part)
                    .font(.system(size: 13))
                    .foregroundColor(selected ? .biliPink : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: 140, height: 60, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.biliPink : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: UGC season (合集)

    private func ugcSeasonSection(_ ugc: UgcSeason, currentAid: Int64) -> some View {
        let episodes = ugc.allEpisodes
        let index = episodes.firstIndex(where: { $0.aid == currentAid })
        let total = max(ugc.episodeCount, episodes.count)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                sheet = .ugcSeason
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 13))
                        .foregroundColor(.biliPink)
                    Text("合集 · \(ugc.title)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let index {
                        Text("\(index + 1)/\(total)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(episodes) { ep in
                            seasonChip(ep, selected: ep.aid == currentAid).id(ep.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onAppear {
                    if let index { proxy.scrollTo(episodes[index].id, anchor: .center) }
                }
            }
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground).opacity(0.6))
                .padding(.horizontal, 6)
        )
        .padding(.vertical, 4)
    }

    private func seasonChip(_ ep: UgcEpisode, selected: Bool) -> some View {
        Button {
            model.selectSeasonEpisode(ep)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(ep.title)
                    .font(.system(size: 13))
                    .foregroundColor(selected ? .biliPink : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if ep.duration > 0 {
                    Text(Fmt.duration(ep.duration))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .frame(width: 150, height: 64, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(.systemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.biliPink : Color(.separator).opacity(0.5), lineWidth: selected ? 1 : 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: Related

    @ViewBuilder
    private var relatedSection: some View {
        if !model.related.isEmpty {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.related) { card in
                    Button {
                        router.push(card.route ?? .video(card.videoRef))
                    } label: {
                        VideoRowCell(card: card)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        } else if !model.relatedLoaded {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
    }

    // MARK: PGC

    private func pgcContent(_ s: PGCSeason) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            pgcHeader(s)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            if s.userStatus.areaLimited {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                    Text("该番剧在当前地区不可播放")
                }
                .font(.system(size: 12))
                .foregroundColor(Color(.systemOrange))
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            if let ep = model.currentEpisode {
                Text("正在播放：\(ep.displayTitle)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            actionRow
                .padding(.top, 4)
            if !s.episodes.isEmpty {
                pgcEpisodeStrip(title: "选集", subtitle: s.newEpDesc, episodes: s.episodes, showsAll: true)
            }
            ForEach(s.sections.filter { !$0.episodes.isEmpty }) { section in
                pgcEpisodeStrip(title: section.title.isEmpty ? "其他" : section.title, subtitle: "",
                                episodes: section.episodes, showsAll: s.episodes.isEmpty)
            }
            if s.seasons.count > 1 {
                seasonsStrip(s)
            }
        }
        .padding(.bottom, 24)
    }

    private func pgcHeader(_ s: PGCSeason) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: s.cover, width: 96)
                .frame(width: 96, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                Text(s.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                if let rating = s.rating, rating.score > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.1f", rating.score))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(red: 1.0, green: 0.62, blue: 0.0))
                        Text("分")
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 1.0, green: 0.62, blue: 0.0))
                        if rating.count > 0 {
                            Text("\(Fmt.count(rating.count))人评")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Text(pgcStats(s))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(pgcMeta(s))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 2)
                HStack(spacing: 12) {
                    Button {
                        guard requireLogin() else { return }
                        Task { await model.toggleSeasonFollow() }
                    } label: {
                        Label(model.isFollowingSeason ? "已\(s.followVerb)" : s.followVerb,
                              systemImage: model.isFollowingSeason ? "heart.fill" : "heart")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(model.isFollowingSeason ? .secondary : .white)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(model.isFollowingSeason ? Color(.secondarySystemFill) : Color.biliPink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy.contains(.seasonFollow))
                    Button {
                        sheet = .pgcInfo
                    } label: {
                        HStack(spacing: 2) {
                            Text("简介")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        }
    }

    private func pgcStats(_ s: PGCSeason) -> String {
        var parts: [String] = []
        if s.stat.views > 0 { parts.append("\(Fmt.count(s.stat.views))播放") }
        if !s.stat.followText.isEmpty {
            parts.append(s.stat.followText)
        } else if s.stat.favorites > 0 {
            parts.append("\(Fmt.count(s.stat.favorites))\(s.followVerb)")
        }
        return parts.joined(separator: " · ")
    }

    private func pgcMeta(_ s: PGCSeason) -> String {
        [s.typeName, s.areas.joined(separator: "、"), s.newEpDesc]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func pgcEpisodeStrip(title: String, subtitle: String, episodes: [PGCEpisode], showsAll: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 14, weight: .medium))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if showsAll {
                    Button {
                        sheet = .pgcEpisodes
                    } label: {
                        HStack(spacing: 2) {
                            Text("全部")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(episodes) { ep in
                            Button {
                                model.selectEpisode(ep)
                            } label: {
                                VideoPGCEpisodeChip(episode: ep, isSelected: ep.epId == model.currentEpisode?.epId)
                            }
                            .buttonStyle(.plain)
                            .id(ep.epId)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onAppear {
                    if let id = model.currentEpisode?.epId, episodes.contains(where: { $0.epId == id }) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: model.currentEpisode?.epId) { id in
                    guard let id, episodes.contains(where: { $0.epId == id }) else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func seasonsStrip(_ s: PGCSeason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("系列")
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(s.seasons) { link in
                        seasonLinkChip(link, selected: link.seasonId == s.seasonId)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 10)
    }

    private func seasonLinkChip(_ link: PGCSeason.SeasonLink, selected: Bool) -> some View {
        Button {
            model.openSeason(link)
        } label: {
            Text(link.title.isEmpty ? "第\(link.seasonId)季" : link.title)
                .font(.system(size: 13))
                .foregroundColor(selected ? .biliPink : .primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .overlay(Capsule().stroke(selected ? Color.biliPink : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ item: VideoIntroSheet) -> some View {
        switch item {
        case .coin(let aid, let maxCoins, let given):
            VideoCoinSheet(maxCoins: maxCoins, given: given) { count, alsoLike in
                Task { await model.giveCoins(count, alsoLike: alsoLike, aid: aid) }
            }
        case .favorite(let rid, let type):
            VideoFavFolderSheet(rid: rid, resourceType: type) { favored in
                model.favoriteChanged(favored, rid: rid)
            }
        case .parts:
            if let d = model.detail {
                VideoPartPickerSheet(parts: d.pages, currentCid: model.currentCid) { part in
                    model.selectPart(part)
                }
            }
        case .ugcSeason:
            if let d = model.detail, let ugc = d.ugcSeason {
                VideoUgcSeasonSheet(season: ugc, currentAid: d.aid) { ep in
                    model.selectSeasonEpisode(ep)
                }
            }
        case .pgcEpisodes:
            if let s = model.season {
                VideoPGCEpisodeSheet(season: s, currentEpId: model.currentEpisode?.epId ?? 0) { ep in
                    model.selectEpisode(ep)
                }
            }
        case .pgcInfo:
            if let s = model.season {
                VideoPGCInfoSheet(season: s)
            }
        }
    }

    private func openCoin() {
        guard requireLogin() else { return }
        if model.relation.coinCount >= model.maxCoins {
            ToastCenter.shared.show("达到投币上限啦~")
            return
        }
        guard model.interactionAid > 0 else { return }
        sheet = .coin(aid: model.interactionAid, maxCoins: model.maxCoins, given: model.relation.coinCount)
    }

    private func openFavorite() {
        guard requireLogin() else { return }
        let resource = model.favoriteResource
        guard resource.rid > 0 else { return }
        sheet = .favorite(rid: resource.rid, type: resource.type)
    }

    // MARK: Helpers

    private func requireLogin() -> Bool {
        if BiliHTTP.shared.isLoggedIn { return true }
        router.push(.login)
        return false
    }

    private func copy(_ text: String, toast: String) {
        UIPasteboard.general.string = text
        ToastCenter.shared.show(toast)
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        switch VideoRichText.target(for: url) {
        case .seek(let t):
            onSeek(t)
            return .handled
        case .route(let route):
            router.push(route)
            return .handled
        case .system:
            return .systemAction
        case .ignore:
            return .discarded
        }
    }
}

// MARK: - Action row

/// 点赞 (tap; hold ≈1.4 s for 一键三连 with a ring on 点赞/投币/收藏) · 不喜欢 · 投币 · 收藏 · 稍后再看 · 分享.
struct VideoIntroActionRow: View {
    @ObservedObject var model: VideoDetailModel
    let requireLogin: () -> Bool
    let onCoin: () -> Void
    let onFavorite: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var router: TabRouter

    @State private var ring: CGFloat = 0
    @State private var pressing = false
    @State private var ringRunning = false
    @State private var tripleFired = false
    @State private var pressTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            likeItem
            dislikeItem
            Button(action: onCoin) {
                itemLabel(text: model.counts.coin > 0 ? Fmt.count(model.counts.coin) : "投币",
                          active: model.relation.coinCount > 0, ringed: true) {
                    VideoCoinGlyph(filled: model.relation.coinCount > 0)
                }
            }
            .buttonStyle(.plain)
            favoriteItem
            Button {
                guard requireLogin() else { return }
                Task { await model.toggleWatchLater() }
            } label: {
                itemLabel(text: "稍后再看", active: model.addedToWatchLater, ringed: false) {
                    Image(systemName: model.addedToWatchLater ? "clock.fill" : "clock")
                        .font(.system(size: 20))
                }
            }
            .buttonStyle(.plain)
            .disabled(model.busy.contains(.watchLater))
            shareItem
        }
        .padding(.horizontal, 4)
        .frame(height: 60)
    }

    private var likeItem: some View {
        itemLabel(text: model.counts.like > 0 ? Fmt.count(model.counts.like) : "点赞",
                  active: model.relation.liked, ringed: true) {
            Image(systemName: model.relation.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                .font(.system(size: 21))
        }
        .onTapGesture { tapLike() }
        .onLongPressGesture(minimumDuration: 1.4, maximumDistance: 16, perform: {
            tripleReached()
        }, onPressingChanged: { isPressing in
            pressingChanged(isPressing)
        })
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("长按一键三连")
    }

    /// 点踩: an app endpoint that needs the TV QR login's access_key (web logins are offered 去登录).
    private var dislikeItem: some View {
        Button {
            tapDislike()
        } label: {
            itemLabel(text: "不喜欢", active: model.relation.disliked, ringed: false) {
                Image(systemName: model.relation.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 21))
            }
        }
        .buttonStyle(.plain)
        .disabled(model.busy.contains(.dislike))
    }

    /// 收藏 opens the folder picker. With 「快速收藏」 a tap favourites into the default folder (or removes the
    /// favourite) and a long press opens the picker.
    @ViewBuilder
    private var favoriteItem: some View {
        let label = itemLabel(text: model.counts.favorite > 0 ? Fmt.count(model.counts.favorite) : "收藏",
                              active: model.relation.favored, ringed: true) {
            Image(systemName: model.relation.favored ? "star.fill" : "star")
                .font(.system(size: 21))
        }
        if settings.player.quickFavorite {
            label
                .onTapGesture { tapQuickFavorite() }
                .onLongPressGesture(minimumDuration: 0.5) { onFavorite() }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("长按选择收藏夹")
        } else {
            Button(action: onFavorite) { label }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var shareItem: some View {
        let label = itemLabel(text: model.counts.share > 0 ? Fmt.count(model.counts.share) : "分享",
                              active: false, ringed: false) {
            Image(systemName: "arrowshape.turn.up.right")
                .font(.system(size: 20))
        }
        if let url = model.shareURL {
            ShareLink(item: url, subject: Text(model.title), message: Text(model.title)) {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private func itemLabel<Icon: View>(text: String, active: Bool, ringed: Bool,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 4) {
            icon()
                .frame(width: 26, height: 26)
                .overlay(ringOverlay(ringed))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundColor(active ? .biliPink : Color.primary.opacity(0.75))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func ringOverlay(_ show: Bool) -> some View {
        if show {
            Circle()
                .trim(from: 0, to: ring)
                .stroke(Color.biliPink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 36, height: 36)
                .opacity(ring > 0.001 ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    private func tapLike() {
        guard requireLogin() else { return }
        Task { await model.toggleLike() }
    }

    private func tapDislike() {
        guard requireLogin() else { return }
        guard AuthService.shared.appAuth != nil else {
            let router = self.router
            ToastCenter.shared.show(VideoAPI.dislikeNeedsTVLoginMessage, duration: 3, actionTitle: "去登录") {
                router.push(.login)
            }
            return
        }
        Task { await model.toggleDislike() }
    }

    private func tapQuickFavorite() {
        guard requireLogin(), !model.busy.contains(.favorite) else { return }
        Task { await model.quickFavorite() }
    }

    /// Hold 200 ms → haptic and a 1.2 s ring; releasing early reverses it over 400 ms.
    private func pressingChanged(_ isPressing: Bool) {
        pressing = isPressing
        pressTask?.cancel()
        if isPressing {
            tripleFired = false
            guard BiliHTTP.shared.isLoggedIn else { return }
            pressTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, pressing else { return }
                ringRunning = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.linear(duration: 1.2)) { ring = 1 }
            }
        } else {
            if ringRunning && !tripleFired {
                withAnimation(.easeOut(duration: 0.4)) { ring = 0 }
            }
            ringRunning = false
        }
    }

    private func tripleReached() {
        pressTask?.cancel()
        tripleFired = true
        guard requireLogin() else {
            ring = 0
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        ring = 1
        Task { @MainActor in
            await model.triple()
            withAnimation(.easeOut(duration: 0.3)) { ring = 0 }
        }
    }
}

/// The 「币」 coin icon used by the action row.
struct VideoCoinGlyph: View {
    var filled: Bool

    var body: some View {
        ZStack {
            if filled {
                Circle().fill(Color.biliPink)
            } else {
                Circle().strokeBorder(lineWidth: 1.6)
            }
            Text("币")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(filled ? Color.white : nil)
        }
        .frame(width: 21, height: 21)
    }
}

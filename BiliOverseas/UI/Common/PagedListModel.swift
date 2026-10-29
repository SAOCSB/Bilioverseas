import SwiftUI

/// Generic infinite-scroll list state. `fetch` receives the previous page's `next` cursor
/// (nil for the first page). Items are de-duplicated by `id`.
@MainActor
final class PagedListModel<Item: Identifiable>: ObservableObject where Item.ID: Hashable {
    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    /// A page has arrived since the last `replace` (tells "not loaded yet" from "loaded, nothing to show").
    @Published private(set) var didLoad = false
    @Published var errorMessage: String?

    private var next: String?
    private var seen = Set<Item.ID>()
    private var generation = 0
    private let fetch: (String?) async throws -> Page<Item>
    /// Optional post-filter (e.g. FeedFilter) applied to every page.
    var filter: ((Item) -> Bool)?

    init(filter: ((Item) -> Bool)? = nil, fetch: @escaping (String?) async throws -> Page<Item>) {
        self.fetch = fetch
        self.filter = filter
    }

    var isEmpty: Bool { items.isEmpty }

    /// Reloads from the first page. `next` / `hasMore` are only replaced once the first page
    /// arrives, so a failed or cancelled refresh keeps paging from where the shown rows end.
    func refresh() async {
        generation += 1
        errorMessage = nil
        isLoading = false
        await load(reset: true)
    }

    /// First load only: a list that already loaded (even empty, e.g. everything filtered) is not
    /// re-requested every time it reappears; a failed first load is retried.
    func loadIfNeeded() async {
        if items.isEmpty && !isLoading && !didLoad { await load(reset: false) }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        await load(reset: false)
    }

    /// Call from a row's `.onAppear`; loads more when one of the last items appears.
    func onItemAppear(_ item: Item) {
        guard hasMore, !isLoading else { return }
        let tail = items.suffix(4).map(\.id)
        if tail.contains(item.id) { Task { await loadMore() } }
    }

    func remove(where predicate: (Item) -> Bool) {
        items.removeAll(where: predicate)
    }

    /// Replaces the rows (e.g. `replace([])` when the query changes): paging restarts from the first
    /// page and a page still in flight for the old rows is dropped.
    func replace(_ newItems: [Item]) {
        generation += 1
        items = newItems
        seen = Set(newItems.map(\.id))
        next = nil
        hasMore = true
        didLoad = !newItems.isEmpty
        isLoading = false
        errorMessage = nil
    }

    private func load(reset: Bool) async {
        isLoading = true
        let gen = generation
        var emptyStreak = 0
        do {
            var cursor = reset ? nil : next
            while true {
                let page = try await fetch(cursor)
                guard gen == generation else { return }
                if reset && cursor == nil {
                    items = []
                    seen = []
                }
                var fresh: [Item] = []
                for item in page.items where !seen.contains(item.id) {
                    if let filter, !filter(item) { continue }
                    seen.insert(item.id)
                    fresh.append(item)
                }
                items.append(contentsOf: fresh)
                next = page.next
                hasMore = page.hasMore
                didLoad = true
                // A fully filtered page should not stall infinite scroll.
                if fresh.isEmpty && page.hasMore && emptyStreak < 3 {
                    emptyStreak += 1
                    cursor = page.next
                    continue
                }
                break
            }
            errorMessage = nil
        } catch BiliError.cancelled {
        } catch is CancellationError {
        } catch {
            if gen == generation { errorMessage = error.localizedDescription }
        }
        if gen == generation { isLoading = false }
    }
}

/// Standard loading / error / empty footer for lists.
struct ListFooter: View {
    let isLoading: Bool
    let hasMore: Bool
    let isEmpty: Bool
    let error: String?
    var emptyText: String = "这里什么都没有"
    var retry: (() -> Void)?

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let retry { Button("重试", action: retry).buttonStyle(.bordered) }
                }
            } else if isLoading {
                ProgressView()
            } else if isEmpty && !(hasMore && retry != nil) {
                Text(emptyText).font(.footnote).foregroundStyle(.secondary)
            } else if !hasMore {
                Text("没有更多了").font(.caption).foregroundStyle(.tertiary)
            } else if let retry {
                // Normally the last rows' onAppear already started the next page. This is shown when
                // nothing will (e.g. several fully filtered pages in a row), so scrolling cannot stall.
                Button("加载更多", action: retry)
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

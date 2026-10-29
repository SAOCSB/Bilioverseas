import SwiftUI

/// Generic infinite-scroll list state. `fetch` receives the previous page's `next` cursor
/// (nil for the first page). Items are de-duplicated by `id`.
@MainActor
final class PagedListModel<Item: Identifiable>: ObservableObject where Item.ID: Hashable {
    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
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

    func refresh() async {
        generation += 1
        next = nil
        hasMore = true
        errorMessage = nil
        isLoading = false
        await load(reset: true)
    }

    func loadIfNeeded() async {
        if items.isEmpty && !isLoading { await load(reset: false) }
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

    func replace(_ newItems: [Item]) {
        items = newItems
        seen = Set(newItems.map(\.id))
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
            } else if isEmpty {
                Text(emptyText).font(.footnote).foregroundStyle(.secondary)
            } else if !hasMore {
                Text("没有更多了").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

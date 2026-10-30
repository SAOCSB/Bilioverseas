import SwiftUI
import UIKit

/// Full-screen vertical pages, one swipe per page: the frame of the 短视频 feed. SwiftUI's paging
/// `ScrollView` needs iOS 17, so this wraps a paging `UICollectionView` whose cells host SwiftUI
/// pages (`UIHostingConfiguration`, iOS 16). Cells are reused, so pages must not own their players.
struct ShortVideoPager<Item: Identifiable, Page: View>: UIViewRepresentable {
    let items: [Item]
    /// The page fully on screen. Set by swiping; setting it scrolls there.
    @Binding var index: Int
    /// A drag at the last page (more pages may be wanted, e.g. after a failed load).
    var onReachEnd: () -> Void = {}
    let page: (Item, Int) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PagingCollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        let view = PagingCollectionView(frame: .zero, collectionViewLayout: layout)
        view.isPagingEnabled = true
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.scrollsToTop = false
        view.backgroundColor = .black
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Coordinator.reuseID)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.currentPage = { [weak coordinator = context.coordinator] in coordinator?.current ?? 0 }
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: PagingCollectionView, context: Context) {
        let coordinator = context.coordinator
        let oldIDs = coordinator.ids
        coordinator.parent = self
        coordinator.ids = items.map { AnyHashable($0.id) }
        if oldIDs != coordinator.ids, oldIDs.isEmpty || !coordinator.ids.starts(with: oldIDs) {
            view.reloadData()
            coordinator.current = min(index, max(items.count - 1, 0))
            view.layoutIfNeeded()
            view.scrollTo(page: coordinator.current, animated: false)
        } else {
            if oldIDs != coordinator.ids {
                // Appended a page of results: insert without disturbing the page on screen.
                let added = (oldIDs.count..<coordinator.ids.count).map { IndexPath(item: $0, section: 0) }
                view.performBatchUpdates { view.insertItems(at: added) }
            }
            // The items on screen (or SwiftUI state their pages read) may have changed; refresh them in place.
            for cell in view.visibleCells {
                if let path = view.indexPath(for: cell) { coordinator.configure(cell, at: path) }
            }
        }
        // While a swipe's page is still being published, the binding still holds the page it left.
        if let pending = coordinator.pendingIndex, index != pending { return }
        if index != coordinator.current, items.indices.contains(index) {
            coordinator.current = index
            view.scrollTo(page: index, animated: true)
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        static var reuseID: String { "page" }
        var parent: ShortVideoPager
        var ids: [AnyHashable] = []
        var current = 0
        /// The page a swipe settled on, until the binding has it.
        var pendingIndex: Int?
        weak var view: PagingCollectionView?

        init(_ parent: ShortVideoPager) { self.parent = parent }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.items.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Coordinator.reuseID, for: indexPath)
            configure(cell, at: indexPath)
            return cell
        }

        func configure(_ cell: UICollectionViewCell, at indexPath: IndexPath) {
            guard parent.items.indices.contains(indexPath.item) else { return }
            let item = parent.items[indexPath.item]
            // The identity keeps a reused cell from handing one video's @State (first frame, hearts…) to the next.
            cell.contentConfiguration = UIHostingConfiguration { parent.page(item, indexPath.item).id(AnyHashable(item.id)) }
                .margins(.all, 0)
                .background(Color.black)
        }

        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            collectionView.bounds.size
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle(scrollView) }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle(scrollView) }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { settle(scrollView) }
            if current == parent.items.count - 1 { parent.onReachEnd() }
        }

        private func settle(_ scrollView: UIScrollView) {
            let height = scrollView.bounds.height
            guard height > 0 else { return }
            let page = Int((scrollView.contentOffset.y / height).rounded())
            guard page != current, parent.items.indices.contains(page) else { return }
            current = page
            pendingIndex = page
            // Not during a SwiftUI update: publish on the next turn of the run loop.
            DispatchQueue.main.async { [weak self, parent] in
                parent.index = page
                if self?.pendingIndex == page { self?.pendingIndex = nil }
            }
        }
    }
}

/// Keeps the current page in place when the size changes (rotation, split view), which would
/// otherwise leave the offset between two pages.
final class PagingCollectionView: UICollectionView {
    var currentPage: () -> Int = { 0 }
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        if bounds.size != lastSize, bounds.height > 0 {
            lastSize = bounds.size
            collectionViewLayout.invalidateLayout()
            super.layoutSubviews()
            scrollTo(page: currentPage(), animated: false)
        } else {
            super.layoutSubviews()
        }
    }

    func scrollTo(page: Int, animated: Bool) {
        guard page >= 0, page < numberOfItems(inSection: 0), bounds.height > 0 else { return }
        setContentOffset(CGPoint(x: 0, y: CGFloat(page) * bounds.height), animated: animated)
    }
}

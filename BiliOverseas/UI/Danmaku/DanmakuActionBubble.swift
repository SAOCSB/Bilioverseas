import UIKit

/// The 「点击弹幕」 action bubble (features.md §8.6): a dark capsule with a pointer at the frozen danmaku, holding
/// 点赞 (with the like count), 复制, 举报 — or 撤回 for own danmaku —, 屏蔽 and, when the text names a time,
/// 跳转. `PlayerSurfaceView` places it and performs the actions.
final class DanmakuActionBubbleView: UIView {
    enum Action {
        case like, copy, report, recall, block
        case seek(Double)
    }

    var onAction: ((Action) -> Void)?

    static let itemSize = CGSize(width: 40, height: 29.4)
    static let pointerHeight: CGFloat = 5.6
    static let margin: CGFloat = 5
    /// Space between the danmaku and the pointer tip.
    static let gap: CGFloat = 2

    private let shape = CAShapeLayer()
    private let stack = UIStackView()
    private var pointerX: CGFloat = 0
    /// The bubble hangs under the danmaku (pointer on top); above it when there is no room below.
    private var pointerOnTop = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shape.fillColor = UIColor(white: 0, alpha: 0.7).cgColor
        shape.strokeColor = UIColor(white: 1, alpha: 0.5).cgColor
        shape.lineWidth = 1.25
        layer.addSublayer(shape)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        addSubview(stack)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Rebuilds the buttons for `item`. `seekTarget` (seconds) adds 跳转.
    func configure(item: DanmakuItem, like: DanmakuLikeState, seekTarget: Double?) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if item.hasServerID {
            let button = makeButton(like.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                                    label: like.liked ? "取消点赞" : "点赞", action: .like)
            if like.liked { button.tintColor = UIColor(red: 0.984, green: 0.447, blue: 0.6, alpha: 1) }
            if like.count > 0 {
                let count = UILabel()
                count.text = like.count > 9999 ? "9999+" : "\(like.count)"
                count.font = UIFont.systemFont(ofSize: 10.5, weight: .medium)
                count.textColor = .white
                count.sizeToFit()
                count.frame.origin = CGPoint(x: DanmakuActionBubbleView.itemSize.width - 13, y: 0)
                count.isUserInteractionEnabled = false
                button.addSubview(count)
            }
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(makeButton("doc.on.doc", label: "复制", action: .copy))
        if item.hasServerID {
            stack.addArrangedSubview(item.isSelf
                ? makeButton("arrow.uturn.backward", label: "撤回", action: .recall)
                : makeButton("exclamationmark.bubble", label: "举报", action: .report))
        }
        if !item.isSelf {
            stack.addArrangedSubview(makeButton("nosign", label: "屏蔽", action: .block))
        }
        if let seekTarget {
            stack.addArrangedSubview(makeButton("scope", label: "跳转到 \(PlayerFormat.time(seekTarget))",
                                                action: .seek(seekTarget)))
        }
    }

    var preferredSize: CGSize {
        CGSize(width: CGFloat(stack.arrangedSubviews.count) * DanmakuActionBubbleView.itemSize.width + 12,
               height: DanmakuActionBubbleView.itemSize.height + DanmakuActionBubbleView.pointerHeight)
    }

    /// Positions the bubble for a danmaku at `anchor` (in `container` coordinates), the pointer at `pointX`
    /// (the tap) clamped to the danmaku.
    func place(anchor: CGRect, pointX: CGFloat, in container: CGRect) {
        let size = preferredSize
        let m = DanmakuActionBubbleView.margin
        let below = anchor.maxY + DanmakuActionBubbleView.gap
        pointerOnTop = below + size.height <= container.maxY - m
        let y = pointerOnTop ? below : max(container.minY + m, anchor.minY - DanmakuActionBubbleView.gap - size.height)
        let target = min(max(pointX, anchor.minX), anchor.maxX)
        let x = min(max(target - size.width / 2, container.minX + m), max(container.minX + m, container.maxX - m - size.width))
        frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        let r = DanmakuActionBubbleView.itemSize.height / 2
        let inset = r + DanmakuActionBubbleView.pointerHeight
        pointerX = min(max(target - x, inset), max(inset, size.width - inset))
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let ph = DanmakuActionBubbleView.pointerHeight
        let body = CGRect(x: 0, y: pointerOnTop ? ph : 0, width: bounds.width,
                          height: max(0, bounds.height - ph))
        shape.frame = bounds
        shape.path = DanmakuActionBubbleView.outline(body: body.insetBy(dx: 0.625, dy: 0.625), pointerX: pointerX,
                                                     pointerHeight: ph, pointerOnTop: pointerOnTop).cgPath
        stack.frame = body.insetBy(dx: 6, dy: 0)
    }

    /// Capsule with a triangular pointer on its top or bottom edge, as one outline (so the border has no seam).
    private static func outline(body: CGRect, pointerX px: CGFloat, pointerHeight ph: CGFloat,
                                pointerOnTop: Bool) -> UIBezierPath {
        let r = body.height / 2
        let p = UIBezierPath()
        p.move(to: CGPoint(x: body.minX + r, y: body.minY))
        if pointerOnTop {
            p.addLine(to: CGPoint(x: px - ph, y: body.minY))
            p.addLine(to: CGPoint(x: px, y: body.minY - ph))
            p.addLine(to: CGPoint(x: px + ph, y: body.minY))
        }
        p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        p.addArc(withCenter: CGPoint(x: body.maxX - r, y: body.midY), radius: r,
                 startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
        if !pointerOnTop {
            p.addLine(to: CGPoint(x: px + ph, y: body.maxY))
            p.addLine(to: CGPoint(x: px, y: body.maxY + ph))
            p.addLine(to: CGPoint(x: px - ph, y: body.maxY))
        }
        p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        p.addArc(withCenter: CGPoint(x: body.minX + r, y: body.midY), radius: r,
                 startAngle: .pi / 2, endAngle: .pi * 3 / 2, clockwise: true)
        p.close()
        return p
    }

    private func makeButton(_ systemName: String, label: String, action: Action) -> UIButton {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.setImage(UIImage(systemName: systemName, withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = label
        button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        return button
    }
}

/// Finding a view controller to present the bubble's follow-up sheets (举报 reasons, 屏蔽 choices) from.
extension UIView {
    /// The top-most view controller presented over the one hosting this view.
    var danmakuPresentingViewController: UIViewController? {
        var responder: UIResponder? = self
        while let r = responder, !(r is UIViewController) { responder = r.next }
        guard var vc = responder as? UIViewController else { return nil }
        while let presented = vc.presentedViewController, !presented.isBeingDismissed { vc = presented }
        return vc
    }
}

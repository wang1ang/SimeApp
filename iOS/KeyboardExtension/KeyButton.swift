import UIKit

final class KeyButton: UIButton, UIInputViewAudioFeedback {
    // playInputClick only sounds when a visible input view (or the pressed
    // responder) opts in; it then follows the system Keyboard Clicks setting.
    var enableInputClicksWhenVisible: Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        UIDevice.current.playInputClick()
    }
    // Keep visual feedback in a non-interactive layer so the button's hit
    // geometry never changes during the press animation.
    private let feedbackView = UIView()
    private var syncingBackground = false
    private var settingPressFeedbackColor = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupFeedbackView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFeedbackView()
    }

    private func setupFeedbackView() {
        feedbackView.isUserInteractionEnabled = false
        feedbackView.backgroundColor = backgroundColor
        feedbackView.layer.cornerRadius = 10
        insertSubview(feedbackView, at: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        feedbackView.bounds = bounds
        feedbackView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override var backgroundColor: UIColor? {
        didSet {
            guard !syncingBackground else { return }
            if isHighlighted && !settingPressFeedbackColor {
                restingBackground = backgroundColor
            }
            feedbackView.backgroundColor = backgroundColor
            syncingBackground = true
            super.backgroundColor = .clear
            syncingBackground = false
        }
    }

    // Expand into horizontal gaps; vertical gaps lie outside the row bounds.
    var hitInset = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)

    // Background to restore when the press ends; captured on first highlight so
    // callers can keep setting backgroundColor normally (e.g. armed Shift).
    private var restingBackground: UIColor?
    private var suppressHighlightAnimation = false

    private func setHighlight(_ highlighted: Bool, animated: Bool) {
        suppressHighlightAnimation = !animated
        isHighlighted = highlighted
        suppressHighlightAnimation = false
    }
    private weak var draggedKey: KeyButton?

    // Apply press feedback synchronously so hit testing stays stable.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if isHighlighted {
                restingBackground = feedbackView.backgroundColor
                settingPressFeedbackColor = true
                backgroundColor = Self.pressedBackground
                settingPressFeedbackColor = false
                feedbackView.transform = Self.pressedTransform(for: bounds.size)
            } else {
                backgroundColor = restingBackground
                if suppressHighlightAnimation {
                    feedbackView.transform = .identity
                } else {
                    UIView.animate(withDuration: 0.12) {
                        self.feedbackView.transform = .identity
                    }
                }
            }
        }
    }

    // Darker than the key in light mode, lighter in dark mode, but gentle.
    private static let pressedBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGray3 : .systemGray4
    }

    private static let pressInset: CGFloat = 2
    private static func pressedTransform(for size: CGSize) -> CGAffineTransform {
        guard size.width > 0, size.height > 0 else { return .identity }
        let sx = max(0, (size.width - 2 * pressInset) / size.width)
        let sy = max(0, (size.height - 2 * pressInset) / size.height)
        return CGAffineTransform(scaleX: sx, y: sy)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let window else {
            super.touchesMoved(touches, with: event)
            return
        }
        super.touchesMoved(touches, with: event)
        let target = window.hitTest(touch.location(in: window), with: event) as? KeyButton
        draggedKey?.setHighlight(false, animated: false)
        setHighlight(false, animated: false)
        draggedKey = nil
        if let target, target.isEnabled {
            if target === self {
                setHighlight(true, animated: false)
            } else {
                target.setHighlight(true, animated: false)
                draggedKey = target
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let window else {
            super.touchesEnded(touches, with: event)
            return
        }
        let endPoint = touch.location(in: window)
        let target = window.hitTest(endPoint, with: event) as? KeyButton
        if let target, target !== self, target.isEnabled {
            releaseOnto(target)
            return
        }
        draggedKey?.setHighlight(false, animated: false)
        draggedKey = nil
        super.touchesEnded(touches, with: event)
    }

    // The finger finished on another key: that key fires instead. The source
    // still gets touchUpOutside so its press ends (⌫ repeat must stop).
    // Known limitation: the target gets no .touchDown, so sliding onto ⌫ doesn't delete.
    func releaseOnto(_ target: KeyButton) {
        setHighlight(false, animated: false)
        sendActions(for: .touchUpOutside)
        target.sendActions(for: .touchUpInside)
        target.setHighlight(false, animated: true)
        draggedKey = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        draggedKey?.setHighlight(false, animated: false)
        draggedKey = nil
        super.touchesCancelled(touches, with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.inset(by: UIEdgeInsets(top: -hitInset.top, left: -hitInset.left,
                                     bottom: -hitInset.bottom, right: -hitInset.right))
            .contains(point)
    }
}

// UIKit checks the visible input view for input-click opt-in.
extension UIInputView: @retroactive UIInputViewAudioFeedback {
    public var enableInputClicksWhenVisible: Bool { true }
}

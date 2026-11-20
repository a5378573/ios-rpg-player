import UIKit

/// 游戏内的虚拟手柄。
///
/// 为什么是 UIKit 而不是 SwiftUI：引擎跑起来之后会**占住主线程**，
/// SwiftUI 的 diff 和渲染都停了，只有 SDL 自己泵的 UIKit 事件循环还在转。
/// 所以覆盖层必须是纯 UIKit 视图，直接挂到引擎的 UIWindow 上。
final class GamepadOverlayView: UIView {

    var onKey: ((Int32, Bool) -> Void)?
    var onRequestExit: (() -> Void)?
    var onLayoutChanged: ((ControlLayout) -> Void)?

    private(set) var layout: ControlLayout
    private var buttonViews: [UUID: GamepadButtonView] = [:]
    private var isEditing = false

    private let editButton = UIButton(type: .system)
    private let exitButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    init(layout: ControlLayout) {
        self.layout = layout
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        buildToolbar()
        rebuildButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 触摸穿透

    /// 空白区域的触摸必须放过去，否则手柄会吃掉整块屏幕。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for subview in subviews where subview.isUserInteractionEnabled && !subview.isHidden {
            if subview.frame.contains(point) { return true }
        }
        return false
    }

    // MARK: - 构建

    private func buildToolbar() {
        for button in [editButton, exitButton, doneButton] {
            button.tintColor = .white
            button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            button.layer.cornerRadius = 17
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
            button.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
            addSubview(button)
        }

        editButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        editButton.addTarget(self, action: #selector(toggleEditing), for: .touchUpInside)

        exitButton.setImage(UIImage(systemName: "rectangle.portrait.and.arrow.right"), for: .normal)
        exitButton.addTarget(self, action: #selector(requestExit), for: .touchUpInside)

        doneButton.setImage(UIImage(systemName: "checkmark"), for: .normal)
        doneButton.addTarget(self, action: #selector(toggleEditing), for: .touchUpInside)
        doneButton.isHidden = true
    }

    private func rebuildButtons() {
        for view in buttonViews.values {
            view.removeFromSuperview()
        }
        buttonViews.removeAll()

        for button in layout.buttons where button.isVisible {
            let view = GamepadButtonView(button: button)
            view.alpha = CGFloat(button.opacity * layout.globalOpacity)
            view.onDown = { [weak self] in
                guard let self, !self.isEditing else { return }
                if let code = Scancode.code(for: button.function, custom: button.customKey) {
                    self.onKey?(code, true)
                }
            }
            view.onUp = { [weak self] in
                guard let self, !self.isEditing else { return }
                if let code = Scancode.code(for: button.function, custom: button.customKey) {
                    self.onKey?(code, false)
                }
            }
            view.onMoved = { [weak self] center in
                self?.moveButton(button.id, to: center)
            }
            addSubview(view)
            buttonViews[button.id] = view
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let safe = safeAreaInsets
        let toolbarY = safe.top + 8
        var x = bounds.width - safe.right - 42
        exitButton.frame = CGRect(x: x, y: toolbarY, width: 34, height: 34)
        x -= 42
        editButton.frame = CGRect(x: x, y: toolbarY, width: 34, height: 34)
        exitButton.isHidden = isEditing
        editButton.isHidden = isEditing
        doneButton.frame = exitButton.frame
        doneButton.isHidden = !isEditing

        for button in layout.buttons where button.isVisible {
            guard let view = buttonViews[button.id] else { continue }
            let size = CGFloat(button.size)
            view.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            view.center = CGPoint(x: CGFloat(button.x) * bounds.width,
                                  y: CGFloat(button.y) * bounds.height)
            view.layer.cornerRadius = size / 2
        }
    }

    // MARK: - 编辑

    @objc private func toggleEditing() {
        isEditing.toggle()
        for view in buttonViews.values {
            view.isEditing = isEditing
        }
        setNeedsLayout()
    }

    private func moveButton(_ id: UUID, to center: CGPoint) {
        guard isEditing,
              let index = layout.buttons.firstIndex(where: { $0.id == id }) else { return }
        // 夹在屏幕内，避免按钮被拖到刘海或完全出界
        let clampedX = min(max(center.x / bounds.width, 0.04), 0.96)
        let clampedY = min(max(center.y / bounds.height, 0.06), 0.96)
        layout.buttons[index].x = Double(clampedX)
        layout.buttons[index].y = Double(clampedY)
        onLayoutChanged?(layout)
    }

    @objc private func requestExit() {
        onRequestExit?()
    }
}

// MARK: - 单个按键

/// 支持多指的圆形按键：按住持续有效，抬起或取消才释放。
final class GamepadButtonView: UIView {

    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onMoved: ((CGPoint) -> Void)?

    var isEditing = false {
        didSet { updateAppearance() }
    }

    private let label = UILabel()
    private let button: VirtualButton
    private var isPressed = false
    private var dragOffset: CGPoint = .zero
    private var isDragging = false

    init(button: VirtualButton) {
        self.button = button
        super.init(frame: .zero)
        isMultipleTouchEnabled = false   // 每个按键单独跟踪自己的那根手指
        isUserInteractionEnabled = true

        label.text = button.effectiveLabel
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 19, weight: .semibold)
        label.isUserInteractionEnabled = false
        addSubview(label)

        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        backgroundColor = UIColor.black.withAlphaComponent(0.3)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        label.font = .systemFont(ofSize: max(14, bounds.width * 0.34), weight: .semibold)
    }

    private func updateAppearance() {
        layer.borderColor = isEditing
            ? UIColor.systemBlue.withAlphaComponent(0.9).cgColor
            : UIColor.white.withAlphaComponent(isPressed ? 0.85 : 0.4).cgColor
        backgroundColor = UIColor.black.withAlphaComponent(isPressed ? 0.55 : 0.3)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if isEditing {
            isDragging = true
            let point = touch.location(in: superview)
            dragOffset = CGPoint(x: center.x - point.x, y: center.y - point.y)
            return
        }
        isPressed = true
        updateAppearance()
        onDown?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEditing, isDragging, let touch = touches.first else { return }
        let point = touch.location(in: superview)
        center = CGPoint(x: point.x + dragOffset.x, y: point.y + dragOffset.y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing {
            if isDragging { isDragging = false; onMoved?(center) }
            return
        }
        release()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing { isDragging = false; return }
        release()
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        updateAppearance()
        onUp?()
    }
}

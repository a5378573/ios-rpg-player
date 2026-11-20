import Foundation

/// 虚拟按键可以承载的功能。自定义按键用 `.custom` + `customKey`。
enum GameKey: String, Codable, CaseIterable, Identifiable {
    case up
    case down
    case left
    case right
    case confirm
    case cancel
    case menu
    case shift
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .up: return "上"
        case .down: return "下"
        case .left: return "左"
        case .right: return "右"
        case .confirm: return "确认"
        case .cancel: return "取消"
        case .menu: return "主页"
        case .shift: return "加速"
        case .custom: return "自定义"
        }
    }

    /// 默认显示的字形
    var defaultLabel: String {
        switch self {
        case .up: return "▲"
        case .down: return "▼"
        case .left: return "◀"
        case .right: return "▶"
        case .confirm: return "A"
        case .cancel: return "B"
        case .menu: return "≡"
        case .shift: return "⇧"
        case .custom: return "★"
        }
    }
}

/// 一个可拖动、可缩放的虚拟按键。
struct VirtualButton: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var function: GameKey = .confirm
    /// 当 function == .custom 时，映射到的键盘按键，例如 "A" / "F5" / "Space"
    var customKey: String = "A"
    var label: String = "A"
    /// 归一化坐标，0...1，相对于游戏画面
    var x: Double = 0.5
    var y: Double = 0.5
    /// 直径，单位 pt
    var size: Double = 56
    var opacity: Double = 0.75
    var isVisible: Bool = true

    var effectiveLabel: String {
        label.isEmpty ? function.defaultLabel : label
    }
}

/// 一套按键布局，按游戏保存。
struct ControlLayout: Codable, Equatable {
    var buttons: [VirtualButton]
    /// 全局透明度倍率
    var globalOpacity: Double = 1.0
    /// 是否显示虚拟键盘
    var isEnabled: Bool = true

    static var `default`: ControlLayout {
        ControlLayout(buttons: [
            VirtualButton(function: .up,    label: "▲", x: 0.105, y: 0.60, size: 58),
            VirtualButton(function: .down,  label: "▼", x: 0.105, y: 0.88, size: 58),
            VirtualButton(function: .left,  label: "◀", x: 0.048, y: 0.74, size: 58),
            VirtualButton(function: .right, label: "▶", x: 0.162, y: 0.74, size: 58),

            VirtualButton(function: .confirm, label: "A", x: 0.930, y: 0.80, size: 64),
            VirtualButton(function: .cancel,  label: "B", x: 0.845, y: 0.89, size: 56),
            VirtualButton(function: .menu,    label: "≡", x: 0.930, y: 0.60, size: 50),
            VirtualButton(function: .shift,   label: "⇧", x: 0.845, y: 0.60, size: 50)
        ])
    }
}

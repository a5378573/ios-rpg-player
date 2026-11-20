import Foundation

/// 键盘扫描码（USB HID Usage Page 0x07）。
///
/// mkxp 的输入层直接吃这套码，不做二次翻译，所以虚拟手柄按下时
/// 只需要注入对应的数字。这些值和引擎的 `MKXP_SCANCODE_*` 一一对应，
/// 但不在 Swift 里 import app_bridge.h，保持头文件隔离。
enum Scancode {
    // 方向键
    static let up: Int32 = 82
    static let down: Int32 = 81
    static let left: Int32 = 80
    static let right: Int32 = 79

    // 常用
    static let ret: Int32 = 40
    static let escape: Int32 = 41
    static let space: Int32 = 44
    static let tab: Int32 = 43
    static let backspace: Int32 = 42
    static let lshift: Int32 = 225
    static let lctrl: Int32 = 224
    static let lalt: Int32 = 226

    /// 功能键到 mkxp 默认动作的映射。
    ///
    /// mkxp 的默认绑定（RPG Maker 习惯）：
    ///   C（确认） = Enter / Space / Z
    ///   B（取消） = Esc / X / 小键盘 0
    ///   A         = Shift
    ///   X         = A
    ///   Y         = S
    ///   Z         = D
    ///   L / R     = Q、W（翻页）
    /// 所以「确认」发 Return、「取消」发 Esc 就与桌面一致。
    static func code(for key: GameKey, custom: String? = nil) -> Int32? {
        switch key {
        case .up:      return up
        case .down:    return down
        case .left:    return left
        case .right:   return right
        case .confirm: return ret
        case .cancel:  return escape
        // 「主页」是玩家习惯里的菜单键。RPG Maker 里菜单由 B 打开，
        // 但 B 已经是取消；X 在 mkxp 里是独立动作键，多数游戏用不上，
        // 拿来做菜单/加速不会误触。
        case .menu:    return 27   // X
        case .shift:   return lshift
        case .custom:  return code(forCustom: custom)
        }
    }

    /// 把 "A" / "F5" / "Space" / "hid:82" 这类写法转成扫描码。
    static func code(forCustom raw: String?) -> Int32? {
        guard let raw else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        // 直接写数字：hid:82
        if token.lowercased().hasPrefix("hid:") {
            let number = token.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if let value = Int(number), (0...255).contains(value) {
                return Int32(value)
            }
            return nil
        }

        // 单字母
        if token.count == 1, let scalar = token.uppercased().unicodeScalars.first {
            let upper = Character(scalar)
            if upper >= "A", upper <= "Z",
               let ascii = upper.asciiValue {
                // HID 里 A = 4，依次递增
                return Int32(Int(ascii) - Int(Character("A").asciiValue!) + 4)
            }
            if upper >= "0", upper <= "9",
               let ascii = upper.asciiValue {
                // 1..9 = 30..38，0 = 39
                if upper == "0" { return 39 }
                return Int32(Int(ascii) - Int(Character("0").asciiValue!) + 29)
            }
        }

        // F1...F12
        let upperToken = token.uppercased()
        if upperToken.hasPrefix("F"), let number = Int(upperToken.dropFirst()),
           (1...12).contains(number) {
            return Int32(57 + number)   // F1 = 58
        }

        switch upperToken {
        case "SPACE", "空格":        return space
        case "ENTER", "RETURN", "回车": return ret
        case "ESC", "ESCAPE", "取消":  return escape
        case "TAB":                 return tab
        case "BACKSPACE":           return backspace
        case "SHIFT":               return lshift
        case "CTRL", "CONTROL":     return lctrl
        case "ALT", "OPTION":       return lalt
        case "MINUS", "-":          return 45
        case "EQUALS", "=":         return 46
        case "LEFTBRACKET", "[":    return 47
        case "RIGHTBRACKET", "]":   return 48
        case "BACKSLASH", "\\":     return 49
        case "SEMICOLON", ";":      return 51
        case "APOSTROPHE", "'":     return 52
        case "GRAVE", "`":          return 53
        case "COMMA", ",":          return 54
        case "PERIOD", ".":         return 55
        case "SLASH", "/":          return 56
        default:                    return nil
        }
    }

    /// 给设置界面用的预设列表。
    static let commonCustomKeys: [String] = [
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
        "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
        "Space", "Enter", "Esc", "Shift", "Ctrl", "Tab",
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"
    ]
}

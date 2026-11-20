import Foundation

/// RPG Maker 各代引擎，以及它们在本 App 中使用的运行时。
enum EngineType: String, Codable, CaseIterable, Identifiable {
    case rpgMaker2000
    case rpgMaker2003
    case rpgMakerXP
    case rpgMakerVX
    case rpgMakerVXAce
    case rpgMakerMV
    case rpgMakerMZ
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rpgMaker2000: return "RPG Maker 2000"
        case .rpgMaker2003: return "RPG Maker 2003"
        case .rpgMakerXP:   return "RPG Maker XP"
        case .rpgMakerVX:   return "RPG Maker VX"
        case .rpgMakerVXAce: return "RPG Maker VX Ace"
        case .rpgMakerMV:   return "RPG Maker MV"
        case .rpgMakerMZ:   return "RPG Maker MZ"
        case .unknown:      return "未知引擎"
        }
    }

    /// 这个引擎由哪个运行时承载。
    var runtimeName: String {
        switch self {
        case .rpgMaker2000, .rpgMaker2003:
            return "EasyRPG"
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            return "mkxp-z"
        case .rpgMakerMV, .rpgMakerMZ:
            return "WebView"
        case .unknown:
            return "未识别"
        }
    }

    var isWebBased: Bool {
        self == .rpgMakerMV || self == .rpgMakerMZ
    }

    var isRGSS: Bool {
        switch self {
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce: return true
        default: return false
        }
    }

    var isEasyRPG: Bool {
        self == .rpgMaker2000 || self == .rpgMaker2003
    }

    /// 用于界面标记的缩写
    var shortTag: String {
        switch self {
        case .rpgMaker2000: return "2K"
        case .rpgMaker2003: return "2K3"
        case .rpgMakerXP: return "XP"
        case .rpgMakerVX: return "VX"
        case .rpgMakerVXAce: return "VA"
        case .rpgMakerMV: return "MV"
        case .rpgMakerMZ: return "MZ"
        case .unknown: return "?"
        }
    }
}

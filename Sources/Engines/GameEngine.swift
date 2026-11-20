import UIKit

/// 所有运行时的统一接口。视图由引擎自己持有，播放器只负责嵌进去。
///
/// 目前只有 MV / MZ 走这个协议（WKWebView，跑在 SwiftUI 里）。
/// XP / VX / VX Ace 走 MkxpSession：原生引擎会接管主线程，
/// SwiftUI 在此期间不再刷新，因此两者不能共用同一套视图生命周期。
@MainActor
protocol GameEngine: AnyObject {
    var view: UIView { get }
    func start() throws
    func stop()
    func press(_ key: GameKey, custom: String?)
    func release(_ key: GameKey, custom: String?)
}

/// 引擎尚未接入或无法启动时的占位实现，避免玩家点进去直接崩。
@MainActor
final class UnavailableEngine: GameEngine {
    private let container = UIView()

    init(message: String) {
        container.backgroundColor = .black

        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
    }

    var view: UIView { container }
    func start() throws {}
    func stop() {}
    func press(_ key: GameKey, custom: String?) {}
    func release(_ key: GameKey, custom: String?) {}
}

@MainActor
enum EngineFactory {
    /// 返回游戏画面在游戏目录中的入口相对路径（MV/MZ 用）。
    static func webEntryPath(for game: Game) -> String? {
        let root = FileLocations.gameFolder(game)
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("index.html").path) {
            return "index.html"
        }
        if fm.fileExists(atPath: root.appendingPathComponent("www/index.html").path) {
            return "www/index.html"
        }
        return nil
    }

    /// 只有 Web 类引擎走这里。原生引擎由 GamePlayerView 单独调度。
    static func makeEngine(for game: Game) throws -> GameEngine {
        switch game.engine {
        case .rpgMakerMV, .rpgMakerMZ:
            guard let entry = webEntryPath(for: game) else {
                return UnavailableEngine(message: "没有找到 index.html，游戏文件可能不完整。\n请重新导入包含 www 目录的完整游戏包。")
            }
            return WebGameEngine(gameRoot: FileLocations.gameFolder(game), entryPath: entry)

        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            // 原生引擎在 GamePlayerView 里通过 MkxpSession 启动
            return UnavailableEngine(message: "\(game.engine.displayName) 由原生引擎启动。")

        case .rpgMaker2000, .rpgMaker2003:
            return UnavailableEngine(message: """
            \(game.engine.displayName) 需要 EasyRPG Player。

            EasyRPG 官方至今没有维护 iOS 目标（作者原话是「唯一还没真正支持的平台」），
            要接入得自己写平台层。这个版本先只提供 XP / VX / VX Ace 与 MV / MZ。
            """)

        case .unknown:
            return UnavailableEngine(message: "未识别的引擎，无法启动。")
        }
    }
}

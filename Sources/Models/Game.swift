import Foundation

struct Game: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// 游戏目录名，位于 Documents/Games 下
    var folderName: String
    var engine: EngineType
    /// 封面文件名，位于游戏目录内
    var coverFileName: String?
    var addedAt: Date = Date()
    var lastPlayedAt: Date?
    var playSeconds: Double = 0
    var layout: ControlLayout = .default
    var translationEnabled: Bool = false
    /// 传给运行时的附加参数
    var launchArguments: String = ""
    /// 是否隐藏
    var isHidden: Bool = false

    var relativeFolderPath: String { folderName }
}

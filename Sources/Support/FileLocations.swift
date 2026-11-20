import Foundation

enum FileLocations {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var gamesRoot: URL {
        documents.appendingPathComponent("Games", isDirectory: true)
    }

    static var importsRoot: URL {
        documents.appendingPathComponent("Imports", isDirectory: true)
    }

    static var libraryFile: URL {
        documents.appendingPathComponent("library.json")
    }

    static func gameFolder(_ game: Game) -> URL {
        gamesRoot.appendingPathComponent(game.folderName, isDirectory: true)
    }

    static func coverURL(for game: Game) -> URL? {
        guard let name = game.coverFileName else { return nil }
        return gameFolder(game).appendingPathComponent(name)
    }

    /// 引擎可写的存档目录。放在 Documents 下，用户能用「文件」App 备份。
    static func saveFolder(_ game: Game) -> URL {
        documents
            .appendingPathComponent("Saves", isDirectory: true)
            .appendingPathComponent(game.folderName, isDirectory: true)
    }

    /// 宿主生成的配置目录（mkxp.json、patches.json）。
    /// 与游戏本体分开，重装/重新导入游戏时配置还在。
    static func configFolder(_ game: Game) -> URL {
        documents
            .appendingPathComponent("Config", isDirectory: true)
            .appendingPathComponent(game.folderName, isDirectory: true)
    }

    /// 每个游戏一份引擎日志，排错时直接看这里。
    static func logFile(_ game: Game) -> URL {
        documents
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("\(game.folderName).log")
    }

    @discardableResult
    static func ensureDirectories() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: gamesRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: importsRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: documents.appendingPathComponent("Saves"), withIntermediateDirectories: true)
            try fm.createDirectory(at: documents.appendingPathComponent("Config"), withIntermediateDirectories: true)
            try fm.createDirectory(at: documents.appendingPathComponent("Logs"), withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}

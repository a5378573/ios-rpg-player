import Foundation
import ZIPFoundation

enum ImportError: LocalizedError {
    case unzipFailed(String)
    case engineNotFound
    case fileAccessDenied

    var errorDescription: String? {
        switch self {
        case .unzipFailed(let detail):
            return "解压失败：\(detail)"
        case .engineNotFound:
            return "没有找到可识别的 RPG Maker 游戏文件（RPG_RT.ldb / Data/Scripts.rxdata / data/System.json）"
        case .fileAccessDenied:
            return "无法访问所选文件，请重新选择"
        }
    }
}

/// 负责解压与引擎识别。耗时操作放到后台队列。
@MainActor
final class ImportService {
    static let shared = ImportService()

    private let fm = FileManager.default

    func importArchive(at archiveURL: URL,
                       progress: @escaping (String) -> Void = { _ in }) async throws -> Game {
        let accessing = archiveURL.startAccessingSecurityScopedResource()
        defer { if accessing { archiveURL.stopAccessingSecurityScopedResource() } }

        let temp = FileLocations.importsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        progress("正在解压…")
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try FileManager.default.unzipItem(at: archiveURL, to: temp)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            throw ImportError.unzipFailed(error.localizedDescription)
        }

        progress("正在识别引擎…")
        guard let gameRoot = Self.findGameRoot(in: temp) else {
            throw ImportError.engineNotFound
        }
        let engine = Self.detectEngine(at: gameRoot)
        guard engine != .unknown else { throw ImportError.engineNotFound }

        let title = Self.guessTitle(at: gameRoot, engine: engine)
        let folderName = Self.uniqueFolderName(base: Self.sanitize(title))

        progress("正在整理文件…")
        let destination = FileLocations.gamesRoot.appendingPathComponent(folderName, isDirectory: true)
        try? fm.createDirectory(at: FileLocations.gamesRoot, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        do {
            try fm.moveItem(at: gameRoot, to: destination)
        } catch {
            throw ImportError.unzipFailed(error.localizedDescription)
        }

        let cover = Self.detectCover(in: destination, engine: engine)
        let game = Game(name: title,
                        folderName: folderName,
                        engine: engine,
                        coverFileName: cover,
                        layout: .default)
        progress("完成")
        return game
    }

    // MARK: - 识别

    /// 向下最多两层寻找真正的游戏根目录。
    static func findGameRoot(in root: URL) -> URL? {
        var queue: [(URL, Int)] = [(root, 0)]
        let fm = FileManager.default
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            if detectEngine(at: dir) != .unknown { return dir }
            guard depth < 2 else { continue }
            guard let children = try? fm.contentsOfDirectory(at: dir,
                                                             includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }

    static func detectEngine(at root: URL) -> EngineType {
        let fm = FileManager.default
        func exists(_ relative: String) -> Bool {
            fm.fileExists(atPath: root.appendingPathComponent(relative).path)
        }

        // MV / MZ
        let mvRoots = ["", "www/"]
        for prefix in mvRoots {
            if exists(prefix + "data/System.json") {
                if exists(prefix + "js/rmmz_core.js") || exists(prefix + "js/rmmz_objects.js") {
                    return .rpgMakerMZ
                }
                return .rpgMakerMV
            }
        }

        // 2000 / 2003
        if exists("RPG_RT.ldb") || exists("rpg_rt.ldb") {
            let ldbName = exists("RPG_RT.ldb") ? "RPG_RT.ldb" : "rpg_rt.ldb"
            let ldbURL = root.appendingPathComponent(ldbName)
            if let handle = try? FileHandle(forReadingFrom: ldbURL) {
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: 2_000_000)) ?? Data()
                let marker = "BattleCommands".data(using: .ascii)!
                return data.range(of: marker) != nil ? .rpgMaker2003 : .rpgMaker2000
            }
            return .rpgMaker2000
        }

        // XP / VX / VX Ace
        if exists("Data/Scripts.rxdata") { return .rpgMakerXP }
        if exists("Data/Scripts.rvdata2") { return .rpgMakerVXAce }
        if exists("Data/Scripts.rvdata") { return .rpgMakerVX }

        return .unknown
    }

    static func guessTitle(at root: URL, engine: EngineType) -> String {
        let fm = FileManager.default

        if engine.isWebBased {
            for prefix in ["", "www/"] {
                let url = root.appendingPathComponent(prefix + "data/System.json")
                if let data = try? Data(contentsOf: url),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let title = obj["gameTitle"] as? String,
                   !title.isEmpty {
                    return title
                }
            }
        }

        if engine.isRGSS || engine.isEasyRPG {
            let iniName = engine.isEasyRPG ? "RPG_RT.ini" : "Game.ini"
            let iniURL = root.appendingPathComponent(iniName)
            if let text = try? String(contentsOf: iniURL, encoding: .utf8) {
                if let title = Self.iniValue(text, section: engine.isEasyRPG ? "RPG_RT" : "Game", key: "Title"),
                   !title.isEmpty {
                    return title
                }
            }
        }

        let folder = root.lastPathComponent
        return folder.isEmpty ? "未命名游戏" : folder
    }

    static func detectCover(in root: URL, engine: EngineType) -> String? {
        let fm = FileManager.default
        let candidates: [String]
        if engine.isWebBased {
            candidates = ["www/img/titles1/", "img/titles1/", "icon/icon.png"]
        } else if engine.isRGSS {
            candidates = ["Graphics/Titles/", "Graphics/Titles1/", "Graphics/System/Title.png"]
        } else {
            return nil
        }
        for candidate in candidates {
            let url = root.appendingPathComponent(candidate)
            if candidate.hasSuffix(".png") {
                if fm.fileExists(atPath: url.path) { return candidate }
                continue
            }
            if let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                if let first = files.first(where: { $0.pathExtension.lowercased() == "png" }) {
                    return candidate + first.lastPathComponent
                }
            }
        }
        return nil
    }

    // MARK: - 工具

    static func iniValue(_ text: String, section: String, key: String) -> String? {
        var currentSection = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                continue
            }
            guard currentSection.caseInsensitiveCompare(section) == .orderedSame else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "game" : String(cleaned.prefix(60))
    }

    static func uniqueFolderName(base: String) -> String {
        let fm = FileManager.default
        var candidate = base
        var index = 2
        while fm.fileExists(atPath: FileLocations.gamesRoot.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }
}

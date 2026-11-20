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
            return "解压完成，但没有找到 RPG Maker 游戏文件。请确认压缩包内直接就是游戏目录（含 Game.ini、RPG_RT.ldb 或 Data/Scripts.rxdata），而不是又套了一层压缩包。"
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
                        try Self.unzipVerified(archiveURL, to: temp)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch let error as ImportError {
            throw error
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

    // MARK: - 解压

    /// 先体检再解压。
    ///
    /// 直接调用 `FileManager.unzipItem` 只会得到一句「ArchiveError 错误 13」，
    /// 那个 13 是 `missingEndOfCentralDirectoryRecord`——文件末尾没有 ZIP
    /// 结束标记。真实原因往往是下面几种之一，这里逐个分辨并说清楚。
    static func unzipVerified(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default

        let attrs = try? fm.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        guard size > 0 else {
            throw ImportError.unzipFailed("""
            文件大小是 0 字节。如果它在 iCloud 云盘里，请先用「文件」App 打开一次、等它下载完成再导入。
            """)
        }

        guard let head = headBytes(source, count: 8) else {
            throw ImportError.unzipFailed("读不到文件内容，可能尚未下载到本机，或者文件提供方没有授予访问权限。")
        }

        guard looksLikeZip(head) else {
            throw ImportError.unzipFailed("\(describeForeignFormat(head))请用 7-Zip 重新打包成标准 ZIP 再导入。")
        }

        guard hasEndOfCentralDirectory(source, fileSize: size) else {
            throw ImportError.unzipFailed("""
            压缩包末尾缺少 ZIP 结束标记（文件不完整）。常见原因：
            ① 下载中断，文件只下了一部分；
            ② 分卷压缩包（.z01 / .z02），需要先合并；
            ③ 用「仅存储」以外的方式打包时产生了非标准结构。
            建议用 7-Zip 重新压缩：格式选 zip，压缩方法 Deflate，不要分卷。
            """)
        }

        let archive: Archive
        do {
            archive = try Archive(url: source, accessMode: .read)
        } catch {
            throw ImportError.unzipFailed(describeArchiveError(error))
        }

        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let base = destination.standardizedFileURL.path

        var written = 0
        var failures: [String] = []

        for entry in archive {
            let path = entry.path
            // 跳过 macOS 元数据与系统垃圾
            if path.hasPrefix("__MACOSX/") || path.hasSuffix(".DS_Store") { continue }
            // 符号链接一律不落地，避免指向包外
            if entry.type == .symlink { continue }

            let target = destination.appendingPathComponent(path).standardizedFileURL
            // 防路径穿越：../ 必须被拦截
            guard target.path == base || target.path.hasPrefix(base + "/") else { continue }

            do {
                if entry.type == .directory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: target.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                    _ = try archive.extract(entry, to: target)
                    written += 1
                }
            } catch {
                failures.append("\(path)（\(error.localizedDescription)）")
            }
        }

        guard written > 0 else {
            throw ImportError.unzipFailed("压缩包是空的，或者里面只有目录没有文件。")
        }
        if !failures.isEmpty {
            let sample = failures.prefix(3).joined(separator: "；")
            throw ImportError.unzipFailed("有 \(failures.count) 个文件解压失败：\(sample)")
        }
    }

    private static func headBytes(_ url: URL, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }

    private static func looksLikeZip(_ head: Data) -> Bool {
        guard head.count >= 4 else { return false }
        let b = [UInt8](head.prefix(4))
        // PK\x03\x04 普通条目；PK\x05\x06 空包；PK\x07\x08 分卷标记
        return b[0] == 0x50 && b[1] == 0x4B
            && ((b[2] == 0x03 && b[3] == 0x04)
                || (b[2] == 0x05 && b[3] == 0x06)
                || (b[2] == 0x07 && b[3] == 0x08))
    }

    private static func describeForeignFormat(_ head: Data) -> String {
        let b = [UInt8](head)
        func hasPrefix(_ bytes: [UInt8]) -> Bool {
            b.count >= bytes.count && Array(b.prefix(bytes.count)) == bytes
        }
        if hasPrefix([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return "这是 RAR 压缩包，不是 ZIP。" }
        if hasPrefix([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return "这是 7z 压缩包，不是 ZIP。" }
        if hasPrefix([0x1F, 0x8B]) { return "这是 gzip 压缩包，不是 ZIP。" }
        if hasPrefix([0x42, 0x5A, 0x68]) { return "这是 bzip2 压缩包，不是 ZIP。" }
        if hasPrefix([0xFD, 0x37, 0x7A, 0x58, 0x5A]) { return "这是 xz 压缩包，不是 ZIP。" }
        if hasPrefix([0x75, 0x73, 0x74, 0x61, 0x72]) { return "这是 tar 归档，不是 ZIP。" }
        if hasPrefix([0x4D, 0x5A]) { return "这是 Windows 可执行文件（.exe），不是 ZIP。" }
        return "文件头不是 ZIP 格式（可能是别的压缩格式改了后缀）。"
    }

    /// 在文件末尾 66 KB 内找 End of Central Directory 签名（PK\x05\x06）。
    /// ZIP 注释最长 65535 字节，所以这个窗口足够覆盖。
    private static func hasEndOfCentralDirectory(_ url: URL, fileSize: Int64) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let window: Int64 = 66_000
        let start = max(0, fileSize - window)
        do {
            try handle.seek(toOffset: UInt64(start))
            guard let tail = try handle.readToEnd() else { return false }
            let signature = Data([0x50, 0x4B, 0x05, 0x06])
            return tail.range(of: signature) != nil
        } catch {
            return false
        }
    }

    /// 把 ArchiveError 翻译成能照着做的建议。
    /// 这些 case 没有 rawValue，桥接成 NSError 时的 code 就是声明顺序。
    private static func describeArchiveError(_ error: Error) -> String {
        guard let archiveError = error as? Archive.ArchiveError else {
            return error.localizedDescription
        }
        switch archiveError {
        case .missingEndOfCentralDirectoryRecord, .unreadableArchive:
            return "压缩包结构不完整，无法解析。请用 7-Zip 重新压成标准 ZIP。"
        case .invalidCRC32:
            return "压缩包内文件校验失败，说明包已损坏。请重新下载或重新压缩。"
        case .invalidCompressionMethod:
            return "压缩包使用了 iOS 不支持的压缩算法（如 LZMA / PPMd / Zstandard）。请用 7-Zip 重压，方法选 Deflate。"
        case .invalidEntryPath:
            return "压缩包内有无法解析的文件名。请用 7-Zip 重压，并确保文件名不是乱码。"
        case .invalidEntrySize, .invalidLocalHeaderDataOffset, .invalidLocalHeaderSize,
             .invalidCentralDirectoryOffset, .invalidCentralDirectorySize,
             .invalidCentralDirectoryEntryCount:
            return "压缩包结构越界，多半是文件被截断。请确认下载完整。"
        case .invalidBufferSize:
            return "解压参数异常，请反馈给开发者。"
        case .cancelledOperation:
            return "解压被中断。"
        case .uncontainedSymlink:
            return "压缩包含有指向外部的符号链接，出于安全考虑已拒绝。"
        case .unwritableArchive:
            return "写入失败，可能是存储空间不足。"
        @unknown default:
            return error.localizedDescription
        }
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

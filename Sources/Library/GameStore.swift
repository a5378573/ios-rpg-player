import Foundation
import Combine

@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var lastError: String?

    private let fm = FileManager.default

    init() {
        FileLocations.ensureDirectories()
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: FileLocations.libraryFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([Game].self, from: data) else { return }
        games = decoded.filter { fm.fileExists(atPath: FileLocations.gameFolder($0).path) }
    }

    private var saveTask: Task<Void, Never>?

    /// 拖动按键时会被高频调用，这里做 0.4 秒合并写盘。
    func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.writeToDisk()
        }
    }

    /// 进入后台或退出播放页时立刻落盘。
    func flush() {
        saveTask?.cancel()
        writeToDisk()
    }

    private func writeToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(games)
            try data.write(to: FileLocations.libraryFile, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func add(_ game: Game) {
        games.append(game)
        save()
    }

    func update(_ game: Game) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index] = game
        save()
    }

    func remove(_ game: Game) {
        games.removeAll { $0.id == game.id }
        try? fm.removeItem(at: FileLocations.gameFolder(game))
        save()
    }

    func toggleHidden(_ game: Game) {
        var copy = game
        copy.isHidden.toggle()
        update(copy)
    }

    func recordPlay(_ game: Game, seconds: Double) {
        guard var copy = games.first(where: { $0.id == game.id }) else { return }
        copy.lastPlayedAt = Date()
        copy.playSeconds += max(0, seconds)
        update(copy)
    }

    func game(withID id: UUID) -> Game? {
        games.first { $0.id == id }
    }
}

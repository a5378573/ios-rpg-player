import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct PlayerRoute: Identifiable {
    let id: UUID
}

struct GameLibraryView: View {
    @EnvironmentObject private var store: GameStore

    @State private var showImporter = false
    @State private var isImporting = false
    @State private var importStatus: String = ""
    @State private var importError: String?
    @State private var playerRoute: PlayerRoute?

    private var visibleGames: [Game] {
        store.games
            .filter { !$0.isHidden }
            .sorted { lhs, rhs in
                switch (lhs.lastPlayedAt, rhs.lastPlayedAt) {
                case let (l?, r?): return l > r
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.addedAt > rhs.addedAt
                }
            }
    }

    var body: some View {
        NavigationView {
            ZStack {
                if visibleGames.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 16)],
                                  spacing: 20) {
                            ForEach(visibleGames) { game in
                                Button {
                                    playerRoute = PlayerRoute(id: game.id)
                                } label: {
                                    GameCard(game: game)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        store.toggleHidden(game)
                                    } label: {
                                        Label("隐藏", systemImage: "eye.slash")
                                    }
                                    Button(role: .destructive) {
                                        store.remove(game)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }

                if isImporting {
                    importOverlay
                }
            }
            .navigationTitle("RPG盒子")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.zip],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .fullScreenCover(item: $playerRoute) { route in
                GamePlayerView(gameID: route.id)
                    .environmentObject(store)
            }
            .alert("导入失败", isPresented: Binding(
                get: { importError != nil },
                set: { newValue in
                    if !newValue { importError = nil }
                }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 52, weight: .light))
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                Text("还没有游戏")
                    .font(.title3.weight(.semibold))
                Text("把游戏文件夹压缩成 ZIP，点右上角加号导入")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showImporter = true
            } label: {
                Label("导入游戏", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)

            VStack(alignment: .leading, spacing: 6) {
                Text("支持范围")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                engineRow("RPG Maker MV / MZ", "内置 WebView，可直接运行")
                engineRow("RPG Maker XP / VX / VX Ace", "需要 mkxp-z 运行时")
                engineRow("RPG Maker 2000 / 2003", "需要 EasyRPG 运行时")
            }
            .padding(.top, 8)
        }
        .padding(28)
    }

    private func engineRow(_ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.medium))
                Text(subtitle).font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var importOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                Text(importStatus.isEmpty ? "正在导入…" : importStatus)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            importStatus = "准备导入…"
            Task {
                do {
                    let game = try await ImportService.shared.importArchive(at: url) { message in
                        importStatus = message
                    }
                    store.add(game)
                    isImporting = false
                    importStatus = ""
                } catch {
                    isImporting = false
                    importStatus = ""
                    importError = error.localizedDescription
                }
            }
        }
    }
}

struct GameCard: View {
    let game: Game

    private var coverImage: UIImage? {
        guard let url = FileLocations.coverURL(for: game),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay {
                        if let image = coverImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Text(String(game.name.prefix(1)))
                                .font(.system(size: 46, weight: .bold, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(game.engine.shortTag)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(game.engine.displayName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

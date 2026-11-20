import SwiftUI
import UIKit

/// 游戏运行时。三类引擎走两条不同的链路：
///
/// - MV / MZ：WKWebView，跑在 SwiftUI 里，虚拟手柄是 SwiftUI 覆盖层。
/// - XP / VX / VX Ace：原生 mkxp 引擎，会接管主线程，虚拟手柄是挂在
///   引擎窗口上的 UIKit 视图，SwiftUI 在这一局里不再刷新。
/// - 2000 / 2003：暂不支持，给出明确说明。
@MainActor
struct GamePlayerView: View {
    let gameID: UUID
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    @State private var webEngine: WebGameEngine?
    @State private var message: String?
    @State private var isLaunching = false
    @State private var sessionEnded = false

    @State private var isEditingControls = false
    @State private var showControlEditor = false
    @State private var isChromeVisible = true
    @State private var startedAt = Date()
    @State private var hasStarted = false

    /// 编辑期间只改本地副本，避免每拖一帧就写盘、重建视图、打断手势。
    @State private var draftLayout: ControlLayout = .default
    @State private var didLoadLayout = false

    /// 原生会话期间不能在主线程刷新 SwiftUI，拖动结果先存在 LayoutBuffer 里，
    /// 等会话结束再落盘。
    private var game: Game? { store.game(withID: gameID) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let webEngine {
                EngineHostView(engineView: webEngine.view)
                    .ignoresSafeArea()

                VirtualControlsOverlay(
                    layout: $draftLayout,
                    isEditing: isEditingControls,
                    onPress: { key, custom in webEngine.press(key, custom: custom) },
                    onRelease: { key, custom in webEngine.release(key, custom: custom) }
                )
                .ignoresSafeArea()

                if isChromeVisible { chrome } else { collapsedChrome }
            }

            if isLaunching {
                launchingView
            }

            if let message {
                messageView(message)
            }
        }
        .statusBarHidden(true)
        .task {
            loadLayoutIfNeeded()
            startIfNeeded()
        }
        .onDisappear { stopAndRecord() }
        .sheet(isPresented: $showControlEditor, onDismiss: commitLayout) {
            ControlEditorView(layout: $draftLayout)
        }
        .alert("游戏已结束", isPresented: $sessionEnded) {
            Button("回到游戏库") { dismiss() }
        } message: {
            Text("""
            存档在「文件」App 的 RPGPlayer/Saves 下。

            iOS 不允许在同一进程里重启 Ruby 虚拟机，所以要玩别的游戏，\
            请先从后台把这个 App 划掉再重新打开。
            """)
        }
    }

    // MARK: - 启动画面

    private var launchingView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.2)
            Text("正在启动引擎…")
                .font(.callout)
                .foregroundColor(.white.opacity(0.85))
            Text("首次进入要解包脚本、初始化 Ruby，\n大一点的游戏会等十几秒。")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.45))
        }
        .padding(28)
    }

    private func messageView(_ text: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(.yellow)
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.9))
            Button("返回游戏库") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    // MARK: - Web 引擎的外框

    private var chrome: some View {
        VStack {
            HStack(spacing: 10) {
                chromeButton(systemName: "chevron.left") {
                    commitLayout()
                    stopAndRecord()
                    dismiss()
                }
                Spacer()
                if isEditingControls {
                    Text("拖动按键调整位置")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                chromeButton(systemName: isEditingControls ? "checkmark" : "dot.scope") {
                    toggleEditing()
                }
                chromeButton(systemName: "slider.horizontal.3") {
                    showControlEditor = true
                }
                chromeButton(systemName: "eye.slash") {
                    withAnimation(.easeOut(duration: 0.2)) { isChromeVisible = false }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            Spacer()
        }
    }

    private var collapsedChrome: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { isChromeVisible = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.trailing, 12)
            .padding(.top, 6)
            Spacer()
        }
    }

    private func chromeButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    // MARK: - 布局

    private func loadLayoutIfNeeded() {
        guard !didLoadLayout, let game else { return }
        draftLayout = game.layout
        didLoadLayout = true
    }

    private func commitLayout() {
        guard didLoadLayout, var copy = store.game(withID: gameID) else { return }
        guard copy.layout != draftLayout else { return }
        copy.layout = draftLayout
        store.update(copy)
        store.flush()
    }

    private func toggleEditing() {
        isEditingControls.toggle()
        if !isEditingControls { commitLayout() }
    }

    // MARK: - 生命周期

    private func startIfNeeded() {
        guard !hasStarted, let game else { return }
        hasStarted = true
        startedAt = Date()

        switch game.engine {
        case .rpgMakerMV, .rpgMakerMZ:
            startWeb(game)
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            startNative(game)
        case .rpgMaker2000, .rpgMaker2003, .unknown:
            message = unavailableMessage(for: game.engine)
        }
    }

    private func startWeb(_ game: Game) {
        do {
            let engine = try EngineFactory.makeEngine(for: game)
            try engine.start()
            guard let web = engine as? WebGameEngine else {
                message = "无法启动这个引擎。"
                return
            }
            webEngine = web
        } catch {
            message = error.localizedDescription
        }
    }

    private func startNative(_ game: Game) {
        isLaunching = true
        let buffer = LayoutBuffer()

        let session = MkxpSession.shared
        session.onLayoutChanged = { newLayout in
            // 主线程被引擎占着，这里只记录，不碰 SwiftUI 状态
            buffer.layout = newLayout
        }
        session.onSessionEnded = {
            // 回调发生在主 run loop 的 callout 里，可以安全地回到 MainActor
            MainActor.assumeIsolated {
                self.isLaunching = false
                self.hasStarted = false
                if let layout = buffer.layout {
                    self.persist(layout: layout)
                }
                if let game = self.store.game(withID: self.gameID) {
                    self.store.recordPlay(game, seconds: Date().timeIntervalSince(self.startedAt))
                }
                self.sessionEnded = true
            }
        }

        do {
            try session.launch(game: game)
        } catch {
            isLaunching = false
            message = error.localizedDescription
        }
    }

    private func persist(layout: ControlLayout) {
        guard var copy = store.game(withID: gameID) else { return }
        guard copy.layout != layout else { return }
        copy.layout = layout
        store.update(copy)
        store.flush()
    }

    private func unavailableMessage(for engine: EngineType) -> String {
        switch engine {
        case .rpgMaker2000, .rpgMaker2003:
            return """
            \(engine.displayName) 需要 EasyRPG Player。

            EasyRPG 官方至今没有维护 iOS 目标，要接入得自己写平台层。
            这个版本先提供 XP / VX / VX Ace（原生引擎）与 MV / MZ（Web 运行时）。
            """
        default:
            return "未识别的引擎，无法启动。"
        }
    }

    private func stopAndRecord() {
        guard hasStarted else { return }
        hasStarted = false

        if let webEngine {
            webEngine.stop()
            self.webEngine = nil
        }

        // 原生会话不能在离开页面时强杀：引擎占着主线程，进程级资源
        // 也只能靠重开 App 复位。这里只处理 Web 引擎和播放时长。
        if MkxpSession.shared.isRunning {
            return
        }

        if let game {
            store.recordPlay(game, seconds: Date().timeIntervalSince(startedAt))
        }
    }
}

struct EngineHostView: UIViewRepresentable {
    let engineView: UIView

    func makeUIView(context: Context) -> UIView {
        engineView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 会话进行期间 SwiftUI 停止刷新，拖动结果先落在这个盒子里。
/// 放在文件作用域，避免跟着 View 的 MainActor 隔离一起走。
private final class LayoutBuffer {
    var layout: ControlLayout?
}

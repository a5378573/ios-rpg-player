import Foundation
import UIKit
import os

enum MkxpSessionError: LocalizedError {
    case engineNotLinked
    case unsupportedEngine(EngineType)
    case alreadyRunning
    case needsRestart
    case missingGameFolder
    case prepareFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .engineNotLinked:
            return """
            这个构建没有链接 mkxp 引擎。

            先执行 Scripts/fetch_engine.sh 拉取预编译引擎，再重新构建。
            """
        case .unsupportedEngine(let engine):
            return "\(engine.displayName) 不在 mkxp 的支持范围内。"
        case .alreadyRunning:
            return "已经有一个游戏在运行。"
        case .needsRestart:
            return """
            iOS 不允许 App 在同一进程里重启 Ruby 虚拟机。

            请从后台把 App 划掉，重新打开后再启动另一个游戏。
            """
        case .missingGameFolder:
            return "游戏目录不存在，可能已被删除。请重新导入。"
        case .prepareFailed(let code):
            return "引擎初始化失败（错误码 \(code)）。日志在 Documents/Logs 下。"
        }
    }
}

/// 一次 mkxp 游戏会话。
///
/// 这个类不做渲染：引擎自己创建 SDL 窗口、自己泵 UIKit 事件循环。
/// 宿主只负责三件事——按顺序配置引擎、在主线程跑起来、
/// 把虚拟手柄挂到引擎的窗口上。
///
/// 重要限制（引擎设计决定，绕不过去）：
/// **一个进程只能跑一个 Ruby 会话**。CRuby 的 `ruby_init()` 每进程
/// 只能调用一次，所以游戏结束后必须重开 App 才能玩下一个。
@MainActor
final class MkxpSession {
    static let shared = MkxpSession()

    private(set) var isRunning = false
    private(set) var hasRunBefore = false

    /// 会话结束（游戏内退出、或宿主请求退出）时回调，主线程。
    var onSessionEnded: (() -> Void)?
    /// 玩家在游戏内改了按键位置。
    var onLayoutChanged: ((ControlLayout) -> Void)?

    private var overlay: GamepadOverlayView?
    private var readinessTimer: DispatchSourceTimer?
    private var layout: ControlLayout = .default
    private var callbacksInstalled = false

    private init() {}

    // MARK: - 启动

    func launch(game: Game) throws {
        guard rpg_engine_available() else {
            throw MkxpSessionError.engineNotLinked
        }
        guard !isRunning else {
            throw MkxpSessionError.alreadyRunning
        }
        guard !hasRunBefore else {
            throw MkxpSessionError.needsRestart
        }
        guard let rubyVersion = Self.rubyVersion(for: game.engine) else {
            throw MkxpSessionError.unsupportedEngine(game.engine)
        }

        let root = FileLocations.gameFolder(game)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw MkxpSessionError.missingGameFolder
        }
        FileLocations.ensureDirectories()

        installCallbacksIfNeeded()

        let result = withOptions(game: game, rubyVersion: rubyVersion) { options in
            var mutable = options
            return rpg_prepare(&mutable)
        }

        guard result == RPGRunOK else {
            throw MkxpSessionError.prepareFailed(Int32(result.rawValue))
        }

        layout = game.layout
        isRunning = true

        // 必须在 run loop 的定时器里起引擎：引擎会占住主线程直到游戏结束，
        // 放进 dispatch 主队列会永远不排空，RGSS 线程随后死锁。
        // RunLoop.perform 是一个 run loop callout，当前这轮 SwiftUI 更新先结束。
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                self?.runEngine()
            }
        }
    }

    /// 请求结束。引擎会在下一帧退出，`rpg_run()` 随之返回。
    func requestTerminate() {
        guard isRunning else { return }
        rpg_terminate()
    }

    /// 引擎创建出来的窗口（调试或截图用）。
    var gameWindow: UIWindow? {
        guard let raw = rpg_game_window() else { return nil }
        return Unmanaged<UIWindow>.fromOpaque(raw).takeUnretainedValue()
    }

    // MARK: - 引擎线程

    private func runEngine() {
        guard isRunning else { return }
        startReadinessPolling()

        // 阻塞，直到游戏结束。期间主线程由 SDL 的事件泵驱动。
        let status = rpg_run()

        stopReadinessPolling()
        removeOverlay()

        isRunning = false
        hasRunBefore = true

        Logger(subsystem: "com.local.rpgplayer", category: "engine")
            .notice("引擎退出，状态码 \(status, privacy: .public)")

        onSessionEnded?()
    }

    // MARK: - 配置

    private func withOptions<T>(game: Game, rubyVersion: Int32, _ body: (RPGSessionOptions) -> T) -> T {
        let root = FileLocations.gameFolder(game).path
        let saves = FileLocations.saveFolder(game).path
        let config = FileLocations.configFolder(game).path
        let log = FileLocations.logFile(game).path
        let ca = Bundle.main.bundlePath + "/Assets.bundle/cacert.pem"
        let hasCA = FileManager.default.fileExists(atPath: ca)

        // rpg_prepare 内部会 strdup，这几块内存只需要活到调用结束。
        let cRoot = strdup(root)!
        let cSaves = strdup(saves)!
        let cConfig = strdup(config)!
        let cLog = strdup(log)!
        let cCA = hasCA ? strdup(ca) : nil
        defer {
            free(cRoot); free(cSaves); free(cConfig); free(cLog)
            if let cCA { free(cCA) }
        }

        let options = RPGSessionOptions(
            gameDirectory: UnsafePointer(cRoot),
            userDataDirectory: UnsafePointer(cSaves),
            managedConfigDir: UnsafePointer(cConfig),
            logFile: UnsafePointer(cLog),
            caBundle: cCA.map { UnsafePointer($0) },
            rubyVersion: rubyVersion,
            syntaxTransform: nil,
            verticalAlignment: 1
        )
        return body(options)
    }

    /// RGSS 1/2/3 对应 Ruby 1.8 / 1.9 / 3.1。
    private static func rubyVersion(for engine: EngineType) -> Int32? {
        switch engine {
        case .rpgMakerXP:    return 18
        case .rpgMakerVX:    return 19
        case .rpgMakerVXAce: return 31
        default:             return nil
        }
    }

    private func installCallbacksIfNeeded() {
        guard !callbacksInstalled else { return }
        callbacksInstalled = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        // C 侧会整体拷贝一份，所以这里的 var 只要活到调用结束即可。
        var callbacks = RPGCallbacks(
            onTerminated: mkxpTerminatedTrampoline,
            onError: mkxpErrorTrampoline,
            onInfo: mkxpInfoTrampoline,
            onFrameRendered: nil,
            context: context
        )
        rpg_set_callbacks(&callbacks)
    }

    // MARK: - 事件（引擎线程 → 主线程）

    fileprivate func handleTerminated() {
        Logger(subsystem: "com.local.rpgplayer", category: "engine")
            .notice("引擎报告游戏结束")
    }

    fileprivate func handleError(_ message: String) {
        // 引擎线程这时是阻塞的：必须弹窗并在关闭时回调 dismiss，
        // 否则整条引擎线程会一直挂着。
        presentBlockingAlert(title: "游戏出错", message: message) {
            rpg_dismiss_error()
        }
    }

    fileprivate func handleInfo(_ message: String) {
        presentBlockingAlert(title: "提示", message: message) {
            rpg_dismiss_info()
        }
    }

    // MARK: - 虚拟手柄

    private func startReadinessPolling() {
        stopReadinessPolling()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.2, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler {
            guard rpg_is_ready() else { return }
            // 回到主 run loop 再动 UI 和状态
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    MkxpSession.shared.checkReadinessOnce()
                }
            }
        }
        readinessTimer = timer
        timer.resume()
    }

    /// 引擎初始化完成后挂载覆盖层。由后台轮询跳回主线程调用。
    fileprivate func checkReadinessOnce() {
        guard isRunning, overlay == nil, rpg_is_ready() else { return }
        stopReadinessPolling()
        attachOverlay()
    }

    private func stopReadinessPolling() {
        readinessTimer?.cancel()
        readinessTimer = nil
    }

    private func attachOverlay() {
        guard isRunning, overlay == nil else { return }
        guard let window = gameWindow, let root = window.rootViewController else {
            return
        }

        let view = GamepadOverlayView(layout: layout)
        view.onKey = { code, pressed in
            rpg_send_key(code, pressed ? 1 : 0)
        }
        view.onRequestExit = { [weak self] in
            // 触摸事件来自主线程的 UIKit，直接进 MainActor
            MainActor.assumeIsolated { self?.confirmExit() }
        }
        view.onLayoutChanged = { [weak self] newLayout in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layout = newLayout
                self.onLayoutChanged?(newLayout)
            }
        }

        view.frame = root.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.addSubview(view)
        overlay = view

        let insets = root.view.safeAreaInsets
        rpg_set_safe_area(Float(insets.top), Float(insets.bottom),
                          Float(insets.left), Float(insets.right))
    }

    private func removeOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    private func confirmExit() {
        let alert = UIAlertController(
            title: "退出游戏",
            message: "这一局会结束，之后要从后台划掉 App 再重开才能玩别的游戏。存档在「文件」App 的 Saves 目录里。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "继续游戏", style: .cancel))
        alert.addAction(UIAlertAction(title: "退出", style: .destructive) { _ in
            rpg_terminate()
        })
        topViewController()?.present(alert, animated: true)
    }

    // MARK: - 弹窗

    private func presentBlockingAlert(title: String, message: String, dismiss: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in dismiss() })

        guard let presenter = topViewController() else {
            // 实在没有可用的视图控制器，也不能把引擎线程永远挂着
            dismiss()
            return
        }
        presenter.present(alert, animated: true)
    }

    private func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }

        guard var controller = (gameWindow ?? keyWindow)?.rootViewController else {
            return keyWindow?.rootViewController
        }
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }
}

// MARK: - C 回调跳板

// 必须是全局函数：C 函数指针不接受捕获上下文的闭包。
// 引擎在线程回调，这里统一跳回主 run loop 再进 MainActor。

private func mkxpOnMain(_ context: UnsafeMutableRawPointer?,
                        _ body: @escaping @MainActor (MkxpSession) -> Void) {
    guard let context else { return }
    RunLoop.main.perform {
        MainActor.assumeIsolated {
            let session = Unmanaged<MkxpSession>.fromOpaque(context).takeUnretainedValue()
            body(session)
        }
    }
}

private func mkxpTerminatedTrampoline(_ context: UnsafeMutableRawPointer?) {
    mkxpOnMain(context) { $0.handleTerminated() }
}

private func mkxpErrorTrampoline(_ message: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    let text = message.map { String(cString: $0) } ?? "未知错误"
    mkxpOnMain(context) { $0.handleError(text) }
}

private func mkxpInfoTrampoline(_ message: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    let text = message.map { String(cString: $0) } ?? ""
    mkxpOnMain(context) { $0.handleInfo(text) }
}

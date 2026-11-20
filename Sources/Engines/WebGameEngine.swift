import UIKit
import WebKit

/// MV / MZ 运行时：WKWebView + 本地 HTTP 服务。
/// 游戏本身是 HTML5，输入通过注入 KeyboardEvent 完成。
@MainActor
final class WebGameEngine: NSObject, GameEngine {
    private let gameRoot: URL
    private let entryPath: String
    private var server: StaticFileServer?
    private var didStart = false

    private(set) lazy var webView: WKWebView = makeWebView()

    init(gameRoot: URL, entryPath: String) {
        self.gameRoot = gameRoot
        self.entryPath = entryPath
        super.init()
    }

    var view: UIView { webView }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }

    func start() throws {
        guard !didStart else { return }
        didStart = true

        let server = StaticFileServer(root: gameRoot)
        try server.start()
        self.server = server

        guard let base = server.baseURL,
              let url = URL(string: entryPath, relativeTo: base) else {
            throw NSError(domain: "WebGameEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法构造本地游戏地址"])
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    func stop() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        server?.stop()
        server = nil
        didStart = false
    }

    // MARK: - 输入

    func press(_ key: GameKey, custom: String?) {
        dispatch(key: key, custom: custom, isDown: true)
    }

    func release(_ key: GameKey, custom: String?) {
        dispatch(key: key, custom: custom, isDown: false)
    }

    private func dispatch(key: GameKey, custom: String?, isDown: Bool) {
        guard let info = Self.keyInfo(for: key, custom: custom) else { return }
        let type = isDown ? "keydown" : "keyup"
        let script = """
        (function(){
          try {
            var e = new KeyboardEvent('\(type)', { key: '\(info.name)', code: '\(info.code)', bubbles: true, cancelable: true });
            try { Object.defineProperty(e, 'keyCode', { get: function(){ return \(info.keyCode); } }); } catch (a) {}
            try { Object.defineProperty(e, 'which', { get: function(){ return \(info.keyCode); } }); } catch (b) {}
            document.dispatchEvent(e);
          } catch (err) {}
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    struct KeyInfo {
        let name: String
        let code: String
        let keyCode: Int
    }

    static func keyInfo(for key: GameKey, custom: String?) -> KeyInfo? {
        switch key {
        case .up:      return KeyInfo(name: "ArrowUp", code: "ArrowUp", keyCode: 38)
        case .down:    return KeyInfo(name: "ArrowDown", code: "ArrowDown", keyCode: 40)
        case .left:    return KeyInfo(name: "ArrowLeft", code: "ArrowLeft", keyCode: 37)
        case .right:   return KeyInfo(name: "ArrowRight", code: "ArrowRight", keyCode: 39)
        case .confirm: return KeyInfo(name: "Enter", code: "Enter", keyCode: 13)
        case .cancel:  return KeyInfo(name: "Escape", code: "Escape", keyCode: 27)
        case .menu:    return KeyInfo(name: "Escape", code: "Escape", keyCode: 27)
        case .shift:   return KeyInfo(name: "Shift", code: "ShiftLeft", keyCode: 16)
        case .custom:
            guard let custom, !custom.isEmpty else { return nil }
            return customKeyInfo(custom)
        }
    }

    /// 把 "A" / "1" / "Space" / "F5" 这类写法转成 KeyboardEvent 需要的字段。
    static func customKeyInfo(_ raw: String) -> KeyInfo? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 过滤会破坏注入脚本的字符
        token = token.replacingOccurrences(of: "'", with: "")
        token = token.replacingOccurrences(of: "\\", with: "")
        token = token.replacingOccurrences(of: "\"", with: "")
        guard !token.isEmpty else { return nil }

        if token.count == 1, let scalar = token.uppercased().unicodeScalars.first {
            let upper = String(Character(scalar))
            if upper >= "A" && upper <= "Z" {
                let code = Int(scalar.value)
                return KeyInfo(name: token.lowercased(), code: "Key\(upper)", keyCode: code)
            }
            if upper >= "0" && upper <= "9" {
                return KeyInfo(name: token, code: "Digit\(token)", keyCode: Int(scalar.value))
            }
        }

        let named: [String: KeyInfo] = [
            "space": KeyInfo(name: " ", code: "Space", keyCode: 32),
            "enter": KeyInfo(name: "Enter", code: "Enter", keyCode: 13),
            "return": KeyInfo(name: "Enter", code: "Enter", keyCode: 13),
            "escape": KeyInfo(name: "Escape", code: "Escape", keyCode: 27),
            "esc": KeyInfo(name: "Escape", code: "Escape", keyCode: 27),
            "tab": KeyInfo(name: "Tab", code: "Tab", keyCode: 9),
            "shift": KeyInfo(name: "Shift", code: "ShiftLeft", keyCode: 16),
            "ctrl": KeyInfo(name: "Control", code: "ControlLeft", keyCode: 17),
            "alt": KeyInfo(name: "Alt", code: "AltLeft", keyCode: 18),
            "backspace": KeyInfo(name: "Backspace", code: "Backspace", keyCode: 8),
            "up": KeyInfo(name: "ArrowUp", code: "ArrowUp", keyCode: 38),
            "down": KeyInfo(name: "ArrowDown", code: "ArrowDown", keyCode: 40),
            "left": KeyInfo(name: "ArrowLeft", code: "ArrowLeft", keyCode: 37),
            "right": KeyInfo(name: "ArrowRight", code: "ArrowRight", keyCode: 39)
        ]
        if let match = named[token.lowercased()] { return match }

        if token.lowercased().hasPrefix("f"),
           let number = Int(token.dropFirst()),
           (1...12).contains(number) {
            return KeyInfo(name: "F\(number)", code: "F\(number)", keyCode: 111 + number)
        }

        return KeyInfo(name: token, code: token, keyCode: 0)
    }
}

extension WebGameEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[WebGameEngine] navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = """
        document.addEventListener('contextmenu', function(e){ e.preventDefault(); });
        document.addEventListener('gesturestart', function(e){ e.preventDefault(); });
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

extension WebGameEngine: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

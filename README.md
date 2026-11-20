# RPG盒子 — iOS 端 RPG Maker 游戏播放器

在 iPhone / iPad 上导入并运行自己合法拥有的 RPG Maker 游戏。带可自定义虚拟键盘，可映射键盘按键，按游戏分别保存配置。

目标形态类似 App Store 上的 ArkRPG / Runa：一个外壳 + 多套运行时，游戏文件由用户自己导入。区别在于本项目不依赖订阅，完全本地运行。

## 当前状态

| 引擎 | 运行时 | 状态 |
|---|---|---|
| RPG Maker XP / VX / VX Ace | mkxp-z（Apple mobile fork，ANGLE → Metal） | **原生引擎已编进 App** |
| RPG Maker MV / MZ | 内置 WKWebView + 本地 HTTP 服务 | **可直接运行** |
| RPG Maker 2000 / 2003 | EasyRPG Player | 未接入（官方无 iOS 目标） |

XP / VX / VX Ace 走的是真正的原生 C++ 引擎：`libmkxpz-core.a` + 三个 Ruby 版本的 binding + SDL2 / pixman / OpenAL / physfs / FreeType / ANGLE 全部静态链接进 App，不经过任何转译层。

## 架构

```
SwiftUI 外壳
├── 游戏库（网格、封面、隐藏/删除）
├── 导入（ZIP → 解压 → 引擎识别 → 落盘）
└── Player
    ├── MV / MZ   → WebGameEngine（WKWebView + StaticFileServer + SwiftUI 手柄）
    └── XP/VX/VA  → MkxpSession
                      └─ RPGEngineHost（C 桥）→ mkxp_run_app
                                                  ├─ SDL 窗口（引擎自己泵 UIKit）
                                                  └─ GamepadOverlayView（UIKit 手柄）
```

两条链路的界面实现不同，这是被迫的：原生引擎跑起来后会**占住主线程**直到游戏结束，SwiftUI 在这期间停止刷新，所以游戏内的虚拟手柄必须是挂在引擎 `UIWindow` 上的 UIKit 视图。

MV/MZ 之所以需要本地 HTTP 服务，是因为游戏用 `XMLHttpRequest` 读 `data/*.json`，`file://` 协议会被 WebKit 的跨域策略拦住，直接白屏。

## 目录

```
ios-rpg-player/
├── project.yml                   # XcodeGen 工程定义（不提交 .xcodeproj）
├── Config/Engine.xcconfig        # 引擎静态库的链接参数
├── Scripts/fetch_engine.sh       # 拉取并校验预编译引擎
├── Sources/
│   ├── App/                      # App 入口
│   ├── Models/                   # EngineType、Game、ControlLayout
│   ├── Library/                  # 游戏库、导入、GameStore
│   ├── Engines/
│   │   ├── GameEngine.swift      # Web 引擎协议与工厂
│   │   ├── WebGameEngine.swift   # MV/MZ
│   │   ├── MkxpSession.swift     # 原生会话调度
│   │   ├── Scancode.swift        # HID 扫描码映射
│   │   └── Host/                 # RPGEngineHost.h/.m（C 桥）
│   ├── Controls/                 # SwiftUI 手柄（Web）+ UIKit 手柄（原生）
│   ├── Player/                   # 播放页
│   └── Support/                  # 路径、静态文件服务、bridging header
├── Vendor/                       # 引擎二进制（脚本生成，不入库）
└── docs/
```

## 构建

需要 macOS 26 + Xcode 26 以上（iOS 26 SDK）。引擎的静态库是用 iOS 26.5 SDK 编译的，
用旧 Xcode 链接会报「object file was built for a newer SDK」一类的错。

```bash
cd ios-rpg-player
sh Scripts/fetch_engine.sh        # 下载引擎 v24 + ANGLE，校验 sha256，约 112 MB
brew install xcodegen
xcodegen generate
open RPGPlayer.xcodeproj
```

没有 Mac 就走云端：推到 GitHub → Actions → **Build unsigned IPA** → 下载 `RPGPlayer-unsigned-ipa`，用 Sideloadly 签名装机。详见 [docs/构建与侧载.md](docs/构建与侧载.md)。

引擎怎么接的、为什么这么接，见 [docs/引擎接入.md](docs/引擎接入.md)。

## 三条必须先知道的限制

1. **一个进程只能玩一个 Ruby 游戏。** CRuby 的 `ruby_init()` 每进程只能调用一次，这是引擎层面的约束（同类应用 Empo 也一样）。退出游戏后要从后台划掉 App 再重开，才能启动另一个 XP/VX/VA 游戏。MV/MZ 不受影响。
2. **包体积会到 100 MB 上下。** 三个 Ruby 运行时 + 全套图形/音频库是静态链进二进制的，不是可选下载。
3. **游戏内改键位只支持拖动位置。** 大小、透明度、新增自定义按键在播放页外编辑；拖动结果在会话结束时写盘。

## 已知限制

- **必须签名才能安装**。未签名 IPA 只能通过 AltStore / Sideloadly 用你的 Apple ID 重签。
- **免费 Apple ID 签的证书 7 天过期**，需要重签；$99/年开发者账号可签 1 年。
- **仅支持 ZIP 导入**。RAR / 7z 需要额外解压库，暂未接入。
- **MV/MZ 的加密游戏**（`www` 下有 `.rpgmvp` / `.rpgmvo` 等加密资源）无法直接运行，需要先解密。
- **不支持 RM95 及更早版本**，没有可用的开源运行时。
- 自用侧载不涉及分发，GPL 义务不触发；如果将来要上架或公开分发，mkxp-z 和 EasyRPG 的 GPL v2 需要单独处理。

## 键盘映射速查

| 功能 | MV/MZ | XP/VX/VA（HID 扫描码） | 2000/2003 |
|---|---|---|---|
| 方向 | 方向键 | 79 / 80 / 81 / 82 | 方向键 |
| 确认 | Enter (13) | 40（Return = Input::C） | Decision |
| 取消 | Escape (27) | 41（Escape = Input::B） | Cancel |
| 主页 | Escape (27) | 27（X 键） | Cancel |
| 加速 | Shift (16) | 225（左 Shift = Input::A） | Shift |

自定义按键支持单个字母或数字（`A`、`1`）、功能键（`F1`–`F12`）、`Space` / `Enter` / `Esc` / `Tab` / `Shift` / `Ctrl`，以及直接写 `hid:82` 这样的原始扫描码。

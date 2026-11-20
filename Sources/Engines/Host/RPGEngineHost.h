//
//  RPGEngineHost.h
//  宿主与 mkxp 引擎之间的 C 接口。
//
//  为什么还要这一层：mkxp 的 app_bridge.h 要求宿主严格按顺序调用
//  十来个 C 函数，并且大量参数是裸指针 + 在引擎线程回调。把这些搬进
//  Swift 会让字符串生命周期、回调函数指针、线程切换散落各处。
//  这里包成「填一个结构体 → prepare → run」，Swift 只面对值类型。
//
//  引擎未链接时（Vendor 没拉取、或只做 WebView 构建），
//  所有函数降级为空实现，rpg_engine_available() 返回 false。
//

#ifndef RPG_ENGINE_HOST_H
#define RPG_ENGINE_HOST_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    /// 已配置好，可以调用 rpg_run()
    RPGRunOK = 0,
    /// 当前构建没有链接引擎二进制
    RPGRunNotLinked = 1,
    /// 已经有一个会话在跑（本进程只允许一个）
    RPGRunAlreadyRunning = 2,
    /// 参数不合法（gameDirectory 为空）
    RPGRunBadOptions = 3,
} RPGRunResult;

typedef struct {
    /// 游戏目录绝对路径，必填。引擎会把它设为工作目录。
    const char *gameDirectory;
    /// 可写的存档目录（Documents 下按游戏分开）
    const char *userDataDirectory;
    /// 宿主生成的配置目录（mkxp.json / patches.json）
    const char *managedConfigDir;
    /// 调试日志文件路径，可为 NULL
    const char *logFile;
    /// CA 证书包路径（Assets.bundle/cacert.pem），可为 NULL
    const char *caBundle;

    /// 18 = Ruby 1.8（XP），19 = Ruby 1.9（VX），31 = Ruby 3.1（VX Ace）
    int rubyVersion;
    /// "legacy" / "modern"，NULL 表示不设置
    const char *syntaxTransform;
    /// 0 = 顶部，1 = 顶部居中，2 = 居中
    int verticalAlignment;
} RPGSessionOptions;

typedef struct {
    /// 游戏正常结束（含游戏内退出到桌面）
    void (*onTerminated)(void *context);
    /// 引擎报错，UI 展示后必须调用 rpg_dismiss_error()
    void (*onError)(const char *message, void *context);
    /// 引擎的 msgbox / p 之类提示，UI 展示后调用 rpg_dismiss_info()
    void (*onInfo)(const char *message, void *context);
    /// 恢复或首次启动后的第一帧已上屏
    void (*onFrameRendered)(void *context);
    void *context;
} RPGCallbacks;

/// 注册回调。必须在 rpg_prepare 之前调用；context 原样回传。
void rpg_set_callbacks(const RPGCallbacks *callbacks);

/// 当前构建是否链接了引擎。
bool rpg_engine_available(void);

/// 按引擎要求的顺序配置会话（不启动）。成功后必须再调用 rpg_run()。
RPGRunResult rpg_prepare(const RPGSessionOptions *options);

/// 运行引擎。**必须在主线程、从 run loop 定时器里调用**，
/// 它会一直占住该线程直到游戏结束，返回值为引擎退出码。
///
/// 不要从 dispatch 主队列的 block 里调用：主队列永远不会排空，
/// 引擎的 RGSS 线程会在第一次 mkxp_getScreenScale 处死锁。
int rpg_run(void);

/// 请求结束当前会话。引擎会在下一帧退出，rpg_run() 随之返回。
void rpg_terminate(void);

/// 引擎是否已经初始化完毕（可以挂虚拟手柄了）。
bool rpg_is_ready(void);

/// 会话是否仍在运行。
bool rpg_is_running(void);

/// 注入一个按键事件。scancode 用 HID 用法码（见 MKXP_SCANCODE_*）。
void rpg_send_key(int scancode, int pressed);

/// 引擎绘制所在的 UIWindow*，未创建时返回 NULL。不要 retain。
void *rpg_game_window(void);

/// 安全区内边距（pt），主线程调用。
void rpg_set_safe_area(float top, float bottom, float left, float right);

/// 把游戏画面限制在窗口的一块区域内（0...1 的比例）。
void rpg_set_viewport(float x, float y, float w, float h, bool portrait);
void rpg_clear_viewport(void);

/// 引擎状态文字，用于调试面板。空字符串表示没有内容。
const char *rpg_details(void);

/// 错误 / 提示弹窗关闭后必须调用，否则引擎线程会一直阻塞。
void rpg_dismiss_error(void);
void rpg_dismiss_info(void);

#ifdef __cplusplus
}
#endif

#endif /* RPG_ENGINE_HOST_H */

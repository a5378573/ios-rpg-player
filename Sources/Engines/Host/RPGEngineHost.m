//
//  RPGEngineHost.m
//  mkxp app_bridge.h 的 Objective-C 封装。
//
//  只做三件事：
//   1. 把 Swift 传来的值拷成引擎生命期内的 C 字符串；
//   2. 按上游要求的顺序调用 mkxp_* 接口；
//   3. 把引擎线程的回调转给宿主，并保证弹窗关闭后放行引擎线程。
//

#import "RPGEngineHost.h"
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if __has_include("app_bridge.h")
#import "app_bridge.h"
#define RPG_HAS_MKXP 1
#else
#define RPG_HAS_MKXP 0
#endif

#pragma mark - 状态

static RPGCallbacks gCallbacks;

static char *gGameDirectory = NULL;
static char *gUserDataDirectory = NULL;
static char *gManagedConfigDir = NULL;
static char *gLogFile = NULL;
static char *gCABundle = NULL;
static char *gSyntaxTransform = NULL;
static char *gArgv0 = NULL;

static int gRubyVersion = 31;
static int gVerticalAlignment = 1;

static BOOL gPrepared = NO;
static BOOL gRunning = NO;

/// 释放并在需要时复制字符串。NULL / 空串都存成 NULL。
static void RPGCopyString(char **slot, const char *value) {
    if (*slot != NULL) {
        free(*slot);
        *slot = NULL;
    }
    if (value != NULL && value[0] != '\0') {
        *slot = strdup(value);
    }
}

static void RPGResetSessionState(void) {
    RPGCopyString(&gGameDirectory, NULL);
    RPGCopyString(&gUserDataDirectory, NULL);
    RPGCopyString(&gManagedConfigDir, NULL);
    RPGCopyString(&gLogFile, NULL);
    RPGCopyString(&gCABundle, NULL);
    RPGCopyString(&gSyntaxTransform, NULL);
    RPGCopyString(&gArgv0, NULL);
    gPrepared = NO;
}

#pragma mark - 引擎回调

#if RPG_HAS_MKXP
static void RPGEngineTerminatedCallback(void *userdata) {
    (void)userdata;
    // 引擎线程，宿主要自己切到主线程
    if (gCallbacks.onTerminated) {
        gCallbacks.onTerminated(gCallbacks.context);
    }
}

static void RPGEngineErrorMessageCallback(const char *message, void *userdata) {
    (void)userdata;
    if (gCallbacks.onError) {
        gCallbacks.onError(message != NULL ? message : "", gCallbacks.context);
    }
}

static void RPGEngineInfoMessageCallback(const char *message, void *userdata) {
    (void)userdata;
    if (gCallbacks.onInfo) {
        gCallbacks.onInfo(message != NULL ? message : "", gCallbacks.context);
    }
}

static void RPGEngineFrameRenderedCallback(void *userdata) {
    (void)userdata;
    if (gCallbacks.onFrameRendered) {
        gCallbacks.onFrameRendered(gCallbacks.context);
    }
}
#endif

#pragma mark - 对外接口

void rpg_set_callbacks(const RPGCallbacks *callbacks) {
    if (callbacks != NULL) {
        gCallbacks = *callbacks;
    } else {
        memset(&gCallbacks, 0, sizeof(gCallbacks));
    }
}

bool rpg_engine_available(void) {
#if RPG_HAS_MKXP
    return true;
#else
    return false;
#endif
}

RPGRunResult rpg_prepare(const RPGSessionOptions *options) {
#if RPG_HAS_MKXP
    if (options == NULL || options->gameDirectory == NULL || options->gameDirectory[0] == '\0') {
        return RPGRunBadOptions;
    }
    if (gRunning) {
        return RPGRunAlreadyRunning;
    }

    // 上一场残留（例如异常退出后重开）先清掉
    RPGResetSessionState();

    RPGCopyString(&gGameDirectory, options->gameDirectory);
    RPGCopyString(&gUserDataDirectory, options->userDataDirectory);
    RPGCopyString(&gManagedConfigDir, options->managedConfigDir);
    RPGCopyString(&gLogFile, options->logFile);
    RPGCopyString(&gCABundle, options->caBundle);
    RPGCopyString(&gSyntaxTransform, options->syntaxTransform);

    gRubyVersion = options->rubyVersion > 0 ? options->rubyVersion : 31;
    gVerticalAlignment = options->verticalAlignment;

    // argv[0] 只在引擎内部当日志与 rtData.argv0 用，取可执行文件路径最稳。
    NSString *executable = [[NSBundle mainBundle] executablePath];
    if (executable == nil) {
        executable = @"RPGPlayer";
    }
    RPGCopyString(&gArgv0, executable.UTF8String);

    // 1) 日志。放在最前面，后面每一步失败都能落到文件里。
    mkxp_setDebugLogPath(gLogFile);

    // 2) 身份与证书。CA 包不设，TLS 会直接失败（明文 http 不受影响）。
    mkxp_setLauncherIdentity("RPGPlayer", "1.0");
    mkxp_setCABundlePath(gCABundle);

    // 3) 每游戏设置。rubyVersion 决定走哪个 Ruby VM：
    //    XP 用 1.8，VX 用 1.9，VX Ace 用 3.1。
    char rubyBuffer[8] = {0};
    snprintf(rubyBuffer, sizeof(rubyBuffer), "%d", gRubyVersion);
    mkxp_setSetting("rubyVersion", rubyBuffer);

    if (gSyntaxTransform != NULL) {
        mkxp_setSetting("syntaxTransform", gSyntaxTransform);
    }
    // 预加载兼容层（win32 垫片、存档路径重定向）必须有，
    // 否则大量 Windows 游戏读不到文件。
    mkxp_setSetting("postloadScripts", "1");
    // 用系统软键盘，不用游戏自绘键盘。
    mkxp_setSetting("inGameKeyboard", "0");
    // JoiPlay 兼容开关默认关：它会让部分游戏走 JoiPlay 专用分支，
    // 而这些分支在 iOS 上不一定成立。
    mkxp_setSetting("joiplayCompat", "0");
    // 默认离线：不介入游戏的联网逻辑。
    mkxp_setSetting("networkEnabled", "0");

    // 4) 会话配置
    MKXPSessionConfig config = (MKXPSessionConfig){0};
    config.managedConfigDir = gManagedConfigDir;
    config.userDataDirectory = gUserDataDirectory;
    config.sharedFontsDirectory = NULL;
    config.verticalAlignment = (MKXPVerticalAlignment)gVerticalAlignment;
    mkxp_applySessionConfig(&config);
    mkxp_applyPerGameSettings((MKXPVerticalAlignment)gVerticalAlignment, true);

    // 5) 会话级状态复位。必须在 applySessionConfig 之后、setGamePath 之前。
    mkxp_resetSessionState();

    // 6) 选游戏。引擎此时可能还阻塞在 mkxp_waitForGamePath()，这一句放行。
    mkxp_setGamePath(gGameDirectory);

    // 7) 回调与输入策略
    mkxp_setEngineTerminatedCallback(RPGEngineTerminatedCallback, NULL);
    mkxp_setErrorMessageCallback(RPGEngineErrorMessageCallback, NULL);
    mkxp_setInfoMessageCallback(RPGEngineInfoMessageCallback, NULL);
    mkxp_setFrameRenderedCallback(RPGEngineFrameRenderedCallback, NULL);

    // 触摸不作为鼠标传给游戏：虚拟手柄走按键注入，画面本身不需要点击。
    mkxp_setTouchMouseEnabled(false);
    // 手柄交给引擎自己读（MFi / Xbox / PS 手柄开箱可用）。
    mkxp_setGameControllerCaptureEnabled(true);

    gPrepared = YES;
    return RPGRunOK;
#else
    (void)options;
    return RPGRunNotLinked;
#endif
}

int rpg_run(void) {
#if RPG_HAS_MKXP
    if (!gPrepared) {
        return 1;
    }

    gRunning = YES;
    char *argv[2];
    argv[0] = gArgv0 != NULL ? gArgv0 : (char *)"RPGPlayer";
    argv[1] = NULL;

    // 阻塞，直到游戏结束。主线程在此期间由 SDL 的事件泵驱动 UIKit。
    int status = mkxp_run_app(1, argv);

    gRunning = NO;
    gPrepared = NO;
    return status;
#else
    return 1;
#endif
}

void rpg_terminate(void) {
#if RPG_HAS_MKXP
    mkxp_requestTerminate();
#endif
}

bool rpg_is_ready(void) {
#if RPG_HAS_MKXP
    return gRunning && mkxp_isGameReady() != 0;
#else
    return false;
#endif
}

bool rpg_is_running(void) {
    return gRunning ? true : false;
}

void rpg_send_key(int scancode, int pressed) {
#if RPG_HAS_MKXP
    if (!gRunning) {
        return;
    }
    mkxp_injectKeyEvent(scancode, pressed ? 1 : 0);
#else
    (void)scancode;
    (void)pressed;
#endif
}

void *rpg_game_window(void) {
#if RPG_HAS_MKXP
    return mkxp_getGameWindow();
#else
    return NULL;
#endif
}

void rpg_set_safe_area(float top, float bottom, float left, float right) {
#if RPG_HAS_MKXP
    mkxp_setSafeAreaInsets(top, bottom, left, right);
#else
    (void)top; (void)bottom; (void)left; (void)right;
#endif
}

void rpg_set_viewport(float x, float y, float w, float h, bool portrait) {
#if RPG_HAS_MKXP
    mkxp_setHostViewportRegion(x, y, w, h, portrait);
#else
    (void)x; (void)y; (void)w; (void)h; (void)portrait;
#endif
}

void rpg_clear_viewport(void) {
#if RPG_HAS_MKXP
    mkxp_clearHostViewportRegion();
#endif
}

const char *rpg_details(void) {
#if RPG_HAS_MKXP
    const char *details = mkxp_getDetails();
    return details != NULL ? details : "";
#else
    return "";
#endif
}

void rpg_dismiss_error(void) {
#if RPG_HAS_MKXP
    mkxp_signalErrorDismissed();
#endif
}

void rpg_dismiss_info(void) {
#if RPG_HAS_MKXP
    mkxp_signalInfoDismissed();
#endif
}

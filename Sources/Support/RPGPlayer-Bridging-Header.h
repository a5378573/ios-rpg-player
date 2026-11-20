//
//  RPGPlayer-Bridging-Header.h
//  Swift 只能看到我们自己那层稳定的 C 接口。
//
//  不要在这里 import app_bridge.h：那是引擎的原始接口，有一百多个
//  函数和裸指针参数，暴露给 Swift 既容易误用，也会让引擎未链接时的
//  构建直接失败。所有调用都走 RPGEngineHost。
//

#import "RPGEngineHost.h"

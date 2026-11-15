#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <unistd.h>

/*
 AtriaScaleNoAnim
 ----------------
 目的：消除 iOS 17 上滑返回桌面时，图标「先恢复原始大小、再渐变变小」的闪回。

 原理
 ----
 Atria 把图标缩放写成 layer.sublayerTransform = MakeScale(0.8, 0.8, 1)。
 但它写入时没有禁用 Core Animation 的隐式动画。

 iOS 17 的 app-to-home 转场（SBScaleIconZoomAnimator 等）会把刚退出的那个
 图标的 layer 复位/重建为 identity(1.0)。Atria 随后写回 0.8 时，Core Animation
 自动创建一条 0.25s 的隐式动画：identity -> 0.8。
 视觉上就是「图标先弹回原始大小，再慢慢缩回设定尺寸」。

 Dock 图标不参与该转场，layer 从未被复位，也没有新的写入，所以不闪。

 修法
 ----
 在 -[CALayer setSublayerTransform:] 上，对 SBIconView 的 backing layer
 用 CATransaction 关闭隐式动画（setDisableActions:YES），让写入瞬时生效。

 兼容性说明
 ----------
 Atria 编辑模式下的缩放动画是显式 addAnimation:，不受 setDisableActions 影响，
 因此拖动图标时的缩放过渡保持不变。

 本插件只改「写入方式」，不改任何缩放数值，也不改变 Atria 的判断逻辑。
*/

static Class AZNIconViewClass(void) {
    static Class cls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_getClass("SBIconView"); });
    return cls;
}

/* 判断某个 layer 是否是图标视图的 backing layer */
static BOOL AZNIsIconLayer(CALayer *layer) {
    if (!layer) return NO;
    Class iconCls = AZNIconViewClass();
    if (!iconCls) return NO;
    id delegate = nil;
    @try {
        delegate = layer.delegate;
    } @catch (__unused NSException *e) {
        return NO;
    }
    if (!delegate) return NO;
    @try {
        return [delegate isKindOfClass:iconCls];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

/* 自检：确认插件真的被加载 */
static void AZNWriteMarker(void) {
    NSArray *paths = @[
        @"/var/mobile/Library/Caches/AtriaScaleNoAnim.loaded",
        @"/var/tmp/AtriaScaleNoAnim.loaded"
    ];
    NSString *text = [NSString stringWithFormat:
        @"AtriaScaleNoAnim loaded\nSBIconView=%@\npid=%d\n",
        AZNIconViewClass() ? @"YES" : @"NO", getpid()];
    for (NSString *p in paths) {
        [text writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

%hook CALayer

- (void)setSublayerTransform:(CATransform3D)t {
    if (AZNIsIconLayer(self)) {
        /*
         关键：禁用本次写入的隐式动画。
         用嵌套事务，不影响外层 SpringBoard 转场事务的其它属性。
        */
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        %orig(t);
        [CATransaction commit];
        return;
    }
    %orig(t);
}

%end

%ctor {
    AZNWriteMarker();
}

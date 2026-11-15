/**
 * AtriaZoomGuard — Tweak.x
 *
 * 问题：iOS 17 上，Atria / CySxL Atria 修改 Icon Scale 后，「上滑返回桌面」
 *       时刚退出那个 app 的图标会先恢复原始尺寸、再变回修改后的尺寸。
 *       用户已验证：开启「减弱动态效果」后闪回消失 —— 说明闪回来自
 *       iOS 17 的 scale-zoom 转场（SBScaleIconZoomAnimator 一类），而不是
 *       Atria 内部的值写入。
 *
 * 机制：转场期间该图标 layer 的 sublayerTransform 被写回 identity(1.0)，
 *       Atria 随后才补写自定义缩放，形成跨帧可见的「1.0 -> 0.8」跳变。
 *       Dock 图标不参与单图标 zoom，所以不闪。
 *
 * 做法：在 CALayer 层兜住所有写入方（不 hook Atria 的任何方法）：
 *   1. 记住每个 SBIconView.layer 最后一次「非 1.0」的 sublayerTransform.m11，
 *      即 Atria 写入的目标缩放（guard）。
 *   2. 之后任何人试图把同一 layer 写回 1.0，直接压制、不放行。
 *   3. 用 0.5s 延迟确认区分「转场瞬时归位」与「用户真的把缩放设回 1.0」：
 *      待决期间只要 Atria 再写过任何非 1.0 值，待决立即取消（转场结束后
 *      Atria 会重新写 0.8）。真关闭时才无动画补写一次 identity。
 *   4. 可选：layoutSubviews 里无动画回写 guard，覆盖视图重建等边界。
 *
 * 约束：全程只跑 SpringBoard 主线程；不使用 block、不捕获 self、不调用
 *       私有类方法、不依赖 Atria 内部符号；ARC / MRC 均可编译。
 */

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>

/* ==================== 可调参数 ==================== */
#define AZG_DEBUG_LOG       1     /* 写日志，便于确认「拦到了归位写入」 */
#define AZG_LAYOUT_RESTORE  1     /* layoutSubviews 二次回写（建议开） */
#define AZG_CONFIRM_DELAY   0.5   /* 判定「用户关闭缩放」的延迟，秒 */
#define AZG_EPS             0.002 /* 浮点比较容差 */
#define AZG_LOG_MAX         400   /* 日志行数上限，防止刷屏 */
#define AZG_LOG_PATH        "/var/mobile/Library/Logs/AtriaZoomGuard.log"
#define AZG_MARK_PATH_A     "/var/mobile/Library/Caches/AtriaZoomGuard.loaded"
#define AZG_MARK_PATH_B     "/var/tmp/AtriaZoomGuard.loaded"

/* ==================== 内部状态 ==================== */
static char kGuardKey;    /* NSNumber：该 layer 的目标缩放；nil = 无 */
static char kPendingKey;  /* NSNumber：首次检测到 identity 归位的时间戳 */
static int  gLogLines = 0;
static BOOL gRestoring = NO;   /* 我们自己的无动画回写，避免递归与自记录 */

static void AZGLog(const char *fmt, ...) {
#if AZG_DEBUG_LOG
    if (gLogLines >= AZG_LOG_MAX) return;
    gLogLines++;
    FILE *f = fopen(AZG_LOG_PATH, "a");
    if (!f) f = fopen("/var/tmp/AtriaZoomGuard.log", "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
#else
    (void)fmt;
#endif
}

static void AZGWriteMarker(BOOL iconClassFound) {
    const char *paths[] = { AZG_MARK_PATH_A, AZG_MARK_PATH_B };
    for (int i = 0; i < 2; i++) {
        FILE *f = fopen(paths[i], "w");
        if (!f) continue;
        fprintf(f, "AtriaZoomGuard 1.0.0 LOADED\n");
        fprintf(f, "SBIconView=%s\n", iconClassFound ? "YES" : "NO");
        fprintf(f, "debugLog=%d layoutRestore=%d confirmDelay=%.2f\n",
                AZG_DEBUG_LOG, AZG_LAYOUT_RESTORE, (double)AZG_CONFIRM_DELAY);
        fprintf(f, "log=%s\n", AZG_LOG_PATH);
        fclose(f);
    }
}

static Class AZGIconClass(void) {
    static Class c = Nil;
    if (!c) c = objc_getClass("SBIconView");
    return c;
}

static BOOL AZGIsIdentity(CGFloat s) {
    return s <= 0.001 || fabs((double)s - 1.0) <= AZG_EPS;
}

/* 只认 Atria 的 CATransform3DMakeScale(s, s, 1)，
   避免把系统转场动画里的临时变换误记成目标缩放 */
static BOOL AZGLooksLikeIconScale(CATransform3D t) {
    return fabs((double)(t.m11 - t.m22)) <= AZG_EPS
        && fabs((double)t.m33 - 1.0) <= AZG_EPS
        && t.m11 > 0.2 && t.m11 < 3.0;
}

static BOOL AZGIsIconLayer(CALayer *layer) {
    Class c = AZGIconClass();
    id del = [layer delegate];
    return (c && del && [del isKindOfClass:c]);
}

/* 无动画写入：既避免隐式 CAAnimation，也避免被本 tweak 自己的 hook 再拦一次 */
static void AZGForceWrite(CALayer *layer, CATransform3D t) {
    gRestoring = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer setSublayerTransform:t];
    [CATransaction commit];
    gRestoring = NO;
}

/* layoutSubviews 二次保险：guard 存在且当前值偏离时，无动画回写 */
static void AZGRestoreIfNeeded(CALayer *layer) {
    NSNumber *pending = objc_getAssociatedObject(layer, &kPendingKey);
    if (pending && (CACurrentMediaTime() - [pending doubleValue] > AZG_CONFIRM_DELAY)) {
        /* 超时且期间没有任何非 1.0 写入 → 用户真的关闭了缩放 */
        objc_setAssociatedObject(layer, &kGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(layer, &kPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        AZGLog("confirm close -> write identity");
        AZGForceWrite(layer, CATransform3DIdentity);
        return;
    }

    NSNumber *g = objc_getAssociatedObject(layer, &kGuardKey);
    if (!g) return;
    CGFloat target = (CGFloat)[g doubleValue];
    CGFloat cur = [layer sublayerTransform].m11;
    if (fabs((double)(cur - target)) > 0.01) {
        AZGForceWrite(layer, CATransform3DMakeScale(target, target, 1));
    }
}

/* 让 Logos 认识这个私有类（运行时由 dyld 解析，无需链接私有框架） */
@interface SBIconView : UIView
@end

%hook CALayer

- (void)setSublayerTransform:(CATransform3D)t {
    /* 我们自己的无动画回写：直接放行，不记录、不递归 */
    if (gRestoring) {
        %orig(t);
        return;
    }
    /* 只处理 SBIconView（含子类）的 backing layer */
    if (!AZGIsIconLayer(self)) {
        %orig(t);
        return;
    }

    CGFloat s = t.m11;
    NSNumber *guard = objc_getAssociatedObject(self, &kGuardKey);

    /* --- 非 1.0 写入：只把「等比缩放」当作 Atria 的目标缩放记住 --- */
    if (!AZGIsIdentity(s)) {
        if (AZGLooksLikeIconScale(t)) {
            objc_setAssociatedObject(self, &kGuardKey, @(s), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        %orig(t);   /* 无论是否记录都放行，绝不干扰 Atria 的正常写入 */
        return;
    }

    /* --- 有人想把图标归位成 1.0 --- */
    if (!guard) {
        %orig(t);   /* 本来就没有缩放，正常放行 */
        return;
    }

    NSNumber *pending = objc_getAssociatedObject(self, &kPendingKey);
    CFTimeInterval now = CACurrentMediaTime();

    if (pending && (now - [pending doubleValue] > AZG_CONFIRM_DELAY)) {
        /* 判定：用户真的把缩放设回了 1.0（期间 Atria 再没写过非 1.0） */
        objc_setAssociatedObject(self, &kGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        AZGLog("confirm close: guard was %.4f -> identity", [guard doubleValue]);
        AZGForceWrite(self, CATransform3DIdentity);
        return;
    }

    if (!pending) {
        objc_setAssociatedObject(self, &kPendingKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        AZGLog("suppress identity: guard=%.4f", [guard doubleValue]);
    }

    /* 关键：压制这次归位写入。layer 保持 Atria 的目标缩放，不出现 1.0 帧 */
    return;
}

%end

%hook UIView

- (void)layoutSubviews {
    %orig;
#if AZG_LAYOUT_RESTORE
    Class iconCls = AZGIconClass();
    if (!iconCls || ![self isKindOfClass:iconCls]) return;
    AZGRestoreIfNeeded([self layer]);
#endif
}

%end

%ctor {
    %init;
    @autoreleasepool {
        BOOL found = (AZGIconClass() != Nil);
        AZGWriteMarker(found);
        NSLog(@"[AtriaZoomGuard] 1.0.0 loaded, SBIconView=%@", found ? @"YES" : @"NO");
        AZGLog("=== LOADED 1.0.0 SBIconView=%s ===", found ? "YES" : "NO");
    }
}

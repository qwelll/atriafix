# AtriaScaleNoAnim

修复 Atria 在 iOS 17 上滑返回桌面时，图标「先恢复原始大小、再渐变变小」的闪回。

不改 Atria 本体，不改任何缩放数值，只改 Core Animation 的写入方式。

---

## 这版和之前几版有什么不同

之前所有尝试都在改「谁写了 1.0」：Atria 的归位分支、取值回退、二进制指令。
你这个现象用「写 1.0」解释不通，因为：

- 你装了禁用归位写入的 1.9.3 补丁包，**仍然闪**；
- 你装了拦截 identity 写入的 guard，**仍然闪**。

真正的机制是**隐式动画**，源码里能直接看到：

```objc
// Atria 1.9.3  src/Hooks/IconView.xm  第 194-222 行
void (^resize)() = ^void() {
    self.layer.sublayerTransform = CATransform3DMakeScale(customScale, customScale, 1);
};

if([ARIEditManager sharedInstance].isEditing) {
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.2f];      // 编辑模式才走这条
    ...
} else {
    resize();                                       // ← 平时走这条，没有任何事务包裹
    [self _atriaGenerateDropShadow:self.bounds];
}
```

`resize()` 直接写 layer 属性，**没有 `setDisableActions:YES`**。

iOS 17 的 app-to-home 转场会把刚退出那个图标的 layer 复位/重建为 identity(1.0)。
Atria 随后写回 0.8 —— Core Animation 发现属性和当前模型值不同，自动补一条
**0.25 秒隐式动画**：`identity → 0.8`。

你看到的就是：图标先弹回原始大小，然后被这条动画缩回去。

三个观察全部对上：

| 观察 | 解释 |
|---|---|
| 只有上滑退出的那个图标闪 | 只有它的 layer 被转场复位 |
| Dock 图标从不闪 | Dock 不参与该转场，layer 没被复位、没有新写入 |
| 关掉动画就不闪 | crossfade 不重建图标 layer，不产生 identity→0.8 的过渡 |

**所以前几次全打偏了：不是「写错了值」，是「写入被动画化了」。**

---

## 修法

在 `-[CALayer setSublayerTransform:]` 上，对 `SBIconView` 的 backing layer
用嵌套 `CATransaction` 关闭隐式动画：

```objc
- (void)setSublayerTransform:(CATransform3D)t {
    if (AZNIsIconLayer(self)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        %orig(t);
        [CATransaction commit];
        return;
    }
    %orig(t);
}
```

写入瞬时生效，不再有 identity→0.8 的过渡。

**不影响 Atria 编辑模式的缩放动画**：那条动画是显式 `addAnimation:forKey:`，
`setDisableActions` 只关隐式 action，显式动画照常播放。

---

## 编译

需要 Theos + iOS SDK（你已有）。

```bash
cd AtriaScaleNoAnim
make clean package FINALPACKAGE=1
```

产物：`packages/com.qwelll.atriascalenoanim_1.0.0_iphoneos-arm64e.deb`

`Makefile` 已设 `THEOS_PACKAGE_SCHEME = roothide`、`ARCHS = arm64 arm64e`、
`TARGET = iphone:clang:latest:15.0`。SDK 版本不同就改 `TARGET` 这一行。

如果 Theos 报 `TARGET` 相关错误，改成你本机实际版本，例如：

```make
export TARGET = iphone:clang:16.5:15.0
```

---

## 安装

1. 先卸载之前装的 `AtriaIconScaleDiag`（避免安全模式残留）。
2. 安装本 deb。
3. Respring。

不需要卸载 Atria，1.4.1-11 和 1.9.3 都能用（本插件不依赖 Atria 任何符号）。

---

## 验证是否真的加载了

Respring 后看这两个文件是否存在任一：

```
/var/mobile/Library/Caches/AtriaScaleNoAnim.loaded
/var/tmp/AtriaScaleNoAnim.loaded
```

内容应是：

```
AtriaScaleNoAnim loaded
SBIconView=YES
pid=xxxx
```

- 文件不存在 → 插件没加载，别测了，告诉我，换编译方式排查。
- 存在但 `SBIconView=NO` → SpringBoard 里没找到 SBIconView 类，判断逻辑会失效，把内容发我。

---

## 测试

1. Atria 里 Icon Scale 设 0.8。
2. 打开任意 App → 上滑返回桌面，停 2 秒。
3. 重复 10 次。

预期：图标从转场结束到显示，**直接就是 0.8**，没有「弹回原大小再缩」的两段式。

再顺手验一下：
- 编辑模式长按抖动、拖动图标 → 缩放过渡应当仍有 0.2s 动画（显式动画未被禁用）；
- 把 Icon Scale 从 0.8 改成 1.3 → 应当瞬时切换；
- Dock、文件夹、小组件。

---

## 如果还是闪

那说明写入被动画化不是唯一原因，剩下两种可能：

1. **layer 被整体替换**，新 layer 渲染的第一帧就是 identity，Atria 的写入发生在该帧之后。
   这时把本插件扩展成「在 `SBIconView didMoveToWindow` 里同步重算」即可，告诉我我再给。
2. **系统 animator 对 `sublayerTransform` 加了显式 `CABasicAnimation`**。
   这种情况要在 `-[CALayer addAnimation:forKey:]` 上过滤，同样是加一个 hook 的事。

无论哪种，请把下面这条信息发我，能直接判断：

> `SBIconView=YES` 吗？闪回是「一帧跳变」还是「约 0.25 秒的渐变」？

---

## 已知取舍

- 禁用隐式动画后，Atria 平时调整缩放（非编辑模式）会是瞬时变化，不再有 0.25s 过渡。
  这正是修复目标；编辑模式的动画不受影响。
- 插件只 hook `CALayer` 且 filter 限定 `com.apple.springboard`，不注入其它进程。

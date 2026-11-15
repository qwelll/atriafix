# AtriaZoomGuard

独立 tweak 源码，**不修改 Atria 任何文件**。修复 iOS 17 上 Atria 修改 Icon Scale 后，上滑返回桌面时「刚退出那个 app 的图标」先恢复原始尺寸、再变回修改尺寸的闪回。

适用于 `me.lau.atria 1.4.1-11`（rootless-compat 二进制补丁版）和 `com.cysxl.atria 1.9.3`（原生 roothide fork）——本 tweak 不依赖 Atria 的任何类或符号，换版本不会失效。

---

## 1. 为什么这样写

你已验证：**开启「减弱动态效果」后闪回消失**。Apple 官方说明该设置会把 app 开关的 zoom 动画换成 dissolve/crossfade。结合 iOS 17.1 `SpringBoardHome.framework` 新增的 `SBScaleIconZoomAnimator` / `SBCrossfadeIconZoomAnimator` / `SBReversibleLayerPropertyAnimator`，可以确定：

- 上滑退出 app 时，系统**只对那一个图标**做 scale-zoom 转场；其他图标整体淡入、Dock 常驻不参与 → 所以只有它闪、Dock 不闪。
- 转场期间/收尾时该图标 layer 的 `sublayerTransform` 被写回 `identity`（m11 = 1.0），Atria 随后才补写自定义缩放（0.8），形成跨帧可见的「1.0 → 0.8」跳变。
- 因此**改 Atria 内部的缩放函数没有用**（写入方是系统转场，不是 Atria）；正确挂点是 `-[CALayer setSublayerTransform:]`，兜住所有写入方。

前几轮改造/编译的二进制在你设备上出现「无 log / 安全模式」，是本地零 SDK 编译产物加载不可靠。这次给你**标准 Theos 源码**，由你用真实 SDK 编译，避开这个问题。

---

## 2. 文件清单

| 文件 | 作用 |
|---|---|
| `Tweak.x` | 全部逻辑（约 200 行，注释完整，可直接改） |
| `Makefile` | Theos 构建配置，已设 `THEOS_PACKAGE_SCHEME = roothide` |
| `control` | deb 元数据，包名 `com.qwelll.atriazoomguard` |
| `AtriaZoomGuard.plist` | Filter：只注入 `com.apple.springboard` |
| `README.md` | 本文 |

---

## 3. 编译

前置：Theos + iPhoneOS SDK（16.5 或更高）+ roothide 环境，`$THEOS` 已配置。

```bash
cd AtriaZoomGuard
make clean package FINALPACKAGE=1
# 产物：packages/com.qwelll.atriazoomguard_1.0.0_iphoneos-arm64e.deb
```

- SDK 版本不同 → 改 `Makefile` 的 `TARGET`（例如 `iphone:clang:16.5:15.0`）。
- rootless 而非 roothide → 把 `THEOS_PACKAGE_SCHEME` 改成 `rootless`。
- 装 deb（Filza / Sileo 或 `make install THEOS_DEVICE_IP=...`）后 **Respring**。

> 若之前装过我发的 `AtriaIconScaleDiag`，先卸载再 Respring，避免安全模式残留。

---

## 4. 怎么确认它真的生效

1. **加载自检**：Filza 打开 `/var/mobile/Library/Caches/AtriaZoomGuard.loaded`（备用 `/var/tmp/AtriaZoomGuard.loaded`），看到 `SBIconView=YES` 才算注入成功。这个文件在插件加载时就写，不依赖任何复现操作。
2. **日志**：`/var/mobile/Library/Logs/AtriaZoomGuard.log`（备用 `/var/tmp/AtriaZoomGuard.log`）。正常上滑返回应出现
   `suppress identity: guard=0.8000` —— 看到就说明**确实拦到了归位写入**。
3. **实测**：Icon Scale 设 0.8 → 打开 App → 上滑返回，重复 10 次；顺手看 Dock、文件夹、小组件、编辑器滑块、横竖屏。
4. **反向验证**：把 Icon Scale 设回 1.0，图标应在约 0.5s 内恢复原始尺寸（不会一直保持 0.8）。

---

## 5. 核心逻辑（3 步）

```
① Atria 写 sublayerTransform = scale(s,s,1)，s ≠ 1.0
   → 用关联对象把 s 记为该 layer 的 guard，清除任何「关闭」待决，正常放行

② 有人把同一 layer 写回 1.0（转场归位 / Atria 归位分支）
   → 直接 return，不放行；layer 保持 guard，不出现 1.0 帧   ← 修复点

③ 区分「转场瞬时归位」与「用户真的把缩放设回 1.0」
   → 首次见到 1.0 时打时间戳；0.5s 内只要 Atria 再写过任何非 1.0
     （转场结束后必然发生），待决即取消；否则判定为真的关闭，
     用 CATransaction setDisableActions:YES 无动画补写一次 identity
```

辅助保险：`UIView -layoutSubviews` 里，若 guard 存在且当前值偏离超过 0.01，用**无动画**方式回写 guard，覆盖图标视图被重建等边界；同时兜住「只写了一次 1.0」时的关闭判定。

全部状态只存在运行内存（关联对象），**Respring 即清空**；不使用 block、不捕获 self、不调用私有类方法、不依赖 Atria 内部符号。

---

## 6. 可调参数（`Tweak.x` 顶部）

| 宏 | 默认 | 作用 |
|---|---|---|
| `AZG_CONFIRM_DELAY` | `0.5` | 「用户关闭缩放」判定延迟（秒）。调大更不易误判，但关闭后恢复更慢 |
| `AZG_LAYOUT_RESTORE` | `1` | `layoutSubviews` 二次回写。若觉得改设置时跳变不自然，可设 `0`，只靠 ② |
| `AZG_DEBUG_LOG` | `1` | 写日志。确认生效后可设 `0` |
| `AZG_EPS` | `0.002` | 浮点比较容差 |
| `AZG_LOG_MAX` | `400` | 日志行数上限 |

---

## 7. 取舍与已知边界

- 把 Icon Scale 设回 1.0 时，图标最多延迟 0.5s 恢复；这是刻意代价，换来「不改设置时零闪回」。
- 若 Atria 对某些位置（App Library、未开启缩放的文件夹内图标）主动写 1.0，本 tweak 会在判定窗口内保持其最后的目标缩放，之后放行。这是为避免误伤转场做的取舍。
- 只处理 `SBIconView`（含子类）的 backing layer，不碰其他 layer。
- `AZG_LAYOUT_RESTORE=1` 时，Atria 修改缩放的隐式渐变动画可能被无动画回写打断，表现为「瞬间到位」而非渐变——这反而消除了可见的过渡帧。

---

## 8. 排错

**编译报错**
- `SBIconView` 未声明 → 确认 `Tweak.x` 里的 `@interface SBIconView : UIView` 在。
- `CATransform3D` / `CACurrentMediaTime` 找不到 → 确认 `#import <QuartzCore/QuartzCore.h>`。
- SDK / arch 相关 → 改 `Makefile` 的 `TARGET` 与 `ARCHS`，把完整报错发我。

**装了没反应**
- 先查第 4 节的两个自检文件。**没有文件 = 没注入**：检查 Filter plist 是否被打进 deb（`dpkg-deb -c xxx.deb`）、是否 Respring、是否被其他 tweak 注入管理器禁用。
- 有 marker 但日志里没有 `suppress identity` → 说明归位不是经 `setSublayerTransform:` 写的。保持 `AZG_LAYOUT_RESTORE=1`，并在 `Tweak.x` 里补一个 `-[CALayer setTransform:]` / `-[UIView setTransform:]` 的等价 hook（把 `AZGIsIdentity` 判断套用到 `t.m11` / `CGAffineTransform.a`）。

**有 `suppress identity` 但仍闪**
→ 说明是**视图替换 / 快照**（系统用另一个 layer 显示图标，Atria 的缩放只在原 layer 上），此时按 layer 记 guard 不够，需要改成按 icon 标识记忆。把日志发我，我按实际路径改。

---

## 9. 若需进一步定位

有电脑 USB 时可用 Frida（roothide 源 `re.frida.server` 16.1.4）直接抓 `-[CALayer setSublayerTransform:]` 写 identity 时的调用堆栈，一次确定写入方。这条路径完全不依赖编译产物。

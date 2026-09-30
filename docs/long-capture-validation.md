# 连续滚动拼接修复（2026-09-30）

## 参考范围

检查本机 `/Applications/ScreenSnap.app`（0.0.1）的设置界面与程序类型／诊断字符串：包含 `ScrollCaptureStream`、`ScrollStitcher`、`LongCanvas`、`FrameSig`、`nccAccept`、`nccRecover`、`stillFrameMAD`、`onPaused`、`onResumed`，以及位移、NCC、margin 日志。这些证据支持连续采集、视觉匹配、歧义判断、暂停恢复的设计方向；不证明其完整实现或具体阈值。自动化快捷键未能进入其长截图浮层，尚未完成两款软件真实滚动过程的对照测试。本次是独立实现，未复制其二进制代码。

## 修复

- 删除滚轮累计值作为文档坐标的逻辑。惯性、网页平滑动画、鼠标加速均可能使滚轮距离与真实页面位移不同。
- 使用逐源像素行的双向 NCC 搜索，独立梯度验证，以及第二候选差值判断；无可靠重叠时保留旧锚点，提示回滚接续。
- 静止帧不再永久锁死为页面底部。反向滚动只更新跟踪位置；只有超过已有画布尾端的内容才追加。
- 不再按相同滚轮值合并帧，也不再从积压队列截取末尾 18 帧。按接收顺序处理；队列超过 192 MiB 时明确报错，不丢中间帧后假装成功。完成前排空已接收帧。
- 允许 1 像素以上的新增内容，修复旧版 72 像素门槛遗漏尾段的问题。
- 已确认位移的画布只保存新增条带，避免每次小位移保留整张 Retina 图像。此路径不再用启发式弹性去重误删真实的小幅滚动。
- 未恢复的拼接缺口不导出为成功长图。

## 自动验证

命令：`swift test -c release --scratch-path /tmp/longshot-visual-build`

22 项 XCTest 在 Debug 和 Release 均全部通过。新增 5 项覆盖：

1. 75% 视口快速跳动、多帧停顿、回滚、再次前进、7 像素尾段；使用生产画布逐段合成，与原始图比较，尺寸一致且灰度差小于 0.01。
2. 无重叠时拒绝推进锚点，回到重叠区域后恢复。
3. 重复文本行存在多个同样合理的匹配时拒绝猜测。
4. 3440 像素宽视口的 455 像素位移保持逐行精度。
5. 按实际日志的 1948×1458 选区回放 120 帧：启动不匹配、静止、连续滚动，测量图像复制、签名、跟踪、画布和预览处理；按 60fps 到达率估算积压，验证不触发 192 MiB 限制。

## 启动积压回归修复

用户日志显示 60fps 采集约 20 帧后即停止；1948×1458 BGRA 帧约 10.83 MiB，原 192 MiB 队列仅能暂存约 17 帧。上一版 Swift 标量 NCC 在 Debug（-Onone）下太慢，且灰度签名反复通过 CGContext 处理原始大图。只跑 Release 的旧测试遗漏了这一问题。

修正保留 60fps 和原队列上限，未通过扩大队列或丢帧绕过问题：

- 缓存锚点的横向采样数据与逐行前缀统计；NCC 点积改为 Accelerate `vDSP_dotpr`。使用 Float 样本执行向量点积，Double 前缀统计计算归一化，保留逐源像素位移搜索、候选差值和独立梯度校验。
- 图像签名改为 vImage 单次灰度转换，再用向量缩放生成两种签名。
- 增加 `visual.process` 每帧耗时／队列长度／MiB 诊断，以及 `visual.ingress.overloaded` 入队失败诊断。

本机本次回放：Debug 平均 **12.60 ms/帧**，Release 平均 **5.65 ms/帧**；两次估算峰值积压均为 0。该数据是本机合成帧流水线回放，不是真实 ScreenCaptureKit + 窗口交互的端到端帧率保证。

命令：

```sh
swift test --scratch-path /tmp/longshot-perf-debug
swift test -c release --scratch-path /tmp/longshot-visual-build
xcodebuild -project LongScreenShot.xcodeproj -scheme LongScreenShot -configuration Debug -derivedDataPath /tmp/longshot-xcode-perf-debug CODE_SIGNING_ALLOWED=NO build
```

测试日志：`long-capture-debug-tests.log`、`long-capture-tests.log`。

原有匹配器返回的粗缩略图 NCC 曾与最终精确位移不一致，相关接口也接入了视觉校验，原有测试一并通过。

## 实机验收与边界

尚需在用户常用页面上验证：快速滚轮、触控板惯性、长时间滚动、到底回弹、网页图片懒加载、浮动页眉／页脚。合成图自动测试不能代替这些实机情形。

建议选取纯滚动内容区域，避免固定工具栏。新定位器会排除顶部／底部各约 1/12 区域参与匹配，但不会从最终导出图中自动移除任意大小的浮层。

若相邻实际采集帧已完全没有共同内容，或整屏完全重复／无纹理，单凭截图无法唯一恢复遗漏位置。此时提示回滚接续，不推测缺失内容。本实现单次搜索范围为视口高度的 ±82%，并要求有效重叠与可靠纹理。

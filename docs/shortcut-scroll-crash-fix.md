# 快捷键设置页滚动崩溃

用户报告 macOS 26.2 下，设置 → 快捷键向下滚动发生 NSInvalidArgumentException。附件堆栈定位到 ToolShortcutRecorderView.draw → NSString.size(withAttributes:) → CoreText TAttributes.ApplyFont → NSDictionary 插入 nil。仅凭堆栈不能确定系统内部哪项字体属性为空。

两个快捷键录入框原先在 draw 中创建等宽字体、属性字典并测量绘制字符串。现改为共享 ShortcutRecorderDisplayView，使用 NSTextField 和系统字体负责文字布局与字体回退；draw 仅绘制背景和边框。状态变化即时更新标签，保留录入、冲突、重置及 Esc 取消逻辑。标签命中测试转交录入框，避免文字子控件截住点击。

验证：37 项 SwiftPM Debug 测试通过。新增测试覆盖全部工具快捷键行在深浅色外观和多个滚动位置下的位图渲染、录入/冲突/Esc 状态更新、全局快捷键标签更新及点击命中。没有修改持久化快捷键配置。已在用户的 Xcode Debug 新版设置窗口完成实机检查：打开快捷键页，滚到底部，再两次上下往返，应用保持运行；底部文字正常显示。点击“撤销”的快捷键文字进入录入状态，按 Esc 恢复原 ⌘Z，未改变用户快捷键配置。应用签名和 DMG 完整性校验通过。

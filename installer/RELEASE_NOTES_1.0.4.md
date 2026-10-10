# Installer 1.0.4 · public release · 2026-10-10

Bundled plugin: **1.1.9RC9**. Published through the independent installer-v1.0.4 self-update channel; plugin Latest is v1.1.9RC9.

## 中文

- 顶部「安装器更新」卡片合并更新入口。发现新版本时红色闪烁，显示「安装器有新版本，点击此处更新安装器」；点击卡片或聚焦后按 Enter / Space 进入原有更新确认流程。无更新、检查中及操作期间不可点击。
- 安装方式选择：保留配置为绿色边框，纯净重装为橙色边框，取消为红色边框。
- 文件确认页把确认安装放在首位，使用绿色渐变脉冲边框；取消为红色边框。卸载确认继续使用红色，保留手动确认要求。
- 文件清单默认优先展示替换、删除、新增、重置等变更。点击任一列标题可切换升降序；大小按字节数排序。
- 保留的飞行记录默认折叠，可展开查看。涉及删除等变更的记录直接展示；复制清单仍包含折叠文件及各文件状态、校验信息。
- 用户提供的机场照片压缩为约 168 KB 的内嵌 JPEG，无需额外图片文件。开场以完整照片展示 `starlux slm` 淡入淡出动画，动画时长设为 1.5 秒；随后照片常驻主界面底层，以毛玻璃效果和深色遮罩保证可读性。
- 毛玻璃图像预处理一次，并缓存当前窗口尺寸的背景；按钮脉冲只重绘按钮区域，关闭窗口时释放动画计时器和图像。

## English

- The installer update card is now the update action. A newer version flashes red and can be clicked or activated with Enter / Space. Current versions, active checks and busy operations cannot activate it.
- Keep settings, clean reinstall and cancel have green, orange and red borders respectively.
- Install confirmation appears first with a pulsing green gradient border. Cancel and uninstall confirmation remain red; actions still require manual confirmation.
- File review prioritizes replacements, removals, additions and resets. Column headers toggle sorting; file sizes sort numerically.
- Preserved flight records start collapsed. Changed records remain visible, and copying the inventory includes collapsed records and per-file findings.
- The supplied airport photo is embedded as a compressed JPEG. A 1.5-second opening animation presents the full photo and `starlux slm`; afterwards a cached frosted background remains behind the main interface.

## Validation

- .NET build: zero errors or warnings.
- 71 existing installer checks passed, including backup/recovery, inventory, clean reinstall and diagnostics.
- Six offline UI checks passed: inactive/clickable card states, child-label and keyboard activation, busy gating, Chinese/English sorting and folding, full copied inventories, visible destructive record changes, confirmation order, and startup completion within two seconds with the background retained.
- Chinese and English off-screen previews inspected. Fixtures perform no actual simulator installation or network update.
- Source photo: user-supplied `f36c7c5d0bf39a63c7ac7e10457839d7.png`; compressed asset: `assets/startup.jpg` (1600 × 669, 172416 bytes).

# StarLux LMM 1.1.9rc4

2026-09-30，公开维护版。插件 **1.1.9rc4** / 安装器 **1.0.3**。

## 插件与分析器

- 继承 RC3 的邻近直升机场干扰跑道识别修复，包括三亚凤凰机场场景。
- 图表纵轴随可见时间区间自适应，悬停不改变范围。
- 可选油门/N1 合并覆盖层；YAW 与操纵十字线居中对齐。
- 保留基于跑道可用长度的长平飘、拉飘黄色降级测试规则；原有红色不降低。这些仍为插件测试阈值，并非机型或航空公司认可的 QAR 标准。
- 主脚本、报告、网页分析器和版本检查统一标识 1.1.9rc4；既有 UI 模块目录 LMM_UI_119 不变。

## 安装器

安装器正式编号为 1.0.3，继承此前 1.0.2rc4 的修复；旧 1.0.2 仅识别纯数字版本，故采用此编号以保证自更新可达。先更新安装器，再更新插件。

- 分类展示相关文件、具体修复原因、缺失与哈希差异；安装/卸载前确认具体范围。
- 完全卸载可清除程序、设置与缓存；飞行记录需单独勾选删除，共享 FlyWithLua 和未知内容保留。
- 默认只显示状态与必要信息，开启“输出详细”后查看逐文件过程；诊断文件保留完整记录。
- 识别移动后的备份，恢复前核对事务身份；拒绝用另一笔备份覆盖当前未完成事务。
- 原备份遗失时，可在备份当前现状后保留设置/记录重新安装；失败恢复现状与旧标记。
- 安装已完成但事务标记未清理时，核验预期文件后仅完成收尾。

## 使用

完整解压 CN 或 EN 离线包，退出 X-Plane，运行包内安装器，选择本地 1.1.9rc4。标准版面向 XP 12.4.4+，兼容版沿用传统界面与数字覆盖层；具体兼容性仍需实机验证。不要只替换 Lua，也不要把手动删除安装标记作为通用修复方式。

手动删除程序文件不会自动清理 `Resources/plugins/StarLux_LMM.install.json` 与 `StarLux_LMM.install.pending.json`。遇到残留事务，使用安装器的恢复或保留数据重装流程。

## English

Public maintenance release **1.1.9rc4**, bundled with installer **1.0.3**. Published to GitHub. Installer 1.0.3 carries the tested 1.0.2rc4 fixes under a numeric version recognized by existing installers.

Includes RC3 airport matching, visible-window chart scaling, combined throttle/N1 overlay, centered YAW display and experimental long-float/balloon grading. Plugin reports, analyzer and update metadata consistently identify RC4.

The installer adds file-level findings, reviewed install/removal plans, full uninstall with separate flight-record consent, compact/detailed output, relocated-backup recovery and an explicitly confirmed keep-data reinstall when the old backup is unavailable. Completed installations are verified before clearing stale transaction markers.

Extract the full bundle and choose local 1.1.9rc4. The EN bundle uses ASCII-only paths. Standard targets XP 12.4.4+; Compatibility retains legacy UI and numeric overlays. In-simulator validation remains necessary.

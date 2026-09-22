# StarLux LMM 安装器 v1.0 使用说明

安装器版本从 v1.0 开始独立维护，与插件版本分别更新。支持 Windows 10/11 x64 和 X-Plane 12，程序自带 .NET 运行库。

## 开始使用

1. 将离线包完整解压到 X-Plane 目录之外的可写文件夹。根目录包含 `StarLux_LMM_installer_安装器.exe` 和 `version/`；也可只使用 EXE 联网获取插件包。
2. 启动安装器，顶部按钮可在中文与英文之间切换，选择会保存。安装器语言与插件默认语言分别设置。
3. 检查识别出的 X-Plane 根目录；多份模拟器可在列表选择，或点击“浏览目录”。目录应包含 `X-Plane.exe`。
4. 选择插件版本，点击“安装 / 更新插件”。操作前完全退出 X-Plane。缺少 FlyWithLua 时，可选择下载固定官方 XP12 NG+ 运行库或导入自己的 NG+ ZIP。

## 三个状态区

- **插件更新**：有更高版本时持续红色闪烁；确认当前版本与在线最高版本一致时为静态绿色。
- **插件状态**：检查文件是否缺失、内容是否匹配安装记录、有无多个主脚本或旧 UI 残留，以及已知 XP 版本与 UI 的兼容性。通过文件及兼容检查后显示绿色。
- **安装器更新**：独立检查安装器版本。有更新时红色闪烁，并启用“更新安装器”；已确认最新时静态绿色。

联网失败、尚无正式更新包或 XP 版本未知时显示待确认状态，不会显示为已验证或最新。文件检查不能代替实际启动模拟器验证。

## 修复与纯净重装

点击“修复插件”后，安装器优先选用当前已安装版本的兼容包；如果该版本不可用，会在确认窗口显示可用替代版本。较旧 XP 的标准版问题会优先匹配兼容版。确认前核对版本、语言与目标目录。

| 方式 | 插件设置 | 随插件分析器偏好 | 飞行记录与机场缓存 |
| --- | --- | --- | --- |
| 保留配置 | 保留 | 保留 | 保留 |
| 纯净重装 | 备份后重置 | 下次打开该分析器时重置已知 LMM 偏好 | 保留 |

两种方式都重新部署所选包并清理已识别的旧 LMM 程序文件。其他插件、用户脚本和既有 FlyWithLua 不会被卸载。纯净重装后，已生成的临时查看页面会移除，重新从插件打开报告即可。

分析器偏好存储在浏览器中，安装器不会扫描或改写浏览器用户目录。一次纯净重装只触发一次页面内重置；此后普通修复保留新的偏好。不同浏览器对本地文件的存储隔离方式可能不同，重置只作用于打开页面所能访问的已知 LMM 设置键。独立分析器 HTML 文件不会被修改。

## 卸载与恢复

“卸载插件”会移除已识别的 LMM 主脚本、UI 模块、随插件分析器和临时查看代码，保留设置、飞行 TXT、机场缓存、其他脚本及 FlyWithLua。共用的顶层 README/LICENSE 文件保留。

安装、修复、纯净重装和卸载均在 EXE 旁的 `backup/日期-编号/` 保存受影响的原文件及 `transaction.json`。写入失败时自动回滚；断电或强制结束后，按未完成事务提示使用“恢复备份”。优先选择最近一次备份，并核对其对应的 XP 目录。

恢复会覆盖该事务涉及的文件。纯净重装备份可以恢复插件配置，但不能恢复已在浏览器中执行重置前的偏好。

## 安装器自更新

点击“更新安装器”后，程序下载并校验新版本，关闭当前窗口，由更新助手替换 EXE 并重新启动。插件、`version/` 和 `backup/` 保持原位。新程序未能正常启动时尝试恢复原安装器；旧 EXE 和更新结果记录会保留，便于排查。

自更新从安装器 v1.0 的独立发布通道开始。尚未支持此协议的旧预览安装器需要先手动替换为 v1.0。联网更新需要发布方将对应版本的正式更新资产上传至官方 GitHub/Gitee；本地构建完成不等于已上线。

## English guide

Extract the portable bundle to a writable folder outside X-Plane and run the EXE. Use the top-right button for a fully English installer interface. Select the simulator root, package and installation mode. Installer language and plugin default language are independent.

**Repair plugin** checks file integrity and selects a compatible package, preferring the installed version. **Keep settings** preserves plugin and analyzer preferences. **Clean reinstall** backs up/resets plugin configuration and resets known analyzer preferences when the bundled page is next opened. Flight reports, airport caches, other plugins and FlyWithLua remain. Browser profiles are never scanned; local-file storage isolation depends on the browser.

**Uninstall** removes identified LMM code while retaining settings and reports. **Restore backup** restores files recorded in a transaction; prefer the latest matching backup. Browser preferences already reset in the browser are not recoverable through a file backup.

Plugin and installer updates have separate status cards: available updates flash red; confirmed current versions are static green. Unknown/offline status is never reported as current. **Update installer** verifies the download, replaces the executable, restarts and attempts rollback if the new process fails its readiness check. Installer updates require published assets in the independent installer release channel.

Close X-Plane before any plugin file operation. The installer checks files and known compatibility, not successful live simulator loading. Windows system file dialogs follow the operating system's language.

## 1.0.1 maintenance / 文件清理修订

升级、修复和卸载会备份并移除可确认属于 StarLux 的旧版本 README 和旧 UI 文件，随后移除空的版本目录及 fonts 子目录。目录中未知的用户文件不会删除；设置、落地记录和机场缓存继续保留。历史备份可从安装器恢复。

Upgrade, repair and uninstall now back up and remove obsolete StarLux version guides and UI files, then prune empty version folders and their empty fonts folders. Unknown user files, settings, flight records and airport caches are preserved. Transaction backups remain restorable.

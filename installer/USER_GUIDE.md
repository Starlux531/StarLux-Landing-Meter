# StarLux LMM 安装器 v1.0.3 使用说明

安装器版本从 v1.0 开始独立维护，与插件版本分别更新。支持 Windows 10/11 x64 和 X-Plane 12，程序自带 .NET 运行库。

## 1.0.3：未完成事务恢复

- 检测到未完成操作后，点击“安装 / 更新插件”或“修复插件”，先进入恢复选择窗口，不再只弹错误后退出。
- 优先查找标记中的原备份，以及当前安装器 `backup/` 中的对应备份。RC4 事务带唯一编号和原始状态校验值，移动或重命名备份仍可匹配；旧事务移动后需保留原日期-编号目录名，并校验模拟器目标和全部备份文件。
- **恢复对应备份 / 定位原备份**：恢复旧文件后再继续安装。当前有未完成事务时，不能用另一笔历史备份覆盖它。
- **保留数据重新安装**：旧备份遗失或不可用时，从完整安装包重新部署。先备份当前受影响文件，归档原标记，再建立新事务；保留现有设置和飞行记录。此操作无法找回已经删除的旧文件。取消、下载失败或载荷校验失败时不改旧标记；部署失败则恢复本次操作前的文件和旧标记。
- 安装已完成、仅清除标记失败时，不再回退整个安装。下一次操作会核对事务预期文件状态，只有逐项一致才清除遗留标记。
- 模拟器目录本身被移动时，旧备份不会自动写回旧目录或被当作其他模拟器的备份；可选择保留当前数据重新安装。

## 维护清单与简洁输出（沿用 RC3）

安装器 1.0.3 为公开维护版，继承 1.0.2rc4 的恢复修复；采用纯数字版本号以兼容旧安装器的自更新识别。本次离线包内置 **插件 1.1.9rc4** 的标准版/兼容版、中英文四种安装包；安装器自身版本为 **1.0.3**，两者独立维护。

- **输出详细**默认关闭并记住选择。关闭时只显示状态、完成结果、关键提醒与错误；开启后显示逐文件检查、暂存、备份、写入和内部诊断。切换时重新显示近期记录，磁盘诊断日志始终保留完整过程。
- **文件清单 / 原因**列出相关程序、设置、缓存、飞行记录、缺失文件和受保护的未知文件。选中一行可以查看完整路径、校验状态及清单/实际 SHA-256。可以复制清单和原因。
- 修复优先使用已安装版本，确认窗口明确显示“当前版本 → 修复目标”。需要升级时使用“安装 / 更新插件”。缺少安装清单表示无法验证，文件校验不同也可能来自手工替换，并不直接证明文件损坏。
- 下载/暂存完成后，展示最终新增、替换、清理及保留清单；确认后先检查现有目标是否只读或被占用，再备份与写入。确认后若安装范围变化，停止并要求重新检查。
- **卸载**保留个人设置、缓存与飞行记录。**完全卸载**同时清除已识别的插件设置和缓存；飞行记录、未完成录制及其备份仅在勾选“同时删除飞行记录”后移除。具体范围以确认表中的“删除”行为准。
- 未知文件、共用 README/LICENSE、其他插件、FlyWithLua、浏览器中的偏好及安装器自身均不删除。安装器旁的 `backup/` 保留恢复副本，因此完全卸载不是数据不可恢复擦除。LMM 空目录会清理，含受保护文件的目录保留。
- 存在未完成事务时先选择对应备份恢复或保留数据重新安装；卸载不会绕过它。恢复窗口优先定位对应备份目录。

## 操作记录与故障诊断（沿用 RC2）

沿用安装器 RC2 的诊断功能；本次离线载荷已更新为插件 **1.1.9rc4**。

- 开启“输出详细”后，窗口显示目录检查、安装选择、下载与切换源、校验、暂存、逐文件备份/复制/删除及回滚过程。确认窗口中的选择、语言与下载源选择也会记录。
- 每次启动新建独立日志，带时间、操作编号、进程/线程编号和步骤耗时。切换语言、关闭后重新启动不会清除之前的日志。界面只保留近期文本，磁盘日志保留本次完整过程。
- 错误提示尽可能列出错误类别、失败步骤、具体路径、系统错误码和处理建议；完整异常与内部错误堆栈写入日志。原因无法确认时明确说明，不把未知错误一概归因于网络或杀毒软件。
- 安装失败时先记录首次错误，再尝试回滚；回滚失败单独记录，保留原始错误、事务清单和未完成标记。原备份被移动或删除时，明确指出所需位置，不自动删除标记或绕过恢复。
- 点击底部 **打开日志** 查看本次会话目录；点击 **导出诊断包** 保存 ZIP，交给开发者。包含当前及同一日志根目录最近四次会话和相关安装清单，不包含配置文件内容、飞行 TXT 或备份中的程序文件。包中有本机路径与用户名，发送前可检查。

默认日志位于安装器旁 `logs/会话编号/installer.log`。无法写入时依次尝试 `%LOCALAPPDATA%/StarLux_LMM_Installer/logs`、`%TEMP%/StarLux_LMM_Installer/logs`。若这些位置均不可写，只能保留内存中的近期记录；请在关闭前导出诊断包。

**给反馈问题用户的操作：** 退出 X-Plane 和旧安装器，将新版 EXE 放回原安装器文件夹替换旧 EXE，保留原有 `version/`、`backup/`；运行后重现一次问题，点击“导出诊断包”发送 ZIP。原安装器 1.0.2 没有持久日志，新版不能补回此前已经丢失的首次错误。若提示原备份缺失，请同时说明是否移动、重新解压或删除过安装器文件夹。

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

**1.0.2rc2 diagnostic build:** persistent per-session logs record user choices, download attempts, validation, per-file backup/deployment, recovery and full exception stacks. Use **Open logs** or **Export diagnostics** at the bottom. Export includes the current and four recent sessions from the same log root, plus installation metadata; it excludes flight reports and configuration contents, but contains local paths/usernames. If all log locations are unwritable, export the recent in-memory log before closing. To test, close X-Plane and the old installer, replace only the EXE in its original folder, keep `version/` and `backup/`, reproduce the issue and send the diagnostic ZIP. Missing errors from the old 1.0.2 session cannot be reconstructed. This local build embeds the unchanged published plugin **1.1.9rc2** and has not been published to the update channel.

Extract the portable bundle to a writable folder outside X-Plane and run the EXE. Use the top-right button for a fully English installer interface. Select the simulator root, package and installation mode. Installer language and plugin default language are independent.

**Repair plugin** checks file integrity and selects a compatible package, preferring the installed version. **Keep settings** preserves plugin and analyzer preferences. **Clean reinstall** backs up/resets plugin configuration and resets known analyzer preferences when the bundled page is next opened. Flight reports, airport caches, other plugins and FlyWithLua remain. Browser profiles are never scanned; local-file storage isolation depends on the browser.

**Uninstall** removes identified LMM code while retaining settings and reports. **Restore backup** restores files recorded in a transaction; prefer the latest matching backup. Browser preferences already reset in the browser are not recoverable through a file backup.

Plugin and installer updates have separate status cards: available updates flash red; confirmed current versions are static green. Unknown/offline status is never reported as current. **Update installer** verifies the download, replaces the executable, restarts and attempts rollback if the new process fails its readiness check. Installer updates require published assets in the independent installer release channel.

Close X-Plane before any plugin file operation. The installer checks files and known compatibility, not successful live simulator loading. Windows system file dialogs follow the operating system's language.

## 1.0.1 maintenance / 文件清理修订

升级、修复和卸载会备份并移除可确认属于 StarLux 的旧版本 README 和旧 UI 文件，随后移除空的版本目录及 fonts 子目录。目录中未知的用户文件不会删除；设置、落地记录和机场缓存继续保留。历史备份可从安装器恢复。

Upgrade, repair and uninstall now back up and remove obsolete StarLux version guides and UI files, then prune empty version folders and their empty fonts folders. Unknown user files, settings, flight records and airport caches are preserved. Transaction backups remain restorable.

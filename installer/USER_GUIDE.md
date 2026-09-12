# StarLux LMM 安装器 / Installer

适用于 Windows 10/11 x64 与 X-Plane 12。安装器自带 .NET 运行库，无需另外安装 Python、.NET SDK 或 FlyWithLua 才能启动。

## 使用

1. 完整解压收到的 ZIP 到一个可写文件夹，里面只有 `StarLux_LMM_installer_安装器.exe` 和 `version`。不要在压缩包预览里直接运行 EXE，也不要放入 X-Plane 目录内部。
2. 退出 X-Plane，运行安装器。自动识别 Steam 库、X-Plane 安装记录和常见路径；多份模拟器需要自己选择，也可手动浏览到包含 `X-Plane.exe` 的根目录。
3. 查看安装状态，选择版本。离线包会标注“本地”；线上会显示 GitHub / Gitee。检查失败意味着“在线状态未知”，不是“没有更新”。
4. 点击安装并核对版本与目标。已有 FlyWithLua 不会自动升级；未找到时，可同意下载官方 XP12 NG+ 2.8.14，或导入自己已下载的 XP12 NG+ ZIP。
5. 安装完成后启动模拟器验证。安装器只检查文件是否存在/匹配，不声称验证了插件实机成功加载。

安装器可单独复制运行，不带 `version` 时会通过 GitHub/Gitee Releases 选择并下载发布包。本地包不需要联网，更新检查不阻塞本地安装。GitHub 与 Gitee 只有发布了同名同版本安装 ZIP 才能相互接替；缺失的版本不会被旧版本替代。

## 备份与恢复

安装时在 EXE 旁新增 `backup/日期-唯一编号/`，包含被覆盖/移出的文件、安装事务清单与日志。首次安装也会记录新增文件列表，以便恢复到未安装状态。

安装器保留已有 `LMM_Settings.cfg`、`LMM_Log`、机场索引和其他用户脚本；升级前把旧的 LMM 主 Lua 脚本备份后移出 Scripts，避免重复运行。FlyWithLua 的示例脚本不会被自动启用。

发生可捕获的写入错误会自动回滚。断电或强制终止后重新运行，若检测到未完成事务，先点“恢复备份”，选择对应 `transaction.json`。恢复应从最近一次备份开始；安装后手工修改过的插件程序文件会被所选备份覆盖，用户设置和飞行记录不受影响。不要手动编辑或删除备份内容。

## 下载与安全

- LMM 来源为官方 GitHub `Starlux531/StarLux-Landing-Meter` 与 Gitee `starlux531/starluxlmm`，无需账号或 token。
- 使用 HTTPS、超时切源、ZIP 路径检查和大小上限；本地清单及可用的发布方 SHA256 会进行校验。旧版资产没有发布方摘要时会明确提示，不能把自行计算的散列视为发行方身份认证。
- 本地 `version/版本/manifest.json` 必须配套 `payload`，不是任意 Lua/ZIP 都会自动执行。具体版本及构建标记以清单与安装界面为准。
- FlyWithLua 自动下载固定官方源码归档中的 2.8.14 Windows 二进制、支持模块、依赖 DLL 和许可证；不会下载 GitHub Releases 上的 XP11 2.7.32，也不跟随 master 的不稳定更新。下载完不执行安装脚本，仅安装运行文件。
- FlyWithLua 国内镜像尚未发布时依赖下载仍需要连通 GitHub；可在官方 NG+ 页面登录下载后导入 ZIP。安装器不绕过登录。
- 若已有 FlyWithLua 文件检测通过但模拟器不能加载，请检查 X-Plane `Log.txt`；文件存在不代表依赖、版本或配置一定正常。
- 安装器目前没有代码签名。Windows 可能显示未知发布者，请核对来源；不要关闭防病毒软件。受保护的目录、目录联接/符号链接不支持自动写入，改用普通可写目录或手动安装。
- 关闭安装器不会保留后台更新任务，不上传用户飞行数据。

## English quick start

Extract the whole bundle into a writable folder outside X-Plane. Run the EXE, select your X-Plane 12 root and package, then confirm installation. Local packages work offline; standalone EXE users can fetch official releases online. Exit X-Plane first. Existing settings, logs, airport caches and unrelated scripts are preserved. Missing FlyWithLua can be downloaded with consent or imported from an XP12 NG+ ZIP. Use **Restore** with the latest backup's `transaction.json` if necessary. The installer checks files, not live simulator loading. This preview installer is unsigned.

Official sources: [GitHub](https://github.com/Starlux531/StarLux-Landing-Meter/releases), [Gitee](https://gitee.com/starlux531/starluxlmm/releases), [FlyWithLua NG+](https://forums.x-plane.org/files/file/82888-flywithlua-ng-next-generation-plus-edition-for-x-plane-12-win-lin-mac/), [fixed FlyWithLua commit](https://github.com/X-Friese/FlyWithLua/tree/453f6a22de4fde15a9c960588690f4780d7d7bf0).

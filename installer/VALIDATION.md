# Installer 0.1.0 preview — validation record

Date: 2026-09-12. Environment: Windows 10 build 19045 x64, .NET SDK 10.0.103; final EXE is self-contained.

## Final artifacts

| Artifact | Bytes | SHA256 |
| --- | ---: | --- |
| `dist/StarLux_LMM_Installer/StarLux_LMM_installer_安装器.exe` | 51,707,304 | `8a9f648440e92d0ae8ee7f1839c301d86d988326ad2ac2b10913fae124b6d189` |
| `dist/StarLux_LMM_Installer.zip` | 47,323,050 | `9a036b825a7467d010bb1fd69fa375f50252fc358bf0678e40346f6c9a0dec4e` |

ZIP inspected: exactly two root entries, the requested EXE and `version`. Bundled manifest: `1.1.8beta`, build `20260912-language-fix`, 12 payload files. Main Lua matches the current source SHA256; fonts/modules and their license are included. No plugin source or algorithm was changed by the installer work.

## Results

- Final published EXE, not just a DLL build, completed **27/27 tests** with exit code 0, including actual GitHub/Gitee downloads and the fixed official FlyWithLua archive.
- Build: zero warnings / zero errors.
- Real-machine read-only discovery returns one canonical simulator path: `D:\STEAM\steamapps\common\X-Plane 12`. Read-only inspection detects existing `1.1.8beta` and FlyWithLua runtime files. No installation into this path was performed.
- Off-screen WinForms rendering checked for layout; native combo-box selected text is not reliably represented by `DrawToBitmap`. Real DPI scaling, dropdowns and end-to-end GUI interactions still require human acceptance testing.

Coverage: numeric and prerelease ordering; Windows path/ADS/device/traversal rejection; duplicate ZIP paths; directory normalization; local offline discovery; payload hashes and version consistency; allowlist and duplicate manifest checks; upgrade backup and old-main removal; settings/log/cache/other-script preservation; manual restore; injected write failure rollback; invalid target and backup-root safeguards; missing-FWL consent boundary; dependency runtime-only install; foreign-target backup rejection; pending transaction detection; corrupt backup rejection; future native-root plan/install/restore; legacy asset filtering; approved HTTPS origins; corrupted-mirror failover with shared digest; catalog mirror merge; redirect rejection; real bundled fonts/payload validation; real official FWL DLL/install/restore; live GitHub and Gitee 1.1.4 CN download/unpack validation.

The test runner writes its detailed machine-readable report to `.tools/installer-research/tests-release.json`; generated fixture directories remain in OS temp for inspection. These files are not distributed to users.

## Remaining acceptance checks

- Real X-Plane startup/loading after user-approved installation, especially custom FlyWithLua setups.
- Clean Windows 10/11 machines without development tools; 125–200% DPI, multiple monitors, multi-library Steam, protected folders and restricted networks.
- Forced-process termination/power-loss recovery in a disposable simulator fixture. Pending-marker and journal logic are tested, but real power-loss behavior was not simulated.
- Code signing before wider public distribution. Current EXE is unsigned.
- Publish/configure a domestic FlyWithLua mirror if desired. Current LMM dual-source assets were verified; no Gitee FWL mirror has been created or claimed available.

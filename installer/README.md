# StarLux LMM Installer v1.0

The installer has its own version line, starting at **1.0.0** (displayed as **v1.0**). Plugin versions remain independent: plugin **1.1.9** is stable as of 2026-09-23. Its offline bundles include installer **1.0.1** with obsolete LMM file cleanup. The existing standalone installer update release remains `installer-v1.0.0`; plugin release tags do not advance that channel.

## Implemented lifecycle

- Separate GitHub/Gitee catalogs for plugin updates and installer updates. Installer updates use `installer-vX.Y.Z` release tags; plugin tags cannot advance the installer version.
- Verified staging, executable replacement after the parent exits, restart acknowledgement, previous-EXE backup and rollback on restart failure. The portable `version` and `backup` directories stay in place.
- File diagnosis against installation receipts: missing/modified files, multiple main scripts, obsolete UI modules, interrupted transactions and known X-Plane/UI compatibility mismatches. Unknown simulator versions are not marked verified.
- Repair selects the installed version where available and a compatible UI variant. If that version is unavailable, the proposed alternative appears in the confirmation. Users can preserve settings or choose clean reinstall.
- Clean reinstall backs up/removes plugin configuration and inserts a one-time reset hook into the installed analyzer. It resets the analyzer's known storage keys when that page is next opened; the transformed HTML hash and reset token are recorded in the receipt. Normal repair carries the token forward to avoid repeated resets. Browser profiles are never scanned or edited directly.
- Uninstall removes identified LMM program files and generated viewer code, preserving settings, reports, caches, unrelated scripts and FlyWithLua. Shared top-level README/LICENSE files are retained. Uninstall uses the same backup, transaction and rollback machinery as installation.
- Persistent Chinese/English switch, localized controls/dialogs/diagnostics, blue gradient UI, independent health/update cards. Known updates pulse red; confirmed current versions remain green; offline/unknown states do not claim to be current.

## Build

Requires the .NET 10 SDK on Windows. The shipped executable is self-contained and needs no separately installed .NET runtime.

```powershell
dotnet restore installer/StarLux.Installer.csproj
./installer/build.ps1 -NoRestore
# Optionally include an existing, verified plugin version directory:
./installer/build.ps1 -NoRestore -PluginVersionDirectory 'D:/release/1.1.8/version'
```

Output: `dist/installer/1.0.0/`. The offline bundle has the EXE and `version/` at its root. No plugin development source is automatically promoted or packaged. `-SkipPublish` reuses `.tools/installer-v1/published/` after checking its product and version.

For future plugin 1.1.9 packaging, use `tools/prepare_release_119.ps1` separately.

## Self-update release contract

Publish the following files from the build output under **`installer-v1.0.0`** on the configured official repositories:

| Asset | Purpose |
| --- | --- |
| `StarLux_LMM_Installer_v1.0.0.zip` | User-facing portable/offline bundle |
| `StarLux_LMM_Installer_Update_v1.0.0.zip` | Self-update payload: exactly the EXE and `installer-update.json` |
| `installer-release.json` | Product/version/asset name and archive SHA256 for sources without an API digest |
| `SHA256SUMS.txt` | Checksums for the generated distribution files |

The internal update manifest identifies `StarLux_LMM_Installer`, the version, the fixed executable filename and its SHA256. The release metadata hashes the entire ZIP. Downloads must originate at the configured repositories over HTTPS; redirects, paths and sizes are checked. Product/version metadata in the PE must match the selected update. Conflicting mirror digests are excluded. These integrity checks do not replace publisher code signing.

Future versions increment the installer project's `<Version>` and publish the matching `installer-v...` tag and filenames. Both repositories should serve identical bytes. The current local work has not uploaded these assets; an unpublished channel displays “No installer release package published”, not “Up to date”.

Self-update keeps a previous executable beside the target and a staging `result.json` for recovery. Failure to restart returns to the original executable where filesystem permissions permit. Browser preferences cannot be restored from file backups after a clean reset has already run in the browser.

## Verification

```powershell
$exe = 'D:/Starlux_LMM/.tools/installer-v1/published/StarLux_LMM_installer_安装器.exe'
Start-Process -FilePath $exe -ArgumentList @('--self-test', 'D:/Starlux_LMM/.tools/installer-v1/tests.json') -WindowStyle Hidden -Wait
```

For an actual self-update replacement/restart test, build a self-contained higher-version executable into a separate fixture folder and append `--update-fixture PATH_TO_EXE` to the test arguments. Tests operate only on temporary fixtures. `--render OUTPUT.png --language en --preview-updates` and `--language zh --preview-current` render off-screen previews with explicitly simulated statuses; they make no network requests and do not inspect a real simulator.

The existing `--inspect XP_ROOT OUTPUT.json` and `--detect OUTPUT.json` diagnostics remain read-only. See [validation results](VALIDATION.md) and [user guide](USER_GUIDE.md).

# StarLux LMM portable installer — development and publishing

This is a Windows 10/11 x64, .NET 10 WinForms **self-contained, single-file** application. The distributed EXE needs no separately installed .NET/Python. Installer and plugin are now version `1.1.8`. Nothing is uploaded or published by the build.

The stable builder is `tools/prepare_release_118.ps1`, also called by `installer/build.ps1`. It generates `dist/1.1.8/StarLux_LMM_Installer_1.1.8` with exactly EXE + version at its root, four Standard/Compatibility × CN/International packages, the standalone analyzer and sanitized author presets. Manifests add `uiVariant` (`sdk440`/`legacy`) and `defaultLanguage` (`zh`/`en`). Existing settings take precedence over package defaults. See [the current bilingual release guide](../README_1.1.8.md). The beta tree below documents the preceding packaging format, not the current output filename.

Latest badges are computed across successfully loaded local and remote releases using numeric semantic versions (final > beta). Every variant of the highest version is labelled. The UI displays target compatibility separately; the badge does not mean that the package is suitable for the selected XP installation. Online variants are identified by `-Standard-` / `-Compatibility-` and `-CN` / `-International` asset names. GitHub and Gitee must receive identical attachment filenames and bytes for same-release fallback.

## Build the requested two-item distribution

From PowerShell with .NET 10 SDK:

```powershell
./installer/build.ps1
```

Output:

```text
dist/StarLux_LMM_Installer/
├── StarLux_LMM_installer_安装器.exe
└── version/
    ├── 安装说明.md
    └── 1.1.8beta-language-fix/
        ├── manifest.json
        └── payload/
            ├── StarLux_LMM_v1.1.8beta.lua
            ├── LMM_Report_Reader.html
            ├── README_1.1.8beta.md
            ├── LICENSE
            └── LMM_UI_118/...
```

`dist/StarLux_LMM_Installer.zip` contains exactly these two root entries. `backup` is created beside the EXE **at installation time**, not shipped empty. Preferences store only the chosen simulator path in `%LOCALAPPDATA%/StarLux_LMM_Installer/preferences.json`. Downloads use a unique OS temporary staging directory and do not pollute the portable release root.

The current package is generated from the working tree's language-fixed source, not the earlier `StarLux_LMM_v1.1.8beta.zip`. Build-generated manifests carry SHA256 for every installed file; the bundled fonts keep their OFL license. Existing config is deliberately not included/overwritten.

## Architecture and boundaries

- `Core.cs`: bounded discovery (Steam registry/libraryfolders/appmanifest, X-Plane install list, fixed common paths), package validation, install planning, backup, restore and installed-file receipts.
- `Network.cs`: bounded release pagination, GitHub/Gitee merge by version **and asset filename**, HTTPS host restrictions, timeout-based failover, download limits and checksum verification. Assets named `StarLux-Landing-Meter*.zip` or `StarLux_LMM_v*.zip` are supported; repository snapshots and installer ZIPs are excluded.
- `MainForm.cs`: bilingual UI, explicit version/target confirmation, downgrade warning, missing-FWL consent, download cancellation, backup restoration. Catalog checks do not disable local installation.
- `SelfTests.cs`: offline integration tests with isolated fake simulators; optional real download tests. These do not install into the user's real X-Plane.

Only active **LMM main scripts** matching the explicit filename family are removed from Scripts, after backup. Other scripts, all user configs, logs and airport caches remain untouched. Locally renamed LMM scripts outside the filename family must be removed manually; the installer does not guess ownership of arbitrary Lua files.

Every target is guarded by a per-target process mutex. Backups are checksum-verified before writing. The journal is persisted before writes, with a pending marker in the simulator plugins folder so an interrupted installation is discoverable even if the installer is later moved. Ordinary errors roll back immediately; interrupted transactions require restoration. This is not a guarantee against disk hardware failure or loss of the backup drive. Backups are not automatically pruned.

ZIP entries reject traversal, Windows device names/ADS, duplicate case-insensitive paths, links and over-large expansion. Reparse/junction simulator or backup paths are rejected rather than followed. Installer is as-invoker, does not disable antivirus, change OS settings, run downloaded scripts, kill X-Plane, self-update its EXE, or publish releases.

## Publishing future local / online versions

Prepare a single clean payload directory with only the files intended for installation, then:

```powershell
./installer/pack-version.ps1 -SourceDirectory 'D:/release-payload' -DestinationDirectory 'D:/release/version/1.1.8beta2' -Version '1.1.8beta2' -Build '20260920-preview'
```

For online installation, ZIP the generated `manifest.json` **and** `payload` together; upload it as a GitHub/Gitee **Release attachment**, e.g. `StarLux_LMM_v1.1.8beta2.zip`. Keep identical bytes and filenames on both sites. A normal repository commit is not a release and does not change the installer's version menu. Use a new version tag for updates; editing files under the same tag/build is supported as reinstall, not automatically reported as a higher version.

The installer already understands the historical public 1.1.4 CN/International assets. For these legacy ZIPs it extracts only its allowlist and ignores bundled settings/logs. GitHub's SHA256 asset digest is verified; if a matching Gitee mirror has no digest, GitHub's known digest is used. If neither source supplies a digest, the user must confirm the weaker HTTPS-only legacy provenance. SHA256 is integrity protection, not an offline cryptographic publisher signature.

Local manifest schema:

```json
{
  "schema": 1,
  "product": "StarLux_LMM",
  "version": "1.1.8beta2",
  "build": "20260920-preview",
  "kind": "flywithlua",
  "notes": "Release notes",
  "files": [{ "path": "StarLux_LMM_v1.1.8beta2.lua", "sha256": "64 hexadecimal characters" }]
}
```

Paths are relative to `payload`, not arbitrary destinations. Local discovery accepts `version/manifest.json` or one subdirectory per version. Unmanifested local ZIPs are not automatically trusted or executed. A future `kind: "native"` uses only `Resources/plugins/StarLux_LMM`, requires `win_x64/StarLux_LMM.xpl`, and does not require FlyWithLua. Lua→native disables the old Lua main; native→Lua is blocked until the native plugin has been manually moved out. Native installation plumbing is tested with fixtures; no native LMM binary is shipped or claimed ready.

## FlyWithLua NG+ provenance and domestic mirror

The [official NG+ page](https://forums.x-plane.org/files/file/82888-flywithlua-ng-next-generation-plus-edition-for-x-plane-12-win-lin-mac/) says 2.8.14 was restored while 2.8.16 issues were being investigated. The GitHub Releases `latest` endpoint is still XP11 2.7.32 and must **not** be used for XP12 auto-install.

Instead, consent-based download uses the [official fixed repository commit](https://github.com/X-Friese/FlyWithLua/tree/453f6a22de4fde15a9c960588690f4780d7d7bf0). Its included Windows binary identifies itself as **2.8.14 build Apr 15 2026 10:24:09**, with OpenAL32/glut DLLs. The installer extracts only Windows runtime/support folders, copies the repository MIT license, and never enables the repository's demo scripts. It does not overwrite an existing detected FWL installation. File detection is not a live plugin load/compatibility test.

Pinned archive:

```text
https://codeload.github.com/X-Friese/FlyWithLua/zip/453f6a22de4fde15a9c960588690f4780d7d7bf0
SHA256 c6e1a4517328c4df20887bba4b6bb40a375344ec5230a39cfd35a99c9708819f
```

For a domestic mirror, first review redistribution licenses and publish this **unchanged archive** as an attachment under the user's Gitee project. Then add `version/flywithlua-mirrors.json` (inside the second release-root entry):

```json
[
  {
    "name": "Gitee",
    "url": "https://gitee.com/starlux531/starluxlmm/releases/download/YOUR_RELEASE/FlyWithLua-2.8.14-official.zip",
    "sha256": "c6e1a4517328c4df20887bba4b6bb40a375344ec5230a39cfd35a99c9708819f"
  }
]
```

This is a publishing template, **not an existing URL**. No mirror was uploaded during development. The EXE accepts only matching pinned hashes and approved repository URLs, falling back to the official fixed GitHub source. Until the mirror is published/configured, dependency auto-download needs GitHub connectivity; manual NG+ ZIP import remains available. LMM itself already has working dual-source release assets.

## Verification commands

```powershell
dotnet build installer/StarLux.Installer.csproj -c Release
$exe = 'D:/Starlux_LMM/installer/bin/Release/net10.0-windows/win-x64/StarLux_LMM_installer_安装器.exe'
Start-Process -FilePath $exe -ArgumentList @('--self-test', 'D:/Starlux_LMM/.tools/installer-tests.json', 'D:/Starlux_LMM/dist/StarLux_LMM_Installer/version/1.1.8beta-language-fix') -Wait -WindowStyle Hidden
```

Optional `--network` downloads and validates both public 1.1.4 sources; `--fwl-archive PATH` validates the pinned archive and installs/restores it in a fixture. Test fixture roots remain in OS temp for inspection. `--inspect XP_ROOT OUTPUT.json` and `--detect OUTPUT.json` are read-only diagnostics; `--render OUTPUT.png` produces an off-screen UI preview without connecting to the internet. Paths with spaces must be quoted in process argument strings.

Before wider publication: test on a clean Windows 10/11 machine (no SDK), non-admin directories, 125–200% DPI, no FWL, an existing custom FWL setup, multiple Steam libraries, offline/GitHub-blocked networks, and a real XP12 startup after installation. Current verification covers the executable and fixture file operations, not an actual simulator startup. Sign the EXE with the publisher's code-signing certificate before general release where practical; no certificate or identity is invented by this project.

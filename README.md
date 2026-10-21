# StarLux SLM · 1.2.0 RC1

**Landing analysis and replay for X-Plane · Universal · Windows x64 · Chinese & English**

The 1.2.0 native-plugin update is now at **Release Candidate 1**. It combines touchdown metrics, flight recording, live overlays and interactive HTML replay in one package.

**[Download RC1 with installer](https://github.com/Starlux531/StarLux-Landing-Meter/releases/download/v1.2.0rc1/StarLux_LMM_v1.2.0rc1_WithInstaller.zip)** · [Release notes](https://github.com/Starlux531/StarLux-Landing-Meter/releases/tag/v1.2.0rc1) · [All releases](https://github.com/Starlux531/StarLux-Landing-Meter/releases)

![StarLux SLM 1.2.0 update overview](https://github.com/Starlux531/StarLux-Landing-Meter/releases/download/v1.2.0rc1/StarLux_SLM_1.2.0_Release_Poster_EN.png)

## What's new in 1.2.0

- **Native XPL plugin:** standalone operation, automatic backend selection and a shared bilingual interface.
- **Startup checks and continuous updates:** database progress, version checks and update notifications in the plugin popup.
- **HTML reader hot updates:** compatible reader-only updates can be applied in game.
- **Adaptive touchdown sampling:** improved FPM/G selection, quality checks and Low FPS notices when sampling is affected.
- **Custom report storage:** keep reports inside the plugin or choose another folder.
- **Legacy migration:** installer 1.0.6 moves StarLux settings, reports and airport caches into the new layout.

The Universal package replaces the Standard/Compatibility split. StarLux SLM runs independently of FlyWithLua.

## Install and update

1. Exit X-Plane and extract the complete bundle.
2. Run the included **1.0.6** installer with the `version/` folder beside it.
3. Select your X-Plane root, choose **1.2.0rc1 · Universal**, and review **Install / update**.
4. Start X-Plane and open **Plugins → StarLux LMM → Settings**.

Existing installer 1.0.6 users can select RC1 from the online catalog. Installers 1.0.2–1.0.4 offer an installer update first; 1.0.0 users can use the complete bundle.

Plugin binary updates use the installer after exiting X-Plane. Compatible HTML-only updates use the in-game update action. Reports default to `Resources/plugins/StarLux_LMM/data/LMM_Log/`.

[Installation guide](https://github.com/Starlux531/StarLux-Landing-Meter/releases/download/v1.2.0rc1/INSTALL_README.md) · [Checksums](https://github.com/Starlux531/StarLux-Landing-Meter/releases/download/v1.2.0rc1/SHA256SUMS.txt)

## Source and releases

This repository hosts **StarLux SLM Open Source** and software releases for 1.2.0 onward.

- **[StarLux SLM Open Source](StarLux%20SLM%20%20Open%20Source/README.md):** 1.1.9 and earlier source releases, available for extension and integration under their accompanying licenses.
- **1.2.0 onward:** distributed as the **StarLux Flight Landing Analysis & Replay Engine (Flare)** module, with software packages, release notes and third-party notices.

Earlier release tags and downloads remain available in [Releases](https://github.com/Starlux531/StarLux-Landing-Meter/releases).

## Feedback

For RC1, check touchdown results, live overlays, sustained low FPS versus isolated stalls, and report/chart playback. Include the simulator `Log.txt` and affected landing report when opening an issue.

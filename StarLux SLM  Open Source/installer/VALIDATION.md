# Installer v1.0 validation · 2026-09-13

Local Windows x64 build of installer **1.0.0** completed with the .NET 10 SDK. The generated executable is self-contained. The offline bundle includes the unchanged completed **plugin 1.1.8**, in four Standard/Compatibility × CN/International variants. Plugin 1.1.9 remains unreleased.

## Results

- **43 C# tests passed**, including existing path/ZIP/download/backup tests and the new maintenance lifecycle. Cases cover missing and modified files, mixed scripts and UI leftovers, incompatible/unknown XP versions, corrupt or inconsistent receipts, keep-settings and clean repair, uninstall/restore, and injected failures.
- **Actual EXE replacement and restarted-process tests passed** using a private higher-version fixture (`1.0.1`, test-only). Successful replacement produced a readiness acknowledgement. Deliberately failing readiness restored the previous EXE. Sibling package and backup files retained their contents. These tests use temporary portable installations, not the user's running installer or simulator.
- **9 analyzer preference keys** verified with Node: reset on the first page load for a clean-install token, preservation on subsequent loads, reset again for a later clean install, unrelated keys retained, and blocked storage handled without an uncaught error.
- Both update catalogs were tested with mock HTTP responses, including independent installer tags, mirror metadata, network failure and conflicting version families. Cached update indications continue flashing after an unsuccessful recheck; unknown connectivity does not claim to be current.
- Chinese and English previews were rendered and visually inspected. Test statuses are simulated. Red update indicators, non-flashing current states, and English status text were checked.
- Update archive/executable manifests, release metadata, SHA256SUMS and the portable ZIP layout were verified. All four embedded plugin payloads match their 1.1.8 manifest hashes and exclude user configuration/log files.

Machine-readable run output: `.tools/installer-v1/final-tests.json`. The output records its temporary fixture directory. Analyzer reset checks use that fixture's `analyzer-reset.html`. Artifact verification: `python tests/verify_installer_release.py`.

## Delivered local artifacts

`dist/installer/1.0.0/` contains the executable, offline ZIP, self-update ZIP, release metadata, checksums and user guide. The offline ZIP has exactly the EXE and `version/` at the root.

No real X-Plane directory was modified. No releases were uploaded. Production online self-update still requires the documented `installer-v1.0.0` assets on the official repositories. Actual simulator loading, end-user DPI configurations and published-channel operation remain release acceptance checks; local file tests are not substitutes for them.

param([switch]$SkipPublish, [string]$InstallerPath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$utf8 = [Text.UTF8Encoding]::new($false)
$development = Get-Content -LiteralPath (Join-Path $repo 'development.json') -Raw | ConvertFrom-Json
$developmentVersion = [string]$development.version
$stable = $development.channel -eq 'stable' -and $developmentVersion -eq '1.1.9'
if (!$stable -and ($development.channel -ne 'unpublished' -or $developmentVersion -notmatch '^1\.1\.9-beta[1-9][0-9]*$')) { throw 'Use stable 1.1.9 or an explicit unpublished 1.1.9-betaN in development.json.' }
$mainSource = [IO.File]::ReadAllText((Join-Path $repo 'StarLux_LMM_v1.1.9.lua'))
if (!$mainSource.StartsWith("-- StarLux 落地率插件 v$developmentVersion`n") -and !$mainSource.StartsWith("-- StarLux 落地率插件 v$developmentVersion`r`n")) { throw 'Main source header must match development.json.' }
# Local packaging for 1.1.9; this script does not publish to GitHub.
$readerPath = Join-Path $repo 'LMM_Report_Reader.html'
$reader = [IO.File]::ReadAllText($readerPath)
$reader = [regex]::Replace($reader, '(<small id="analyzerBuild"[^>]*>)[^<]*(</small>)', [Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $developmentVersion + $m.Groups[2].Value })
$presets = [IO.File]::ReadAllText((Join-Path $repo '发行预设/analyzer-presets.json'))
$embedded = '<script type="application/json" id="lmm-bundled-presets">' + $presets + '</script>'
if ($reader.Contains('id="lmm-bundled-presets"')) {
    $reader = [regex]::Replace($reader, '<script type="application/json" id="lmm-bundled-presets">[\s\S]*?</script>', [Text.RegularExpressions.MatchEvaluator]{ param($m) $embedded })
} else { $reader = $reader.Replace('<style>', $embedded + "`n<style>") }
[IO.File]::WriteAllText($readerPath, $reader, $utf8)
# Independent storage namespace, no bridge and no dependencies outside this HTML.
$standalone = $reader.Replace('starlux-lmm-reader-', 'starlux-lmm-standalone-reader-').Replace('<title>StarLux LMM 分析器</title>', '<title>StarLux Analyzer · 落地分析器</title>')
[IO.File]::WriteAllText((Join-Path $repo 'Starlux_Analyzer_落地分析器.html'), $standalone, $utf8)
$release = Join-Path $repo "dist/$developmentVersion"
$bundle = Join-Path $release "StarLux_LMM_Installer_$developmentVersion"
New-Item -ItemType Directory -Force -Path $bundle | Out-Null
if ($InstallerPath) {
    Copy-Item -LiteralPath $InstallerPath -Destination (Join-Path $bundle 'StarLux_LMM_installer_安装器.exe') -Force
} elseif (!$SkipPublish) {
    & 'C:/Program Files/dotnet/dotnet.exe' publish (Join-Path $repo 'installer/StarLux.Installer.csproj') -c Release -o $bundle --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Installer publish failed' }
}
if (!(Test-Path -LiteralPath (Join-Path $bundle 'StarLux_LMM_installer_安装器.exe'))) { throw 'Build installer first' }
foreach ($variant in @('Standard','Compatibility')) {
    foreach ($locale in @('CN','International')) {
        $id = "$developmentVersion-$variant-$locale"
        $package = Join-Path $bundle "version/$id"
        $payload = Join-Path $package 'payload'
        New-Item -ItemType Directory -Force -Path $payload | Out-Null
        foreach ($name in @('LMM_Report_Reader.html','README_1.1.9.md','LICENSE')) {
            Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $payload -Force
        }
        # Copy directory contents explicitly so rebuilding never nests LMM_UI_119.
        $uiTarget = Join-Path $payload 'LMM_UI_119'
        New-Item -ItemType Directory -Force -Path $uiTarget | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $repo 'LMM_UI_119') | Copy-Item -Destination $uiTarget -Recurse -Force
        $scriptPath = Join-Path $payload "StarLux_LMM_v$developmentVersion.lua"
        $script = $mainSource
        if ($variant -eq 'Compatibility') {
            if (!$script.Contains('force_compatibility = false')) { throw 'Compatibility marker missing' }
            $script = $script.Replace('force_compatibility = false','force_compatibility = true')
        }
        if ($locale -eq 'International') {
            if (!$script.Contains('    document_language = "zh",')) { throw 'Default language marker missing' }
            $script = $script.Replace('    document_language = "zh",','    document_language = "en",')
        }
        [IO.File]::WriteAllText($scriptPath, $script, $utf8)
        $entries = @(Get-ChildItem -LiteralPath $payload -File -Recurse | Sort-Object FullName | ForEach-Object {
            @{ path = [IO.Path]::GetRelativePath($payload,$_.FullName).Replace('\','/'); sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() }
        })
        $manifest = @{
            schema=1; product='StarLux_LMM'; version=$developmentVersion; build="$developmentVersion-$variant-$locale"; kind='flywithlua'
            uiVariant=$(if ($variant -eq 'Standard') {'sdk440'} else {'legacy'})
            defaultLanguage=$(if ($locale -eq 'CN') {'zh'} else {'en'})
            notes=$(if ($stable) {
                if ($variant -eq 'Standard') {'1.1.9 正式版。标准版：XP 12.4.4+。 / Stable 1.1.9. Standard: XP 12.4.4+.'}
                else {'1.1.9 正式版。兼容版：旧 XP 12，覆盖层为数字显示。 / Stable 1.1.9. Compatibility: older XP 12; numeric overlays.'}
            } elseif ($variant -eq 'Standard') {'未发布开发测试版，待实机验收。标准版：XP 12.4.4+。 / Unreleased development build, flight validation pending. Standard: XP 12.4.4+.'} else {'未发布开发测试版，兼容覆盖层暂为数字显示。 / Unreleased development build; legacy overlays currently display numbers.'})
            files=$entries
        }
        [IO.File]::WriteAllText((Join-Path $package 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), $utf8)
        Compress-Archive -LiteralPath (Join-Path $package 'manifest.json'),$payload -DestinationPath (Join-Path $release "StarLux_LMM_v$id.zip") -Force
    }
}
$extras = Join-Path $bundle 'version'
foreach ($name in @('Starlux_Analyzer_落地分析器.html','README_1.1.9.md')) {
    Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $extras -Force
    Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $release -Force
}
Copy-Item -LiteralPath (Join-Path $repo '发行预设/analyzer-presets.json') -Destination $extras -Force
Copy-Item -LiteralPath (Join-Path $repo '发行预设/analyzer-presets.json') -Destination $release -Force
# A locally used installer can create its own recovery folder. Keep it in place;
# the archive below explicitly contains only the executable and version payloads.
$rootNames = @(Get-ChildItem -LiteralPath $bundle | Where-Object { !($_.PSIsContainer -and $_.Name -eq 'backup') } | ForEach-Object Name)
if ($rootNames.Count -ne 2 -or $rootNames -notcontains 'version' -or $rootNames -notcontains 'StarLux_LMM_installer_安装器.exe') { throw 'Bundle root must contain only installer and version' }
Compress-Archive -LiteralPath (Join-Path $bundle 'StarLux_LMM_installer_安装器.exe'),$extras -DestinationPath ($bundle+'.zip') -Force
Copy-Item -LiteralPath (Join-Path $bundle 'StarLux_LMM_installer_安装器.exe') -Destination $release -Force
$hashes = @(Get-ChildItem -LiteralPath $release -File | Where-Object {$_.Name -ne 'SHA256SUMS.txt'} | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() + '  ' + $_.Name })
[IO.File]::WriteAllLines((Join-Path $release 'SHA256SUMS.txt'), $hashes, $utf8)
Write-Output "Release built: $release"

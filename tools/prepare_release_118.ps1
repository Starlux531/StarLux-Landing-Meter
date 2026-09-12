param([switch]$SkipPublish)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$utf8 = [Text.UTF8Encoding]::new($false)
# Mechanical promotion; beta source remains available for comparison/rollback.
$main = Join-Path $repo 'StarLux_LMM_v1.1.8.lua'
[IO.File]::WriteAllText($main, [IO.File]::ReadAllText($main).Replace('1.1.8beta','1.1.8'), $utf8)
$readerPath = Join-Path $repo 'LMM_Report_Reader.html'
$reader = [IO.File]::ReadAllText($readerPath)
$presets = [IO.File]::ReadAllText((Join-Path $repo '发行预设/analyzer-presets.json'))
$embedded = '<script type="application/json" id="lmm-bundled-presets">' + $presets + '</script>'
if ($reader.Contains('id="lmm-bundled-presets"')) {
    $reader = [regex]::Replace($reader, '<script type="application/json" id="lmm-bundled-presets">[\s\S]*?</script>', [Text.RegularExpressions.MatchEvaluator]{ param($m) $embedded })
} else { $reader = $reader.Replace('<style>', $embedded + "`n<style>") }
[IO.File]::WriteAllText($readerPath, $reader, $utf8)
# Independent storage namespace, no bridge and no dependencies outside this HTML.
$standalone = $reader.Replace('starlux-lmm-reader-', 'starlux-lmm-standalone-reader-').Replace('<title>StarLux LMM 分析器</title>', '<title>StarLux Analyzer · 落地分析器</title>')
[IO.File]::WriteAllText((Join-Path $repo 'Starlux_Analyzer_落地分析器.html'), $standalone, $utf8)
$release = Join-Path $repo 'dist/1.1.8'
$bundle = Join-Path $release 'StarLux_LMM_Installer_1.1.8'
New-Item -ItemType Directory -Force -Path $bundle | Out-Null
if (!$SkipPublish) {
    & 'C:/Program Files/dotnet/dotnet.exe' publish (Join-Path $repo 'installer/StarLux.Installer.csproj') -c Release -o $bundle --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Installer publish failed' }
}
if (!(Test-Path -LiteralPath (Join-Path $bundle 'StarLux_LMM_installer_安装器.exe'))) { throw 'Build installer first' }
foreach ($variant in @('Standard','Compatibility')) {
    foreach ($locale in @('CN','International')) {
        $id = "1.1.8-$variant-$locale"
        $package = Join-Path $bundle "version/$id"
        $payload = Join-Path $package 'payload'
        New-Item -ItemType Directory -Force -Path $payload | Out-Null
        foreach ($name in @('StarLux_LMM_v1.1.8.lua','LMM_Report_Reader.html','README_1.1.8.md','LICENSE')) {
            Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $payload -Force
        }
        # Copy directory contents explicitly so rebuilding never nests LMM_UI_118.
        $uiTarget = Join-Path $payload 'LMM_UI_118'
        New-Item -ItemType Directory -Force -Path $uiTarget | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $repo 'LMM_UI_118') | Copy-Item -Destination $uiTarget -Recurse -Force
        $scriptPath = Join-Path $payload 'StarLux_LMM_v1.1.8.lua'
        $script = [IO.File]::ReadAllText($scriptPath)
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
            schema=1; product='StarLux_LMM'; version='1.1.8'; build="20260912-$variant-$locale"; kind='flywithlua'
            uiVariant=$(if ($variant -eq 'Standard') {'sdk440'} else {'legacy'})
            defaultLanguage=$(if ($locale -eq 'CN') {'zh'} else {'en'})
            notes=$(if ($variant -eq 'Standard') {'标准版：X-Plane 12.4.4+，原生中文 UI。 / Standard: XP 12.4.4+, native Chinese UI.'} else {'旧版 UI 兼容：X-Plane 12、12.4.4 之前；传统英文设置控件，中文报告和标准字号中文弹窗保留。 / Legacy UI: XP 12 before 12.4.4; English settings, Chinese reports and normal-size Chinese popup retained.'})
            files=$entries
        }
        [IO.File]::WriteAllText((Join-Path $package 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), $utf8)
        Compress-Archive -LiteralPath (Join-Path $package 'manifest.json'),$payload -DestinationPath (Join-Path $release "StarLux_LMM_v$id.zip") -Force
    }
}
$extras = Join-Path $bundle 'version'
foreach ($name in @('Starlux_Analyzer_落地分析器.html','README_1.1.8.md')) {
    Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $extras -Force
    Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $release -Force
}
Copy-Item -LiteralPath (Join-Path $repo '发行预设/analyzer-presets.json') -Destination $extras -Force
Copy-Item -LiteralPath (Join-Path $repo '发行预设/analyzer-presets.json') -Destination $release -Force
$rootNames = @(Get-ChildItem -LiteralPath $bundle | ForEach-Object Name)
if ($rootNames.Count -ne 2 -or $rootNames -notcontains 'version' -or $rootNames -notcontains 'StarLux_LMM_installer_安装器.exe') { throw 'Bundle root must contain only installer and version' }
Compress-Archive -LiteralPath (Join-Path $bundle 'StarLux_LMM_installer_安装器.exe'),$extras -DestinationPath ($bundle+'.zip') -Force
Copy-Item -LiteralPath (Join-Path $bundle 'StarLux_LMM_installer_安装器.exe') -Destination $release -Force
$hashes = @(Get-ChildItem -LiteralPath $release -File | Where-Object {$_.Name -ne 'SHA256SUMS.txt'} | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() + '  ' + $_.Name })
[IO.File]::WriteAllLines((Join-Path $release 'SHA256SUMS.txt'), $hashes, $utf8)
Write-Output "Release built: $release"

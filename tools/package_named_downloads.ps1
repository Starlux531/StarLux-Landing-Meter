$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$version = (Get-Content -LiteralPath (Join-Path $repo 'development.json') -Raw | ConvertFrom-Json).version
$release = Join-Path $repo "dist/$version"
# GitHub sanitizes non-ASCII release asset names. ZIP entries preserve originals.
Compress-Archive -LiteralPath (Join-Path $release 'Starlux_Analyzer_落地分析器.html') -DestinationPath (Join-Path $release "Starlux_Analyzer_$version.zip") -Force
Compress-Archive -LiteralPath (Join-Path $release 'StarLux_LMM_installer_安装器.exe') -DestinationPath (Join-Path $release "StarLux_LMM_Installer_Only_$version.zip") -Force
$hashes = @(Get-ChildItem -LiteralPath $release -File | Where-Object {$_.Name -ne 'SHA256SUMS.txt'} | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() + '  ' + $_.Name })
[IO.File]::WriteAllLines((Join-Path $release 'SHA256SUMS.txt'),$hashes,[Text.UTF8Encoding]::new($false))

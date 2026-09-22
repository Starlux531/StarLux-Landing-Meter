param(
    [switch]$SkipPublish,
    [switch]$NoRestore,
    [string]$PluginVersionDirectory = ''
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$project = Join-Path $PSScriptRoot 'StarLux.Installer.csproj'
$version = ([xml](Get-Content -LiteralPath $project -Raw)).Project.PropertyGroup.Version
$output = Join-Path $repo "dist/installer/$version"
$published = Join-Path $repo '.tools/installer-v1/published'
$utf8 = [Text.UTF8Encoding]::new($false)
if (!$SkipPublish) {
    $arguments = @('publish', $project, '-c', 'Release', '-o', $published, '--nologo')
    if ($NoRestore) { $arguments += '--no-restore' }
    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Installer publish failed' }
}
$exeName = 'StarLux_LMM_installer_安装器.exe'
$exe = Join-Path $published $exeName
$info = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
if ($info.ProductName -ne 'StarLux LMM Installer' -or ($info.ProductVersion -split '\+')[0] -ne $version) { throw 'Published installer product/version does not match project' }
$stage = Join-Path $repo ('.tools/installer-v1/build-' + [guid]::NewGuid().ToString('N'))
$bundle = Join-Path $stage 'bundle'
$update = Join-Path $stage 'update'
New-Item -ItemType Directory -Force -Path $output,$bundle,$update | Out-Null
Copy-Item -LiteralPath $exe -Destination $bundle
New-Item -ItemType Directory -Path (Join-Path $bundle 'version') | Out-Null
if ($PluginVersionDirectory) {
    $source = (Resolve-Path -LiteralPath $PluginVersionDirectory).Path
    if (@(Get-ChildItem -LiteralPath $source -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Plugin source contains links' }
    # Use an explicitly supplied completed plugin distribution; never promote 1.1.9 automatically.
    Get-ChildItem -LiteralPath $source | Copy-Item -Destination (Join-Path $bundle 'version') -Recurse
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'USER_GUIDE.md') -Destination (Join-Path $bundle 'version/Installer_Guide.md')
Copy-Item -LiteralPath $exe -Destination $update
$manifest = @{ schema=1; product='StarLux_LMM_Installer'; version=$version; executable=$exeName; sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant() }
[IO.File]::WriteAllText((Join-Path $update 'installer-update.json'),($manifest | ConvertTo-Json),$utf8)
$asset = "StarLux_LMM_Installer_Update_v$version.zip"
Compress-Archive -LiteralPath (Join-Path $update $exeName),(Join-Path $update 'installer-update.json') -DestinationPath (Join-Path $output $asset) -Force
$release = @{ schema=1; product='StarLux_LMM_Installer'; version=$version; asset=$asset; sha256=(Get-FileHash -LiteralPath (Join-Path $output $asset)).Hash.ToLowerInvariant() }
[IO.File]::WriteAllText((Join-Path $output 'installer-release.json'),($release | ConvertTo-Json),$utf8)
Compress-Archive -LiteralPath (Join-Path $bundle $exeName),(Join-Path $bundle 'version') -DestinationPath (Join-Path $output "StarLux_LMM_Installer_v$version.zip") -Force
Copy-Item -LiteralPath $exe -Destination $output -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'USER_GUIDE.md') -Destination $output -Force
$hashes = @(Get-ChildItem -LiteralPath $output -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() + '  ' + $_.Name })
[IO.File]::WriteAllLines((Join-Path $output 'SHA256SUMS.txt'),$hashes,$utf8)
Write-Output "Installer $version packaged locally: $output"
Write-Output "Release tag contract: installer-v$version. No files have been uploaded."

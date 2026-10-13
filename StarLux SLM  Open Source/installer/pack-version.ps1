param(
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$DestinationDirectory,
    [Parameter(Mandatory)][string]$Version,
    [string]$Build = '',
    [ValidateSet('flywithlua','native')][string]$Kind = 'flywithlua',
    [string]$Notes = '',
    [ValidateSet('','sdk440','legacy')][string]$UiVariant = '',
    [ValidateSet('','zh','en')][string]$DefaultLanguage = ''
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$destination = [IO.Path]::GetFullPath($DestinationDirectory)
if ($Version -notmatch '^\d+\.\d+(\.\d+)?([-\.]?(alpha|beta|rc)\d*)?$') { throw 'Use a numeric version with an optional alpha/beta/rc suffix.' }
if (Test-Path -LiteralPath $destination) { throw 'Choose a new destination directory. Existing packages are never overwritten.' }
if ($destination.StartsWith($source.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Destination must be outside the source directory.' }
$items = @(Get-ChildItem -LiteralPath $source -Recurse -Force)
if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) { throw 'Symlinks and junctions are not supported.' }
$files = @($items | Where-Object { !$_.PSIsContainer })
if (!$files.Count) { throw 'Empty payload.' }
if ($Kind -eq 'flywithlua') {
    $mains = @($files | Where-Object { $_.DirectoryName -eq $source -and $_.Name -match '^StarLux_LMM(?:_v?[0-9][\w.\-]*)?\.lua$' })
    if ($mains.Count -ne 1) { throw 'Exactly one top-level StarLux_LMM main script is required.' }
}
if ($Kind -eq 'native' -and !(Test-Path -LiteralPath (Join-Path $source 'win_x64/StarLux_LMM.xpl'))) { throw 'Native payload requires win_x64/StarLux_LMM.xpl.' }
foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($source, $file.FullName).Replace('\','/')
    if ($Kind -eq 'flywithlua' -and $relative -notmatch '^(StarLux_LMM(?:_v?[0-9][\w.\-]*)?\.lua|LMM_Report_Reader\.html|LICENSE|README[^/]*\.(md|txt)|LMM_UI_[0-9]+/([\w.-]+\.lua|fonts/[\w.-]+\.(otf|ttf|txt|json)))$') {
        throw "Unexpected payload file: $relative. Remove configs, logs and archives from the source first."
    }
}
$payload = Join-Path $destination 'payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
$entries = @($files | Sort-Object FullName | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($source, $_.FullName)
    $targetFile = Join-Path $payload $relative
    New-Item -ItemType Directory -Path (Split-Path $targetFile -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $targetFile
    @{ path = $relative.Replace('\','/'); sha256 = (Get-FileHash -LiteralPath $targetFile).Hash.ToLowerInvariant() }
})
$manifest = @{ schema=1; product='StarLux_LMM'; version=$Version; build=$Build; kind=$Kind; notes=$Notes; uiVariant=$UiVariant; defaultLanguage=$DefaultLanguage; files=$entries }
[IO.File]::WriteAllText((Join-Path $destination 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
Write-Output "Package created: $destination"

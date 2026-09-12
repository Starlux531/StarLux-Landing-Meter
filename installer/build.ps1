param([switch]$SkipPublish)
$ErrorActionPreference = 'Stop'
# Stable release builder: four UI/language packages, standalone reader and presets.
& (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/prepare_release_118.ps1') -SkipPublish:$SkipPublish

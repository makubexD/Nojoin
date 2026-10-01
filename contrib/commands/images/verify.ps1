#: fail if the compose override disagrees with images.psd1

<#
.SYNOPSIS
    Exit non-zero when compose.podman.yml does not repeat images.psd1 exactly.
#>
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force

$state = Get-ImageMirrorState
$bad = @($state.Files | Where-Object { -not $_.Agrees })

if ($bad.Count -eq 0) {
    Write-Pass 'images' "$($state.Files.Count) mirror(s) agree with NojoinTag $($state.Tag)"
    exit 0
}

foreach ($f in $bad) {
    Write-Fail $f.Note "$($f.File)  $($f.Detail)"
}
Write-Host ""
Write-Host "  fix: .\contrib\maku.ps1 images pin v$($state.Tag)"
exit 1

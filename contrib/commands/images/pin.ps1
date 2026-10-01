#: set NojoinTag and the compose default to a release

<#
.SYNOPSIS
    Point the fork at one upstream release.

.DESCRIPTION
    Accepts vX.Y.Z or X.Y.Z and stores X.Y.Z, which is the GHCR tag.
    Rewrites contrib/images.psd1 and every TagMirrors file, then runs images verify.
    Does not commit. fork sync commits the pin when it moves.

.PARAMETER Tag
    The release to pin.

.PARAMETER SkipInspect
    Write the pin without asking the registry whether the four images exist.

.EXAMPLE
    .\contrib\maku.ps1 images pin v2.5.1
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Tag,

    [switch]$SkipInspect
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Use-NativeExitCodes

$tag = ConvertTo-ImageTag $Tag

if (-not $SkipInspect) {
    if (-not (Test-ImagesPublished $tag)) {
        throw (New-Refusal "ghcr.io/valtora/nojoin-*:${tag} is not published for all four images." `
                           "re-run with -SkipInspect if the tag should be written anyway")
    }
}

$touched = @(Set-NojoinTag $tag)
if ($touched.Count -eq 0) {
    Write-Host "Already pinned to $tag."
} else {
    Write-Host "Pinned Nojoin to $tag in:"
    $touched | ForEach-Object { Write-Host "    $_" }
}

& (Join-Path $PSScriptRoot 'verify.ps1')
exit $LASTEXITCODE

#: print the pinned tag and the fully qualified image refs

<#
.SYNOPSIS
    Print NojoinTag and every image reference, and whether the compose override agrees.
#>
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force

$data = Get-ImageData
$tag = Get-NojoinTag

Write-Host ""
Write-Host ("  {0,-14} {1}" -f 'tag', $tag)
Write-Host ("  {0,-14} {1}" -f 'git tag', "v$tag")
Write-Host ""
foreach ($repo in (Get-NojoinRepos)) {
    Write-Host ("  {0}" -f "${repo}:${tag}")
}
Write-Host ""
foreach ($image in (Get-ThirdPartyImages)) {
    Write-Host ("  {0}" -f $image)
}
Write-Host ""

$state = Get-ImageMirrorState
foreach ($f in $state.Files) {
    if ($f.Agrees) { Write-Host ("  ok        {0}" -f $f.File) }
    else { Write-Host ("  DIFFERS   {0}  {1}" -f $f.File, $f.Detail) -ForegroundColor Red }
}
Write-Host ""
exit 0

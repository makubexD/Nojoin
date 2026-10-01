#: ahead/behind against upstream, and the current image pin

<#
.SYNOPSIS
    Show how far this branch is from upstream/main, and which image tag is pinned.

.PARAMETER Branch
    Which branch to report. Defaults to the one checked out.

.EXAMPLE
    .\contrib\maku.ps1 fork status
#>
param([string]$Branch)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Use-NativeExitCodes

if (-not $Branch) { $Branch = Get-CurrentBranch }

& git rev-parse --verify --quiet upstream/main | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw (New-Refusal "This clone has no upstream/main to compare against." `
                       ".\contrib\maku.ps1 fork sync")
}

$ahead  = (& git rev-list --count "upstream/main..$Branch").Trim()
$behind = (& git rev-list --count "$Branch..upstream/main").Trim()
if ($LASTEXITCODE -ne 0) {
    throw (New-Refusal "Could not compare '$Branch' with upstream/main." `
                       "git rev-parse --verify $Branch")
}

$behindNote = if ($behind -eq '0') { 'up to date' }
              else { 'run: .\contrib\maku.ps1 fork sync' }
$tag = Get-NojoinTag

Write-Host ""
Write-Host "  $Branch vs Valtora/Nojoin:main"
Write-Host ""
Write-Host ("    {0,-8} {1,6}   {2}" -f 'ahead',  $ahead,  'commits this fork carries')
Write-Host ("    {0,-8} {1,6}   {2}" -f 'behind', $behind, $behindNote)
Write-Host ("    {0,-8} {1,6}   {2}" -f 'pin',    $tag,    "image tag (upstream git tag v$tag)")
Write-Host ""

# The nginx entrypoint runs this script with sh, so the git execute bit is not
# required. Report the index mode when the file is tracked. Untracked files
# have no mode yet. .gitattributes only forces LF.
$resolverRel = 'contrib/podman/nginx/05-podman-resolver.sh'
$indexLine = (& git ls-files -s -- $resolverRel | Out-String).Trim()
if ($indexLine) {
    $mode = ($indexLine -split '\s+', 2)[0]
    Write-Host "info  resolver  $resolverRel is mode $mode in git (informational; the entrypoint runs it with sh)"
}
exit 0

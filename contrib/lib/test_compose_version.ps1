# Checks Test-ComposeVersionSupported against the external-provider banner
# and the Docker Compose version floor, then runs the live
# `podman compose version` text through Get-ComposeVersionText.
# Does not start, stop, or reconfigure the Podman machine. Does not read .env.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Podman.psm1') -Force

$banner = @(
    '>>>> Executing external compose provider "C:\Program Files\Podman\docker-compose.exe". Please see podman-compose(1) for how to disable this message. <<<<'
    'Docker Compose version v5.1.0'
) -join "`n"

$cases = @(
    @{ Name = 'banner plus Docker Compose v5.1.0'; Text = $banner; Expect = $true }
    @{ Name = 'Docker Compose v2.24.0'; Text = 'Docker Compose version v2.24.0'; Expect = $true }
    @{ Name = 'Docker Compose v2.40.3'; Text = 'Docker Compose version v2.40.3'; Expect = $true }
    @{ Name = 'Docker Compose v2.23.9'; Text = 'Docker Compose version v2.23.9'; Expect = $false }
    @{ Name = 'podman-compose 1.3.0'; Text = 'podman-compose version 1.3.0'; Expect = $false }
    @{ Name = 'empty'; Text = ''; Expect = $false }
)

$failed = 0
foreach ($case in $cases) {
    $got = Test-ComposeVersionSupported $case.Text
    if ($got -ne $case.Expect) {
        Write-Host "FAIL $($case.Name): got $got expected $($case.Expect)"
        $failed++
    } else {
        Write-Host "PASS $($case.Name) => $got"
    }
}

$warningBefore = $env:PODMAN_COMPOSE_WARNING_LOGS
$live = Get-ComposeVersionText
$warningAfter = $env:PODMAN_COMPOSE_WARNING_LOGS
Write-Host "LIVE_CODE=$($live.Code)"
Write-Host 'LIVE_TEXT<<'
Write-Host $live.Text
Write-Host '>>'
$liveOk = Test-ComposeVersionSupported $live.Text
Write-Host "LIVE_ACCEPTED=$liveOk"
Write-Host "WARNING_LOGS_BEFORE=[$warningBefore]"
Write-Host "WARNING_LOGS_AFTER=[$warningAfter]"
if ($live.Code -ne 0 -or -not $liveOk) { $failed++ }
if ($failed) { exit 1 }
exit 0

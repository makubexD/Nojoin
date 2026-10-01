#: wait until healthy, then check health, nginx, the socket, and DNS

<#
.SYNOPSIS
    Prove the running stack. Ends with DEPLOYMENT CHECK PASSED or DEPLOYMENT CHECK FAILED.

.DESCRIPTION
    Waits until every healthchecked service is healthy and the others are running,
    then checks:
        - https://localhost:14443/api/health returns status ok
        - https://localhost:14443/ returns 200
        - nginx rewrote 127.0.0.11 to the Podman nameserver and can proxy to api
        - the api can read nojoin-api logs through socket-proxy
        - host.docker.internal resolves inside the api container
        - uid 1000 can write /app/data
        - uid 1000 can write /home/appuser/.cache in nojoin-worker-cpu
#>
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Use-NativeExitCodes

$failed = 0
function Add-Failure { $script:failed++ }

function Get-ContainerProbe([string]$Name) {
    $fmt = '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}'
    $line = & podman inspect $Name --format $fmt 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $parts = @(($line | Out-String).Trim() -split '\|', 2)
    return @{
        Status = $parts[0]
        Health = $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
    }
}

$all = @(
    'nojoin-db', 'nojoin-redis', 'nojoin-socket-proxy', 'nojoin-api',
    'nojoin-worker-gpu', 'nojoin-worker-cpu', 'nojoin-worker-io', 'nojoin-worker-parse',
    'nojoin-frontend', 'nojoin-nginx'
)
$needHealth = Get-HealthcheckedContainers
$deadline = (Get-Date).AddMinutes(8)
$ready = $false
$nextReport = Get-Date

while ((Get-Date) -lt $deadline) {
    $bad = @()
    foreach ($name in $all) {
        $probe = Get-ContainerProbe $name
        if (-not $probe) { $bad += "$name missing"; continue }
        if ($name -in $needHealth) {
            if ($probe.Health -ne 'healthy') { $bad += "$name $($probe.Health)" }
        } elseif ($probe.Status -ne 'running') {
            $bad += "$name $($probe.Status)"
        }
    }
    if ($bad.Count -eq 0) { $ready = $true; break }
    if ((Get-Date) -ge $nextReport) {
        Write-Host ("waiting: " + ($bad -join ', '))
        $nextReport = (Get-Date).AddSeconds(15)
    }
    Start-Sleep -Seconds 3
}

if (-not $ready) {
    Write-Fail 'healthy' 'services did not become healthy within 8 minutes'
    Add-Failure
} else {
    Write-Pass 'healthy' 'all services'
}

function Get-Https([string]$Url) {
    try {
        return Invoke-WebRequest -Uri $Url -SkipCertificateCheck -TimeoutSec 20
    } catch {
        return $_.Exception.Response
    }
}

$health = Get-Https 'https://localhost:14443/api/health'
$healthStatus = $null
if ($health -and $health.Content) {
    try { $healthStatus = [string](($health.Content | ConvertFrom-Json).status) } catch { $healthStatus = $null }
}
if ($healthStatus -eq 'ok') {
    Write-Pass 'health' 'status ok'
} else {
    $code = if ($health) { [int]$health.StatusCode } else { 0 }
    Write-Fail 'health' "https://localhost:14443/api/health status=$healthStatus http=$code"
    Add-Failure
}

$rootPage = Get-Https 'https://localhost:14443/'
$rootCode = 0
if ($rootPage -and $rootPage.StatusCode) { $rootCode = [int]$rootPage.StatusCode }
if ($rootCode -eq 200) {
    Write-Pass 'frontend' 'HTTP 200'
} else {
    Write-Fail 'frontend' "https://localhost:14443/ returned $rootCode"
    Add-Failure
}

$generated = (& podman exec nojoin-nginx cat /etc/nginx/nginx.conf 2>&1 | Out-String)
$generatedCode = $LASTEXITCODE
$upstream = (& podman exec nojoin-nginx cat /etc/nginx/nginx.conf.upstream 2>&1 | Out-String)
$upstreamCode = $LASTEXITCODE
$resolverOk = ($generatedCode -eq 0) -and ($upstreamCode -eq 0) -and
              ($upstream -match 'resolver 127\.0\.0\.11') -and
              ($generated -notmatch 'resolver 127\.0\.0\.11') -and
              ($generated -match 'resolver\s+\S+')
if ($resolverOk -and $healthStatus -eq 'ok') {
    Write-Pass 'resolver' 'nginx proxied api with the Podman nameserver'
} else {
    Write-Fail 'resolver' 'nginx did not rewrite 127.0.0.11, or /api/health did not succeed through it'
    Add-Failure
}

$logProbe = 'import urllib.request; u="http://socket-proxy:2375/v1.41/containers/nojoin-api/logs?stdout=1&stderr=1&tail=1"; r=urllib.request.urlopen(u, timeout=15); r.read(32); raise SystemExit(0 if r.status == 200 else 1)'
& podman exec nojoin-api python -c $logProbe | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Pass 'socket' 'api read nojoin-api logs through socket-proxy'
} else {
    Write-Fail 'socket' ('api could not read logs through socket-proxy (exit ' + $LASTEXITCODE + ')')
    Add-Failure
}

$dnsProbe = 'import socket; socket.getaddrinfo("host.docker.internal", 11434); print("ok")'
$dns = (& podman exec nojoin-api python -c $dnsProbe 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -eq 0 -and $dns -match 'ok') {
    Write-Pass 'host-gateway' 'host.docker.internal resolves in the api'
} else {
    Write-Fail 'host-gateway' 'host.docker.internal did not resolve in the api'
    Add-Failure
}

& podman exec --user 1000:1000 nojoin-api sh -c 'touch /app/data/.maku-write-probe && rm -f /app/data/.maku-write-probe' | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Pass 'data' 'uid 1000 can write /app/data'
} else {
    $fix = if ((Get-StackMode).DataVolume) {
        'the nojoin_data volume is not writable by uid 1000'
    } else {
        '.\contrib\maku.ps1 stack start -DataVolume'
    }
    Write-Fail 'data' 'uid 1000 cannot write /app/data'
    Write-Host "  fix: $fix" -ForegroundColor Red
    Add-Failure
}

& podman exec --user 1000:1000 nojoin-worker-cpu sh -c 'touch /home/appuser/.cache/.maku-write-probe && rm -f /home/appuser/.cache/.maku-write-probe' | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Pass 'cache' 'uid 1000 can write /home/appuser/.cache'
} else {
    Write-Fail 'cache' 'uid 1000 cannot write /home/appuser/.cache'
    Add-Failure
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host 'DEPLOYMENT CHECK PASSED'
    exit 0
}
Write-Host 'DEPLOYMENT CHECK FAILED'
exit 1

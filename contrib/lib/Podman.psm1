# Podman readiness, the compose invocation, and the port checks the stack
# commands share. Container arguments live in the compose files, not here.

Import-Module (Join-Path $PSScriptRoot 'Console.psm1')
Import-Module (Join-Path $PSScriptRoot 'Images.psm1')
Import-Module (Join-Path $PSScriptRoot 'Repo.psm1')

$script:Services = @(
    'db', 'redis', 'socket-proxy', 'api',
    'worker-gpu', 'worker-cpu', 'worker-io', 'worker-parse',
    'frontend', 'nginx'
)

$script:Healthchecked = @(
    'nojoin-db', 'nojoin-redis', 'nojoin-api', 'nojoin-frontend', 'nojoin-nginx'
)

function Get-StackServices { return @($script:Services) }

function Get-HealthcheckedContainers { return @($script:Healthchecked) }

function Assert-ServiceName([string]$Service) {
    if (-not $Service) { return }
    if ($Service -notin $script:Services) {
        throw (New-Refusal "Unknown service '$Service'." `
                           ($script:Services -join ', '))
    }
}

function Test-PodmanReady {
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        throw (New-Refusal "podman is not installed, or not on PATH." `
                           "install it -- contrib/fork/SETUP.md")
    }
    $version = (& podman --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "podman is on PATH but did not run.`n$version" `
                           "install it -- contrib/fork/SETUP.md")
    }

    try {
        Assert-PodmanResponds
        return
    } catch {
        $infoFailure = $_.Exception.Message
    }

    $listRaw = (& podman machine list --format json 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal ("podman info failed and 'podman machine' is not available, so a stopped VM cannot be started from here.`n" +
                            "podman info said:`n$infoFailure`n" +
                            "podman machine list said:`n$listRaw") `
                           "install it -- contrib/fork/SETUP.md")
    }

    $machines = @()
    if ($listRaw -and $listRaw -ne 'null') {
        try { $parsed = $listRaw | ConvertFrom-Json } catch {
            throw (New-Refusal "podman machine list did not return JSON.`n$listRaw" `
                               "contrib/fork/SETUP.md")
        }
        if ($null -ne $parsed) {
            $machines = @(foreach ($m in @($parsed)) { if ($null -ne $m) { $m } })
        }
    }
    $running = @($machines | Where-Object { $_.Running })
    $stopped = @($machines | Where-Object { -not $_.Running -and $_.Name })

    if ($running.Count -gt 0 -or ($machines.Count -gt 0 -and $stopped.Count -eq 0)) {
        throw $infoFailure
    }
    if ($stopped.Count -eq 0) {
        throw (New-Refusal ("No podman machine exists, so there is nothing to start.`n" +
                            "podman info said:`n$infoFailure") `
                           "contrib/fork/SETUP.md -- podman machine init")
    }

    $target = $stopped | Where-Object { $_.Default } | Select-Object -First 1
    if (-not $target) {
        $target = $stopped | Where-Object { $_.Name -eq 'podman-machine-default' } | Select-Object -First 1
    }
    if (-not $target) { $target = $stopped | Select-Object -First 1 }

    $startOut = (& podman machine start $target.Name 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal ("podman machine start $($target.Name) failed (exit $LASTEXITCODE).`n$startOut") `
                           "contrib/fork/SETUP.md")
    }

    $last = $infoFailure
    for ($i = 0; $i -lt 5; $i++) {
        if ($i -gt 0) { Start-Sleep -Seconds 2 }
        try {
            Assert-PodmanResponds
            Add-Action 'started' "auto-started podman machine $($target.Name)"
            return
        } catch {
            $last = $_.Exception.Message
        }
    }
    throw (New-Refusal ("Started podman machine $($target.Name), but podman info is still failing.`n$last") `
                       "podman machine list")
}

function Assert-PodmanResponds {
    $detail = (& podman info 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) { return }
    throw (New-Refusal "podman info failed (exit $LASTEXITCODE). podman said:`n$detail" `
                       "podman machine list -- and if it is running: podman system connection list")
}

function Get-PodmanClientVersion {
    $text = (& podman --version 2>&1 | Out-String).Trim()
    if ($text -match '(\d+)\.(\d+)\.(\d+)') {
        return [pscustomobject]@{
            Text = $text
            Version = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
        }
    }
    return [pscustomobject]@{ Text = $text; Version = $null }
}

# `podman machine inspect` records the memory the machine was created with, in MiB
# (2048 for this workstation). A value that can only be bytes is converted.
# On a WSL machine that recorded number is not the RAM the VM gets: WSL uses
# %USERPROFILE%\.wslconfig, or 50% of the host when that file is absent, and
# `podman machine set --memory` does not apply. HostMemBytes is the live value,
# `podman info` .Host.MemTotal, in bytes.
function Get-PodmanHostMemoryBytes {
    $raw = (& podman info --format '{{.Host.MemTotal}}' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $raw -notmatch '^\d+$') {
        throw (New-Refusal "could not read WSL memory from podman info .Host.MemTotal.`n$raw" `
                           "podman info --format '{{.Host.MemTotal}}'")
    }
    return [int64]$raw
}

function Get-PodmanMachineResources {
    $raw = (& podman machine inspect 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "podman machine inspect failed.`n$raw" "contrib/fork/SETUP.md")
    }
    $start = $raw.IndexOf('[')
    if ($start -lt 0) { $start = $raw.IndexOf('{') }
    if ($start -lt 0) {
        throw (New-Refusal "podman machine inspect did not return JSON." "contrib/fork/SETUP.md")
    }
    $machines = @($raw.Substring($start) | ConvertFrom-Json)
    $target = $machines | Where-Object { $_.State -eq 'running' } | Select-Object -First 1
    if (-not $target) {
        $target = $machines | Where-Object { $_.Name -eq 'podman-machine-default' } | Select-Object -First 1
    }
    if (-not $target) { $target = $machines | Select-Object -First 1 }
    $mem = [int64]$target.Resources.Memory
    if ($mem -gt 1000000) { $mem = [int64]($mem / 1MB) }
    return [pscustomobject]@{
        Name = [string]$target.Name
        State = [string]$target.State
        CPUs = [int]$target.Resources.CPUs
        MemoryMiB = [int]$mem
        HostMemBytes = (Get-PodmanHostMemoryBytes)
        Rootful = [bool]$target.Rootful
    }
}

# The socket path inside the machine. `podman info` from the Windows client
# reports the remote host, so this is the Unix socket containers can mount.
function Get-PodmanSocketPath {
    $raw = (& podman info --format '{{.Host.RemoteSocket.Path}}' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw (New-Refusal "could not read the Podman socket path. Raw value: '$raw'" `
                           "podman info --format '{{.Host.RemoteSocket.Path}}'")
    }
    $path = $raw
    # Rootful WSL reports unix:///run/podman/podman.sock. Only that scheme is a path.
    if ($path -match '^(?i)unix://(.*)$') {
        $path = $Matches[1]
    } elseif ($path -match '^[a-zA-Z][a-zA-Z0-9+.\-]*://') {
        throw (New-Refusal "Podman reported socket path '$raw', which is not a path inside the machine." `
                           "podman info --format '{{.Host.RemoteSocket.Path}}'  (expected an absolute Unix path, optionally prefixed with unix://)")
    }
    if ([string]::IsNullOrWhiteSpace($path) -or -not $path.StartsWith('/')) {
        throw (New-Refusal "Podman reported socket path '$raw', which is not a path inside the machine." `
                           "podman info --format '{{.Host.RemoteSocket.Path}}'  (expected /run/.../podman.sock)")
    }
    return $path
}

# podman compose delegates to an external provider. !reset / !override need
# Docker Compose v2.24 or newer. The 2025 rebrand of that line is v5, which
# is newer than 2.24 and is accepted. A provider whose text contains
# "podman-compose version" is not. The external-provider banner mentions
# podman-compose(1) and is not that provider.
#
# The banner is written to stderr. PODMAN_COMPOSE_WARNING_LOGS=false
# suppresses it (podman-compose(1)). Version text is stdout only, and any
# line that still starts with ">>>>" is dropped before the match.
# Get-ComposeCommand returns an argument array. Invoke the first element
# and splat the rest. `& @prefix` is a single command name ("podman compose")
# and is not a command on PATH.
function Get-ComposeCommand {
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        throw (New-Refusal "podman is not on PATH." "contrib/fork/SETUP.md")
    }
    return @('podman', 'compose')
}

function Remove-ComposeBannerLines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $kept = foreach ($line in ($Text -split '\r?\n')) {
        if ($line.StartsWith('>>>>')) { continue }
        $line
    }
    if ($null -eq $kept) { return '' }
    return (@($kept) -join "`n").Trim()
}

function Restore-ComposeWarningLogs($Previous) {
    if ($null -eq $Previous) {
        Remove-Item Env:\PODMAN_COMPOSE_WARNING_LOGS -ErrorAction SilentlyContinue
    } else {
        $env:PODMAN_COMPOSE_WARNING_LOGS = [string]$Previous
    }
}

function Get-ComposeVersionText {
    $prefix = Get-ComposeCommand
    $previous = $env:PODMAN_COMPOSE_WARNING_LOGS
    $env:PODMAN_COMPOSE_WARNING_LOGS = 'false'
    try {
        $raw = & $prefix[0] @($prefix[1..($prefix.Count - 1)]) version 2>$null
        $code = $LASTEXITCODE
        $out = Remove-ComposeBannerLines (($raw | Out-String).Trim())
        return [pscustomobject]@{ Text = $out; Code = $code }
    } finally {
        Restore-ComposeWarningLogs $previous
    }
}

function Test-ComposeVersionSupported([string]$Text) {
    $body = Remove-ComposeBannerLines $Text
    if ($body -match 'podman-compose version') { return $false }
    if ($body -notmatch 'Docker Compose version v?(\d+)\.(\d+)\.(\d+)') { return $false }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -eq 2) { return $minor -ge 24 }
    return $major -ge 3
}

function Get-StackModePath {
    return Join-Path (Split-Path $PSScriptRoot -Parent) '.local\stack-mode.psd1'
}

function Get-StackMode {
    $path = Get-StackModePath
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ Gpu = $false; DataVolume = $false }
    }
    $data = Import-PowerShellDataFile -Path $path
    return @{
        Gpu = [bool]$data.Gpu
        DataVolume = [bool]$data.DataVolume
    }
}

function Save-StackMode([bool]$Gpu, [bool]$DataVolume) {
    $path = Get-StackModePath
    $dir = Split-Path $path -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $gpuText = if ($Gpu) { '$true' } else { '$false' }
    $dataText = if ($DataVolume) { '$true' } else { '$false' }
    $body = "@{`r`n    Gpu = $gpuText`r`n    DataVolume = $dataText`r`n}`r`n"
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $body, $utf8)
}

function Get-StackComposeFiles([bool]$Gpu, [bool]$DataVolume) {
    $files = @(
        'docker-compose.example.yml',
        'contrib/podman/compose.podman.yml'
    )
    if ($Gpu) { $files += 'contrib/podman/compose.gpu.yml' }
    if ($DataVolume) { $files += 'contrib/podman/compose.datavolume.yml' }
    return $files
}

function Assert-EnvFile {
    $path = Join-Path (Get-RepoRoot) '.env'
    if (-not (Test-Path -LiteralPath $path)) {
        throw (New-Refusal ".env does not exist, so compose has no FIRST_RUN_PASSWORD." `
                           ".\contrib\maku.ps1 stack install")
    }
    return $path
}

# Runs `podman compose` from the repo root. Relative -f paths stay forward-slash
# so the Windows client does not split them on the drive-letter colon.
# NOJOIN_IMAGE_TAG comes from images.psd1 and overrides anything in .env.
# PODMAN_COMPOSE_WARNING_LOGS=false hides the external-provider banner for
# this call. The previous value is restored afterwards.
function Invoke-StackCompose {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [bool]$Gpu = $false,
        [bool]$DataVolume = $false,
        [switch]$RequireEnvFile
    )
    $root = Get-RepoRoot
    $env:NOJOIN_IMAGE_TAG = Get-NojoinTag
    $env:PODMAN_SOCKET = Get-PodmanSocketPath

    $argv = @('compose')
    foreach ($f in (Get-StackComposeFiles $Gpu $DataVolume)) {
        $argv += @('-f', $f)
    }
    $envFile = Join-Path $root '.env'
    if ($RequireEnvFile -or (Test-Path -LiteralPath $envFile)) {
        if ($RequireEnvFile) { Assert-EnvFile | Out-Null }
        $argv += @('--env-file', '.env')
    }
    $argv += $Arguments

    $previousComposeLogs = $env:PODMAN_COMPOSE_WARNING_LOGS
    Push-Location $root
    try {
        $env:PODMAN_COMPOSE_WARNING_LOGS = 'false'
        & podman @argv
        $code = $LASTEXITCODE
        return $code
    } finally {
        Pop-Location
        Restore-ComposeWarningLogs $previousComposeLogs
    }
}

function Test-PortInUse([int]$Port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try     { $client.Connect('127.0.0.1', $Port); return $true }
    catch   { return $false }
    finally { $client.Dispose() }
}

function Wait-ForPortFree([int]$Port, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-PortInUse $Port)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return -not (Test-PortInUse $Port)
}

function Get-PortHolder([int]$Port) {
    $rows = & podman ps --all --external --format '{{.Names}} {{.Ports}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($row in @($rows)) {
        if ($row -match ":${Port}->") { return $row.Trim() }
    }
    return $null
}

# Compose labels the volume with the logical name. The project prefix is
# `nojoin` (the compose `name:`), used when the label is absent. A bare volume
# name is not inspected: it can belong to another project.
function Get-ProjectVolume([string]$Logical) {
    $name = (& podman volume ls --filter "label=com.docker.compose.project=nojoin" --filter "label=com.docker.compose.volume=$Logical" --format '{{.Name}}' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $name) {
        return @($name -split "`r?`n" | Where-Object { $_ })[0].Trim()
    }
    $candidate = "nojoin_$Logical"
    & podman volume inspect $candidate 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $candidate }
    return $null
}

# Absent switches leave the saved mode. A present switch sets that mode,
# including an explicit false. Callers must splat only the switches the user
# actually passed, so ContainsKey can tell false from absent.
function Resolve-StackMode {
    param(
        [switch]$Gpu,
        [switch]$DataVolume
    )
    $mode = Get-StackMode
    if ($PSBoundParameters.ContainsKey('Gpu')) { $mode.Gpu = [bool]$Gpu }
    if ($PSBoundParameters.ContainsKey('DataVolume')) { $mode.DataVolume = [bool]$DataVolume }
    return $mode
}

# Turning DataVolume on hides whatever is already in ./data. Refuse that
# switch while the directory has anything in it, unless the caller passed
# -IgnoreExistingData. Re-running a mode that is already on is not a switch.
function Assert-DataVolumeSwitch {
    param(
        [Parameter(Mandatory)][bool]$WasEnabled,
        [Parameter(Mandatory)][bool]$Enable,
        [switch]$IgnoreExistingData
    )
    if (-not $Enable -or $WasEnabled) { return }
    $data = Join-Path (Get-RepoRoot) 'data'
    if (-not (Test-Path -LiteralPath $data)) { return }
    $any = Get-ChildItem -LiteralPath $data -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $any) { return }
    if ($IgnoreExistingData) { return }
    throw (New-Refusal "Refusing to switch to the named volume nojoin_data: ./data exists and is not empty. Recordings in ./data would no longer be visible." `
                       "copy them first, or re-run with -IgnoreExistingData")
}

# Same files and env as Invoke-StackCompose. The JSON stays in memory.
# Nothing here writes the document or an env value to the host.
function Get-StackComposeConfig {
    param(
        [bool]$Gpu = $false,
        [bool]$DataVolume = $false
    )
    $root = Get-RepoRoot
    $env:NOJOIN_IMAGE_TAG = Get-NojoinTag
    $env:PODMAN_SOCKET = Get-PodmanSocketPath

    $argv = @('compose')
    foreach ($f in (Get-StackComposeFiles $Gpu $DataVolume)) {
        $argv += @('-f', $f)
    }
    $envFile = Join-Path $root '.env'
    if (Test-Path -LiteralPath $envFile) {
        $argv += @('--env-file', '.env')
    }
    $argv += @('config', '--format', 'json')

    $stamp = [guid]::NewGuid().ToString('n')
    $stdout = Join-Path ([System.IO.Path]::GetTempPath()) "maku-compose-$stamp.json"
    $stderr = Join-Path ([System.IO.Path]::GetTempPath()) "maku-compose-$stamp.txt"
    Push-Location $root
    try {
        & podman @argv 1> $stdout 2> $stderr
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            throw (New-Refusal "podman compose config failed (exit $code)." "podman compose version")
        }
        $text = [System.IO.File]::ReadAllText($stdout).Trim()
        $start = $text.IndexOf('{')
        if ($start -lt 0) {
            throw (New-Refusal "podman compose config did not return JSON." "podman compose version")
        }
        if ($start -gt 0) { $text = $text.Substring($start) }
        try {
            return ($text | ConvertFrom-Json)
        } catch {
            throw (New-Refusal "podman compose config did not return JSON." "podman compose version")
        }
    } finally {
        Pop-Location
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-StackServices, Get-HealthcheckedContainers, Assert-ServiceName, `
                              Test-PodmanReady, Get-PodmanClientVersion, Get-PodmanMachineResources, `
                              Get-PodmanSocketPath, Get-ComposeCommand, Get-ComposeVersionText, `
                              Test-ComposeVersionSupported, Get-StackMode, Save-StackMode, `
                              Resolve-StackMode, Assert-DataVolumeSwitch, `
                              Get-StackComposeFiles, Assert-EnvFile, Invoke-StackCompose, `
                              Get-StackComposeConfig, Test-PortInUse, Wait-ForPortFree, `
                              Get-PortHolder, Get-ProjectVolume

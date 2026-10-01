#: check Podman, compose, secrets, ports, the data directory, and rendered config

<#
.SYNOPSIS
    Report whether this machine can run the stack. Does not change machine memory or CPU.

.DESCRIPTION
    A stopped Podman machine is started. CPU count is read from machine inspect.
    The memory check uses podman info .Host.MemTotal (bytes). The MiB value
    recorded by machine inspect is printed as information and is not the limit.
    .env is checked for the presence of FIRST_RUN_PASSWORD and DATA_ENCRYPTION_KEY.
    Values are never printed. Example placeholders produce a warning.
    The rendered compose config for the active mode is checked without printing
    the JSON or any env value. SELinux state is information. A true value warns
    that bind mounts from /mnt/c may need label=disable. It is not a failure.
    ASR thread count is informational. NOJOIN_ASR_THREADS is read as a number
    from the process environment, or from .env when the process has none.
    No other .env value is printed. A non-integer, a value below 1, or a value
    above the CPU count visible to the machine is a warning, not a failure.

.PARAMETER Gpu
    Render this GPU mode instead of the saved one. -Gpu:$false forces CPU.
    Absent uses the saved mode. This command does not save the mode.

.PARAMETER DataVolume
    Render this data mode instead of the saved one. -DataVolume:$false forces
    the ./data bind. Absent uses the saved mode.

.EXAMPLE
    .\contrib\maku.ps1 stack doctor
#>
param(
    [switch]$Gpu,
    [switch]$DataVolume
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Use-NativeExitCodes

$failed = 0
function Add-Failure { $script:failed++ }

$modeArgs = @{}
if ($PSBoundParameters.ContainsKey('Gpu')) { $modeArgs.Gpu = [bool]$Gpu }
if ($PSBoundParameters.ContainsKey('DataVolume')) { $modeArgs.DataVolume = [bool]$DataVolume }
$mode = Resolve-StackMode @modeArgs

$client = Get-PodmanClientVersion
if (-not $client.Version -or $client.Version.Major -ne 5) {
    Write-Fail 'podman' "$($client.Text) (need 5.x)"
    Add-Failure
} else {
    Write-Pass 'podman' $client.Text
}

Test-PodmanReady
$machine = Get-PodmanMachineResources
if ($machine.State -eq 'running') {
    Write-Pass 'machine' "$($machine.Name) running ($($machine.CPUs) CPUs)"
} else {
    Write-Fail 'machine' "$($machine.Name) is $($machine.State)"
    Add-Failure
}

# 8 GiB. The recorded inspect value is informational: WSL, not `podman machine set`, decides RAM.
$recorded = "machine inspect records $($machine.MemoryMiB) MiB"
if ($machine.HostMemBytes -lt 8GB) {
    Write-Fail 'memory' "$($machine.HostMemBytes) bytes (need at least 8 GiB). CPUs are $($machine.CPUs). $recorded."
    Write-Host '  fix: create %USERPROFILE%\.wslconfig with [wsl2] and memory=16GB, then wsl --shutdown' -ForegroundColor Red
    Add-Failure
} else {
    Write-Pass 'memory' "$($machine.HostMemBytes) bytes. $recorded."
}

$compose = Get-ComposeVersionText
$composeOk = ($compose.Code -eq 0 -and (Test-ComposeVersionSupported $compose.Text))
if (-not $composeOk) {
    Write-Fail 'compose' $(if ($compose.Text) { $compose.Text } else { "podman compose version failed (exit $($compose.Code))" })
    Write-Host "  fix: install Docker Compose v2.24 or newer (Podman Desktop bundles it). podman-compose cannot be used." -ForegroundColor Red
    Add-Failure
} else {
    Write-Pass 'compose' $compose.Text
}

try {
    $socket = Get-PodmanSocketPath
    Write-Pass 'socket' $socket
} catch {
    $socket = $null
    Write-Fail 'socket' $_.Exception.Message.Split([Environment]::NewLine)[0]
    Add-Failure
}

# false means rootful. Informational only: a rootful machine is a valid way to run the stack.
$rootless = (& podman info --format '{{.Host.Security.Rootless}}' 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $rootless -notin @('true', 'false')) {
    Write-Host "machine privilege: could not read Host.Security.Rootless (raw: '$rootless')"
} elseif ($rootless -eq 'false') {
    Write-Host 'machine privilege: rootful (Host.Security.Rootless=false)'
} else {
    Write-Host 'machine privilege: rootless (Host.Security.Rootless=true)'
}

$selinux = (& podman info --format '{{.Host.Security.SELinuxEnabled}}' 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $selinux) {
    Write-Warn 'selinux' 'could not read Host.Security.SELinuxEnabled'
} else {
    Write-Host "SELinux: $selinux"
    if ($selinux -eq 'true') {
        Write-Warn 'selinux' 'SELinux is enabled. Bind mounts from /mnt/c may need label=disable.'
    }
}

$cpuRaw = (& podman info --format '{{.Host.CPUs}}' 2>$null | Out-String).Trim()
$cpuLine = @($cpuRaw -split "`r?`n" | Where-Object { $_ -match '^\d+$' } | Select-Object -Last 1)
$cpuCount = 0
$cpuKnown = ($LASTEXITCODE -eq 0) -and ($cpuLine.Count -eq 1) -and [int]::TryParse([string]$cpuLine, [ref]$cpuCount)
$cpuText = if ($cpuKnown) { "$cpuCount" } else { 'unknown' }

# Process environment first. .env only when that variable is absent there.
# The value is accepted only as an integer, so a non-numeric string is not printed.
$threadRaw = [Environment]::GetEnvironmentVariable('NOJOIN_ASR_THREADS', 'Process')
if ([string]::IsNullOrWhiteSpace($threadRaw)) {
    $threadRaw = $null
    $dotenvPath = Join-Path (Get-RepoRoot) '.env'
    if (Test-Path -LiteralPath $dotenvPath) {
        $threadMap = Read-DotEnv $dotenvPath
        if ($threadMap.ContainsKey('NOJOIN_ASR_THREADS') -and -not [string]::IsNullOrWhiteSpace([string]$threadMap['NOJOIN_ASR_THREADS'])) {
            $threadRaw = ([string]$threadMap['NOJOIN_ASR_THREADS']).Trim()
        }
    }
} else {
    $threadRaw = $threadRaw.Trim()
}

$threadNumber = 0
$threadIsInt = $false
if ($null -eq $threadRaw) {
    $threadNumber = 8
    $threadIsInt = $true
    Write-Host "ASR threads: default 8 (CPUs visible to the machine: $cpuText)"
} else {
    $threadIsInt = [int]::TryParse(
        $threadRaw,
        [System.Globalization.NumberStyles]::Integer,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$threadNumber
    )
    if ($threadIsInt) {
        Write-Host "ASR threads: $threadNumber (CPUs visible to the machine: $cpuText)"
    } else {
        Write-Host "ASR threads: not an integer (CPUs visible to the machine: $cpuText)"
        Write-Warn 'threads' 'NOJOIN_ASR_THREADS is not an integer'
    }
}
if ($threadIsInt -and $threadNumber -lt 1) {
    Write-Warn 'threads' "$threadNumber is less than 1"
}
if ($threadIsInt -and $cpuKnown -and $threadNumber -gt $cpuCount) {
    Write-Warn 'threads' "$threadNumber is greater than $cpuCount CPUs visible to the machine"
}

$envPath = Join-Path (Get-RepoRoot) '.env'
if (-not (Test-Path -LiteralPath $envPath)) {
    Write-Fail 'env' '.env is missing'
    Write-Host "  fix: .\contrib\maku.ps1 stack install" -ForegroundColor Red
    Add-Failure
} else {
    $map = Read-DotEnv $envPath
    foreach ($key in @('FIRST_RUN_PASSWORD', 'DATA_ENCRYPTION_KEY')) {
        if (-not $map.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$map[$key])) {
            Write-Fail 'env' "$key is missing or empty"
            Add-Failure
        } else {
            Write-Pass 'env' "$key is set"
        }
    }
    $placeholders = @{
        FIRST_RUN_PASSWORD  = @('change_this_before_first_start')
        DATA_ENCRYPTION_KEY = @('change_this_to_a_long_random_secret')
        REDIS_PASSWORD      = @('change_this_before_remote_access', 'change_to_secure_string')
        POSTGRES_PASSWORD   = @('postgres')
    }
    foreach ($key in @($placeholders.Keys)) {
        $value = [string]$map[$key]
        if ($map.ContainsKey($key) -and $value -in $placeholders[$key]) {
            Write-Warn 'env' "$key is still the example placeholder"
        }
    }
}

foreach ($port in @(14141, 14443)) {
    if (-not (Test-PortInUse $port)) {
        Write-Pass "port $port" 'free'
        continue
    }
    $holder = Get-PortHolder $port
    if ($holder -match 'nojoin-nginx') {
        Write-Pass "port $port" 'already published by nojoin-nginx'
    } else {
        $who = if ($holder) { $holder } else { 'something outside podman is listening' }
        Write-Fail "port $port" $who
        Add-Failure
    }
}

$store = if ($mode.DataVolume) { 'named volume nojoin_data' } else { 'bind ./data' }
Write-Host "data store: $store"

$data = Join-Path (Get-RepoRoot) 'data'
if ($mode.DataVolume) {
    Write-Pass 'data' 'named volume nojoin_data will be used'
} else {
    try {
        New-Item -ItemType Directory -Force -Path $data | Out-Null
        $probe = Join-Path $data '.maku-write-probe'
        [System.IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force
        Write-Pass 'data' './data is writable from this shell (stack verify checks the container)'
    } catch {
        Write-Fail 'data' './data is not writable from this shell'
        Write-Host "  fix: .\contrib\maku.ps1 stack install -DataVolume" -ForegroundColor Red
        Add-Failure
    }
}

function ConvertTo-ComposeVolume($Volume) {
    if ($Volume -is [string]) {
        $text = [string]$Volume
        if ($text -match '^(?<source>.*):(?<target>/[^:]+)(?::(?<mode>[^:]+))?$') {
            $flag = [string]$Matches['mode']
            return @{
                Type = 'bind'
                Source = [string]$Matches['source']
                Target = [string]$Matches['target']
                ReadOnly = (@($flag -split ',') -contains 'ro')
            }
        }
        return @{ Type = 'bind'; Source = $text; Target = ''; ReadOnly = $false }
    }
    $names = @($Volume.PSObject.Properties.Name)
    $ro = $false
    if ($names -contains 'read_only') {
        $flag = $Volume.read_only
        $ro = ($flag -is [bool] -and $flag) -or ([string]$flag -eq 'true')
    }
    return @{
        Type = [string]$Volume.type
        Source = [string]$Volume.source
        Target = [string]$Volume.target
        ReadOnly = $ro
    }
}

function Get-VolumeList($Value) {
    $list = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Value) { return $list }
    if ($Value -is [string]) {
        $list.Add((ConvertTo-ComposeVolume $Value))
        return $list
    }
    foreach ($item in @($Value)) {
        $list.Add((ConvertTo-ComposeVolume $item))
    }
    return $list
}

function Add-ConfigFailure([string]$Message) {
    $safe = $Message
    if ($safe -match '\{') { $safe = 'podman compose config could not be read.' }
    $lines = @($safe -split "`r?`n" | Where-Object { $_ -ne '' })
    Write-Fail 'config' $lines[0]
    for ($i = 1; $i -lt $lines.Count; $i++) {
        Write-Host $lines[$i] -ForegroundColor Red
    }
    Add-Failure
}

if (-not $composeOk) {
    Add-ConfigFailure 'compose is too old to render, so the config was not checked.'
} elseif (-not $socket) {
    Add-ConfigFailure 'Podman socket is unknown, so the config was not rendered.'
} else {
    $failedBeforeConfig = $script:failed
    $configFailed = $false
    try {
        $config = Get-StackComposeConfig -Gpu:([bool]$mode.Gpu) -DataVolume:([bool]$mode.DataVolume)
    } catch {
        Add-ConfigFailure $_.Exception.Message
        $config = $null
        $configFailed = $true
    }
    if (-not $configFailed) {
        $services = $config.services
        if (-not $services) {
            Add-ConfigFailure 'compose config has no services'
        } else {
            foreach ($prop in @($services.PSObject.Properties)) {
                $driver = [string]$prop.Value.logging.driver
                if ($driver -eq 'json-file') {
                    Add-ConfigFailure "$($prop.Name) logging.driver is json-file"
                }
            }

            $gpuSvc = $services.PSObject.Properties['worker-gpu']
            if (-not $gpuSvc) {
                Add-ConfigFailure 'worker-gpu is missing from the rendered config'
            } elseif (-not $mode.Gpu -and $null -ne $gpuSvc.Value.deploy.resources) {
                Add-ConfigFailure 'worker-gpu has deploy.resources while GPU mode is off'
            }

            $proxySvc = $services.PSObject.Properties['socket-proxy']
            if (-not $proxySvc) {
                Add-ConfigFailure 'socket-proxy is missing from the rendered config'
            } else {
                $proxyVolumes = @(Get-VolumeList $proxySvc.Value.volumes)
                if ($proxyVolumes.Count -ne 1) {
                    Add-ConfigFailure "socket-proxy has $($proxyVolumes.Count) volumes"
                } else {
                    $source = [string]$proxyVolumes[0].Source
                    if ($source -ne $socket) {
                        Add-ConfigFailure 'socket-proxy volume source does not equal the Podman socket path'
                    }
                    if ($source.StartsWith('/mnt/') -or $source -eq '/mnt') {
                        Add-ConfigFailure 'socket-proxy volume source is under /mnt/'
                    }
                }
            }

            $nginxSvc = $services.PSObject.Properties['nginx']
            if (-not $nginxSvc) {
                Add-ConfigFailure 'nginx is missing from the rendered config'
            } else {
                $nginxVolumes = @(Get-VolumeList $nginxSvc.Value.volumes)
                $upstream = @($nginxVolumes | Where-Object { $_.Target -eq '/etc/nginx/nginx.conf.upstream' -and $_.ReadOnly })
                if ($upstream.Count -eq 0) {
                    Add-ConfigFailure 'nginx is missing a read-only /etc/nginx/nginx.conf.upstream mount'
                }
                $live = @($nginxVolumes | Where-Object {
                    $_.Target -eq '/etc/nginx/nginx.conf' -and ($_.Type -eq 'bind' -or [string]::IsNullOrEmpty($_.Type))
                })
                if ($live.Count -gt 0) {
                    Add-ConfigFailure 'nginx bind-mounts /etc/nginx/nginx.conf'
                }
            }

            $ioSvc = $services.PSObject.Properties['worker-io']
            if (-not $ioSvc) {
                Add-ConfigFailure 'worker-io is missing from the rendered config'
            } else {
                $ioNames = @($ioSvc.Value.PSObject.Properties.Name)
                if ($ioNames -contains 'build' -and $null -ne $ioSvc.Value.build) {
                    Add-ConfigFailure 'worker-io still has a build'
                }
            }
        }
        if ($script:failed -eq $failedBeforeConfig) {
            $gpuNote = if ($mode.Gpu) { ', gpu' } else { '' }
            Write-Pass 'config' "rendered ($store$gpuNote)"
        }
    }
}

Write-Host ""
if ($failed -gt 0) {
    Write-Fail 'doctor' "$failed check(s) failed"
    exit 1
}
Write-Pass 'doctor' 'ready'
exit 0

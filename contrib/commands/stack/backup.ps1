#: pg_dump postgres, copy the data store, and optionally export model_cache

<#
.SYNOPSIS
    Consistent pg_dump of the running database, plus the live data store.

.DESCRIPTION
    postgres_data is not exported with `podman volume export` (that snapshot is
    not consistent). redis_data is skipped: Redis is a broker and a cache.
    ./data is copied, unless the saved mode uses the named volume, in which
    case nojoin_data is exported. model_cache is exported when it exists.
    POSTGRES_USER and POSTGRES_DB are read from .env (defaults postgres and
    nojoin) and are never printed.

.PARAMETER Output
    Directory to write. Default: contrib/.local/backups/<timestamp>.

.EXAMPLE
    .\contrib\maku.ps1 stack backup
#>
param([string]$Output)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Use-NativeExitCodes

function Hide-PgText([string]$Text, [string]$User, [string]$Database) {
    if (-not $Text) { return '' }
    $safe = $Text
    if ($User) { $safe = $safe.Replace($User, 'POSTGRES_USER') }
    if ($Database) { $safe = $safe.Replace($Database, 'POSTGRES_DB') }
    return $safe
}

# Stream pg_dump -Fc to a file. stdout is copied as bytes so PowerShell does
# not re-encode the archive. The user and database are not written to the host.
function Export-PostgresDump([string]$Destination, [string]$User, [string]$Database) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command podman -ErrorAction Stop).Source
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($arg in @('exec', 'nojoin-db', 'pg_dump', '-U', $User, '-d', $Database, '-Fc')) {
        [void]$psi.ArgumentList.Add($arg)
    }
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    if (-not $proc.Start()) {
        throw (New-Refusal "could not start pg_dump." "podman exec nojoin-db pg_isready")
    }
    $errTask = $proc.StandardError.ReadToEndAsync()
    $out = [System.IO.File]::Create($Destination)
    try {
        $proc.StandardOutput.BaseStream.CopyTo($out)
    } finally {
        $out.Dispose()
    }
    $proc.WaitForExit()
    $errText = Hide-PgText ([string]$errTask.GetAwaiter().GetResult()) $User $Database
    if ($proc.ExitCode -ne 0) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw (New-Refusal "pg_dump failed (exit $($proc.ExitCode)).`n$($errText.Trim())" `
                           "podman exec nojoin-db pg_isready")
    }
    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -lt 5) {
        throw (New-Refusal "pg_dump wrote an empty file." "podman exec nojoin-db pg_isready")
    }
    $fs = [System.IO.File]::OpenRead($Destination)
    try {
        $buf = [byte[]]::new(5)
        $read = $fs.Read($buf, 0, 5)
    } finally {
        $fs.Dispose()
    }
    if ($read -ne 5 -or [System.Text.Encoding]::ASCII.GetString($buf) -ne 'PGDMP') {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw (New-Refusal "pg_dump output is not a custom-format archive." "podman exec nojoin-db pg_isready")
    }
}

function Export-ProjectVolume([string]$Logical, [string]$OutputDir, [bool]$Required) {
    $volume = Get-ProjectVolume $Logical
    if (-not $volume) {
        if ($Required) {
            throw (New-Refusal "Missing volume '$Logical'." `
                               "start the stack once so compose creates it, then re-run stack backup")
        }
        Write-Warn 'volume' "$Logical is absent; skipped"
        return $null
    }
    $dest = Join-Path $OutputDir "$Logical.tar"
    & podman volume export $volume --output $dest
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "podman volume export failed for '$Logical'." `
                           "podman volume ls --filter label=com.docker.compose.project=nojoin")
    }
    Write-Pass 'volume' "$Logical ($volume)"
    return "$Logical -> $volume"
}

Test-PodmanReady
$root = Get-RepoRoot
if (-not $Output) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Output = Join-Path $root "contrib\.local\backups\$stamp"
}
New-Item -ItemType Directory -Force -Path $Output | Out-Null

$envPath = Join-Path $root '.env'
$map = if (Test-Path -LiteralPath $envPath) { Read-DotEnv $envPath } else { @{} }
$pgUser = if ($map.ContainsKey('POSTGRES_USER') -and -not [string]::IsNullOrWhiteSpace([string]$map['POSTGRES_USER'])) {
    [string]$map['POSTGRES_USER']
} else { 'postgres' }
$pgDb = if ($map.ContainsKey('POSTGRES_DB') -and -not [string]::IsNullOrWhiteSpace([string]$map['POSTGRES_DB'])) {
    [string]$map['POSTGRES_DB']
} else { 'nojoin' }

$dump = Join-Path $Output 'postgres.dump'
Export-PostgresDump $dump $pgUser $pgDb
Write-Pass 'postgres' 'pg_dump custom format'
$exported = @('postgres.dump')

Write-Host 'redis_data skipped (broker and cache only).'

$mode = Get-StackMode
if ($mode.DataVolume) {
    if (Test-Path -LiteralPath (Join-Path $root 'data')) {
        Write-Warn 'data' './data was not copied; the live store is the named volume nojoin_data'
    }
    $item = Export-ProjectVolume 'nojoin_data' $Output $true
    if ($item) { $exported += $item }
} else {
    $data = Join-Path $root 'data'
    $dataDest = Join-Path $Output 'data'
    if (Test-Path -LiteralPath $data) {
        Copy-Item -LiteralPath $data -Destination $dataDest -Recurse -Force
        Write-Pass 'data' $dataDest
        $exported += './data'
    } else {
        Write-Warn 'data' './data does not exist; nothing copied'
    }
}

$cache = Export-ProjectVolume 'model_cache' $Output $false
if ($cache) { $exported += $cache }

$manifest = @(
    "tag=$(Get-NojoinTag)"
    "at=$((Get-Date).ToString('o'))"
    'postgres=pg_dump'
    'redis=skipped'
    ($exported | ForEach-Object { "item=$_" })
) -join [Environment]::NewLine
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $Output 'MANIFEST.txt'), $manifest + [Environment]::NewLine, $utf8)

Add-Action 'backed up' $Output
Write-Pass 'backup' $Output
exit 0

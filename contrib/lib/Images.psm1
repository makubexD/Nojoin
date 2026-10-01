# The image pin in contrib/images.psd1, and the compose override that repeats it
# because YAML cannot import a PowerShell data file.

$script:PinFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'images.psd1'
$script:TagPattern = '\$\{NOJOIN_IMAGE_TAG(?::-([^}]*))?\}'

function Get-ImageData {
    if (-not (Test-Path -LiteralPath $script:PinFile)) {
        throw "Missing $($script:PinFile)"
    }
    return Import-PowerShellDataFile -Path $script:PinFile
}

function Get-NojoinTag {
    $tag = [string](Get-ImageData).NojoinTag
    if ($tag -notmatch '^\d+\.\d+\.\d+$') {
        throw "NojoinTag '$tag' is not an image tag like 2.5.1. Upstream git tags look like v2.5.1; the image tag drops the v."
    }
    return $tag
}

# v2.5.1 and 2.5.1 are the same pin. The stored form is the image tag.
function ConvertTo-ImageTag([string]$Tag) {
    $t = $Tag.Trim()
    if ($t -match '^v(\d+\.\d+\.\d+)$') { return $Matches[1] }
    if ($t -match '^\d+\.\d+\.\d+$') { return $t }
    throw "Expected a release like v2.5.1 or 2.5.1, got '$Tag'."
}

function Get-NojoinRepos {
    $data = Get-ImageData
    return @($data.Api, $data.Worker, $data.WorkerIo, $data.Frontend)
}

function Get-ThirdPartyImages {
    $data = Get-ImageData
    return @($data.Postgres, $data.Redis, $data.Nginx, $data.SocketProxy)
}

# How many times each fully-qualified reference must appear in compose.podman.yml.
# worker-io no longer names the worker image as a build context.
function Get-ExpectedImageCounts([string]$Tag) {
    $data = Get-ImageData
    $pin = '${NOJOIN_IMAGE_TAG:-' + $Tag + '}'
    return @(
        @{ Needle = "$($data.Postgres)"; Count = 1 }
        @{ Needle = "$($data.Redis)"; Count = 1 }
        @{ Needle = "$($data.Nginx)"; Count = 1 }
        @{ Needle = "$($data.SocketProxy)"; Count = 1 }
        @{ Needle = "$($data.Api):$pin"; Count = 1 }
        @{ Needle = "$($data.Worker):$pin"; Count = 2 }
        @{ Needle = "$($data.WorkerIo):$pin"; Count = 2 }
        @{ Needle = "$($data.Frontend):$pin"; Count = 1 }
    )
}

function Get-ImageMirrorState {
    $data = Get-ImageData
    $tag = [string]$data.NojoinTag
    $root = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $root) { throw "Not a git repository." }
    $root = $root.Trim()

    $rows = foreach ($rel in @($data.TagMirrors)) {
        $path = Join-Path $root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path)) {
            [pscustomobject]@{ File = $rel; Agrees = $false; Note = 'missing'; Detail = '' }
            continue
        }
        $body = [System.IO.File]::ReadAllText($path)
        $problems = @()
        foreach ($item in (Get-ExpectedImageCounts $tag)) {
            $found = ([regex]::Matches($body, [regex]::Escape($item.Needle))).Count
            if ($found -ne $item.Count) {
                $problems += "$($item.Needle) x$found (want $($item.Count))"
            }
        }
        if ($body -match 'ghcr\.io/valtora/nojoin-[^:\s]+:latest') {
            $problems += 'a nojoin image is still tagged :latest'
        }
        $defaults = @([regex]::Matches($body, $script:TagPattern) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $badDefault = @($defaults | Where-Object { $_ -ne $tag })
        if ($badDefault.Count -gt 0) {
            $problems += "tag default is $($badDefault -join ', ') (want $tag)"
        }
        $agrees = ($problems.Count -eq 0)
        [pscustomobject]@{
            File = $rel
            Agrees = $agrees
            Note = $(if ($agrees) { 'ok' } else { 'differs' })
            Detail = ($problems -join '; ')
        }
    }
    return [pscustomobject]@{ Tag = $tag; Files = @($rows) }
}

function Set-NojoinTag([string]$Tag) {
    $tag = ConvertTo-ImageTag $Tag
    $data = Get-ImageData
    $root = (& git rev-parse --show-toplevel).Trim()
    $touched = @()

    $files = @($script:PinFile) + @($data.TagMirrors | ForEach-Object { Join-Path $root ($_.Replace('/', '\')) })
    foreach ($path in $files) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $body = [System.IO.File]::ReadAllText($path)
        $next = $body
        if ($path -eq $script:PinFile) {
            $match = [regex]::Match($next, "(?m)^(\s*NojoinTag\s*=\s*')[^']*(')")
            if ($match.Success) {
                $next = $next.Substring(0, $match.Index) + $match.Groups[1].Value + $tag + $match.Groups[2].Value + $next.Substring($match.Index + $match.Length)
            }
        } else {
            $literal = '${NOJOIN_IMAGE_TAG:-' + $tag + '}'
            $found = [regex]::Matches($next, $script:TagPattern)
            if ($found.Count -gt 0) {
                $sb = New-Object System.Text.StringBuilder
                $last = 0
                foreach ($match in $found) {
                    [void]$sb.Append($next, $last, $match.Index - $last)
                    [void]$sb.Append($literal)
                    $last = $match.Index + $match.Length
                }
                [void]$sb.Append($next, $last, $next.Length - $last)
                $next = $sb.ToString()
            }
        }
        if ($next -ne $body) {
            $utf8 = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($path, $next, $utf8)
            $rel = $path
            if ($rel.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rel = $rel.Substring($root.Length).TrimStart('\', '/')
            }
            $touched += ($rel -replace '\\', '/')
        }
    }
    return @($touched)
}

# ghcr.io/owner/repo:tag -> owner/repo and tag. Anything else is not this registry.
function Get-GhcrNameAndTag([string]$Ref) {
    $ref = $Ref.Trim()
    if ($ref.StartsWith('docker://')) { $ref = $ref.Substring('docker://'.Length) }
    $slash = $ref.LastIndexOf('/')
    $colon = $ref.LastIndexOf(':')
    $tag = $null
    if ($colon -gt $slash) {
        $tag = $ref.Substring($colon + 1)
        $ref = $ref.Substring(0, $colon)
    }
    if (-not $ref.StartsWith('ghcr.io/') -or -not $tag) { return $null }
    $repo = $ref.Substring('ghcr.io/'.Length)
    if (-not $repo) { return $null }
    return @{ Repo = $repo; Tag = $tag }
}

# Anonymous GHCR. True when the manifest HEAD is HTTP 200.
# Not published: HTTP 404, or 401/403 on that HEAD after a token was issued.
# Anything else (timeout, 429, 5xx, token failure) throws. A transient registry
# error must not look like "not published". No podman.
function Test-ManifestExists([string]$Ref) {
    $parts = Get-GhcrNameAndTag $Ref
    if (-not $parts) { throw "Not a ghcr.io reference: $Ref" }
    $repo = $parts.Repo
    $tag = $parts.Tag
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $tokenUri = "https://ghcr.io/token?scope=repository:${repo}:pull"
        try {
            $tokenResponse = Invoke-RestMethod -Uri $tokenUri -TimeoutSec 20
        } catch {
            throw "GHCR token request failed for ${repo}: $($_.Exception.Message). This is not treated as 'not published'."
        }
        $access = [string]$tokenResponse.token
        if (-not $access) { $access = [string]$tokenResponse.access_token }
        if (-not $access) {
            throw "GHCR token response for ${repo} had no token. This is not treated as 'not published'."
        }
        $headers = @{
            Authorization = "Bearer $access"
            Accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
        }
        $manifestUri = "https://ghcr.io/v2/${repo}/manifests/${tag}"
        try {
            $response = Invoke-WebRequest -Uri $manifestUri -Method Head -Headers $headers -TimeoutSec 20 -SkipHttpErrorCheck
        } catch {
            throw "GHCR manifest check failed for ${Ref}: $($_.Exception.Message). This is not treated as 'not published'."
        }
        $code = [int]$response.StatusCode
        if ($code -eq 200) { return $true }
        if ($code -eq 404 -or $code -eq 401 -or $code -eq 403) { return $false }
        throw "GHCR manifest check for ${Ref} returned HTTP $code. This is not treated as 'not published'."
    } finally {
        $ProgressPreference = $progress
    }
}

# All four release images, not just the api. A half-published release is not a pin.
function Test-ImagesPublished([string]$Tag) {
    $tag = ConvertTo-ImageTag $Tag
    foreach ($repo in (Get-NojoinRepos)) {
        if (-not (Test-ManifestExists "${repo}:${tag}")) { return $false }
    }
    return $true
}

# Newest strict vX.Y.Z tag whose four images are already on GHCR.
# $null when every fetched tag is unpublished. A token failure, timeout, 429,
# or 5xx throws out of Test-ManifestExists and stops the walk, so an older
# release cannot be pinned because a newer check blipped. The caller compares.
function Get-LatestPublishedTag {
    $lines = & git tag -l 'v*' --sort=-v:refname
    if ($LASTEXITCODE -ne 0) { throw "could not list upstream tags" }
    foreach ($line in @($lines)) {
        $name = ([string]$line).Trim()
        if ($name -notmatch '^v(\d+\.\d+\.\d+)$') { continue }
        $tag = $Matches[1]
        if (Test-ImagesPublished $tag) { return $tag }
    }
    return $null
}

Export-ModuleMember -Function Get-ImageData, Get-NojoinTag, ConvertTo-ImageTag, `
                              Get-NojoinRepos, Get-ThirdPartyImages, Get-ImageMirrorState, `
                              Set-NojoinTag, Test-ManifestExists, Test-ImagesPublished, `
                              Get-LatestPublishedTag

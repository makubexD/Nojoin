# Repository helpers. Nothing here knows how the containers are started.

Import-Module (Join-Path $PSScriptRoot 'Console.psm1')
#
# git answers some questions with exit codes ("this key is not set" is exit 1).
# PowerShell 7.4+ turns any non-zero native exit into a terminating error when
# $PSNativeCommandUseErrorActionPreference is set, which would hide those answers.

function Use-NativeExitCodes {
    if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
        Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Global
    }
}

function Get-RepoRoot {
    $root = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $root) {
        throw "Not a git repository. Run this from inside the Nojoin clone."
    }
    return (Resolve-Path $root.Trim()).Path
}

function Get-CurrentBranch {
    $branch = & git rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not read the current branch." }
    $branch = $branch.Trim()
    if ($branch -eq 'HEAD') {
        throw "HEAD is detached. Check out the branch you are working on first."
    }
    return $branch
}

$script:UpstreamUrl = 'https://github.com/Valtora/Nojoin.git'

# A remote added without a push URL pushes to its fetch URL, which here is
# upstream itself. The push URL is set to DISABLED in the same step.
function Assert-UpstreamRemote {
    & git remote get-url upstream 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Adding 'upstream' -> $script:UpstreamUrl"
        & git remote add upstream $script:UpstreamUrl
        if ($LASTEXITCODE -ne 0) { throw 'could not add the upstream remote' }
    }
    $pushUrl = & git config --get remote.upstream.pushurl
    if ($LASTEXITCODE -ne 0 -or -not $pushUrl) {
        Write-Host "Disabling pushes to 'upstream' (it is fetch-only)."
        & git remote set-url --push upstream DISABLED
        if ($LASTEXITCODE -ne 0) { throw 'could not disable the upstream push URL' }
    }
}

# The model folders' own .gitattributes (`*.bin filter=lfs`) makes git run a
# clean filter that marks bundled_models/*.bin dirty without changing the blob.
# .git/info/attributes is local and overrides that. assume-unchanged is not used:
# a flag left from an older checkout is cleared.
function Initialize-Clone {
    $marker = 'bundled_models/** -filter -diff -merge'
    $attrRel = (& git rev-parse --git-path info/attributes 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $attrRel) { throw "Not a git repository." }
    if (-not [System.IO.Path]::IsPathRooted($attrRel)) {
        $attrRel = Join-Path (Get-Location).Path $attrRel
    }
    $attrPath = [System.IO.Path]::GetFullPath($attrRel)
    $parent = Split-Path -Parent $attrPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $existing = if (Test-Path -LiteralPath $attrPath) { [System.IO.File]::ReadAllText($attrPath) } else { '' }
    $present = $false
    foreach ($row in ($existing -split "`r?`n")) {
        if ($row.Trim() -eq $marker) { $present = $true; break }
    }
    if (-not $present) {
        $next = $existing
        if ($next.Length -gt 0 -and -not $next.EndsWith("`n")) { $next += "`n" }
        $next += $marker + "`n"
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($attrPath, $next, $utf8)
        Write-Host "Unset the bundled_models LFS filter in $attrPath"
    }

    # -v prints a leading tag. Lowercase h is assume-unchanged. Uppercase H is a
    # normal cached file, and -match would treat those as the same letter.
    $clear = @()
    foreach ($row in @(& git ls-files -v -- bundled_models)) {
        $text = [string]$row
        if ($text.Length -ge 3 -and $text[0] -ceq 'h' -and $text[1] -eq ' ') {
            $clear += $text.Substring(2)
        }
    }
    if ($clear.Count -gt 0) {
        & git update-index --no-assume-unchanged -- @clear
        if ($LASTEXITCODE -ne 0) { throw "could not clear assume-unchanged on bundled_models" }
        Write-Host "Cleared assume-unchanged on $($clear.Count) bundled_models path(s)."
    }

    # Exit 1 means a file still differs. That is the cleanliness check's answer, not a failure.
    if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
        Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local
    }
    & git update-index --refresh 2>&1 | Out-Null
}

# Only tracked changes block a branch switch. Untracked files ride along.
# bundled_models/ is excluded: the phantom diff is the LFS clean filter.
function Assert-CleanTree {
    Initialize-Clone
    $dirty = & git status --porcelain --untracked-files=no -- ':!bundled_models'
    if ($LASTEXITCODE -ne 0) { throw "Not a git repository." }
    $rows = @($dirty | Where-Object { $_ })
    if ($rows.Count -gt 0) {
        throw ("Working tree has uncommitted changes. Commit or stash first:" +
               [Environment]::NewLine + ($rows -join [Environment]::NewLine))
    }
}

# True when the URL names Valtora/Nojoin, whatever the scheme and whether or
# not it ends in .git. The fork's origin must not be this repo.
function Test-UpstreamRepoUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    $text = $Url.Trim().TrimEnd('/')
    if ($text.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $text = $text.Substring(0, $text.Length - 4).TrimEnd('/')
    }
    return $text -match '(?i)(?:[:/])Valtora/Nojoin$'
}

function Assert-ForkOrigin {
    $url = (& git remote get-url origin 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $url) {
        throw (New-Refusal "This clone has no origin remote, so the fork cannot be pushed." `
                           "git remote add origin <your fork>")
    }
    if (Test-UpstreamRepoUrl $url) {
        throw (New-Refusal "origin points at the upstream repo (Valtora/Nojoin). The fork origin must not be upstream." `
                           "git remote set-url origin <your fork>")
    }
}

# Fast-forward push only. Prints the unpushed subjects, then refuses to call
# the push a success until origin/$Branch has every local commit. No --force,
# no --follow-tags. Returns $false when there is nothing to push.
function Push-GitBranch([string]$Branch) {
    & git rev-parse --verify --quiet "refs/remotes/origin/$Branch" | Out-Null
    $haveOrigin = ($LASTEXITCODE -eq 0)
    $range = "origin/$Branch..$Branch"
    if ($haveOrigin) {
        $ahead = (& git rev-list --count $range).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw (New-Refusal "could not compare $Branch with origin/$Branch." "git fetch origin")
        }
        if ($ahead -eq '0') { return $false }
        Write-Host "Unpushed on ${Branch}:"
        & git log --oneline $range
    } else {
        Write-Host "origin/$Branch does not exist yet. Pushing $Branch."
        & git log --oneline $Branch
    }
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "could not list unpushed commits on $Branch." "git fetch origin")
    }

    & git push --no-follow-tags origin $Branch
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "could not push $Branch to origin." "git status; this command does not force-push")
    }

    $left = (& git rev-list --count $range).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "could not verify origin/$Branch after the push." "git fetch origin")
    }
    if ($left -ne '0') {
        throw (New-Refusal "origin/$Branch is still $left commit(s) behind $Branch after the push." `
                           "git status; this command does not force-push")
    }
    return $true
}

# Parse KEY=value lines. Values are returned to the caller and must not be
# written to the host. Comments and blank lines are skipped.
function Read-DotEnv([string]$Path) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            continue
        }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ((($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'"))) -and $value.Length -ge 2) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $map[$key] = $value
    }
    return $map
}

# Replace the first KEY= line, or append one. The rest of the file is preserved.
# The value is not logged.
function Set-DotEnvKey([string]$Path, [string]$Key, [string]$Value) {
    $raw = if (Test-Path -LiteralPath $Path) { [System.IO.File]::ReadAllText($Path) } else { '' }
    $pattern = "(?m)^(\s*(?:export\s+)?$([regex]::Escape($Key))\s*=).*$"
    $match = [regex]::Match($raw, $pattern)
    if ($match.Success) {
        $next = $raw.Substring(0, $match.Index) + $match.Groups[1].Value + $Value + $raw.Substring($match.Index + $match.Length)
    } else {
        $next = $raw
        if ($next.Length -gt 0 -and -not $next.EndsWith("`n")) { $next += "`n" }
        $next += "$Key=$Value`n"
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $next, $utf8)
}

Export-ModuleMember -Function Use-NativeExitCodes, Get-RepoRoot, Get-CurrentBranch, `
                              Assert-UpstreamRemote, Assert-ForkOrigin, Test-UpstreamRepoUrl, `
                              Push-GitBranch, Assert-CleanTree, Initialize-Clone, `
                              Read-DotEnv, Set-DotEnvKey

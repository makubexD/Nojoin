#: bring upstream main into main, merge it into podman, and repin images

<#
.SYNOPSIS
    Fetch upstream, fast-forward main, merge it into podman, and pin the newest published release.

.DESCRIPTION
    In order:
        1. fetch upstream main and tags (the remote is added, fetch-only, if absent)
        2. refuse if origin points at Valtora/Nojoin
        3. refuse if main has commits that are not in upstream/main
        4. read upstream's check runs, unless -SkipUpstreamCiCheck.
           At least one run must be success. Without gh, this refuses.
        5. fast-forward main and push it with --no-follow-tags
        6. merge main into podman. Push podman when it is ahead of origin,
           including a push that failed on an earlier run
        7. move NojoinTag to the newest vX.Y.Z whose four images are on GHCR,
           commit that on podman, and push it

    A merge conflict stops for `git merge --abort`. The partial merge is not pushed.
    main is never committed to and is fast-forward only. Nothing is force-pushed.
    Upstream tags are fetched and never pushed: a v* tag on the fork would start release.yml.
    On failure the checkout returns to the branch this command started on.

.PARAMETER ReleaseBranch
    Branch that receives the merge. Default: podman.

.PARAMETER SkipUpstreamCiCheck
    Sync even when upstream CI is red, pending, or absent, and when gh is missing.

.PARAMETER SkipIdentityCheck
    Push even if the installed `gid` identity check fails. A missing gid is
    already a warning, not a refusal.

.EXAMPLE
    .\contrib\maku.ps1 fork sync
#>
param(
    [string]$ReleaseBranch = 'podman',
    [switch]$SkipUpstreamCiCheck,
    [switch]$SkipIdentityCheck
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Use-NativeExitCodes

$repoRoot = Get-RepoRoot

function Invoke-Checkout([string]$branch) {
    & git checkout $branch
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "could not check out '$branch'." `
                           "bundled_models/** -filter -diff -merge belongs in .git/info/attributes (Initialize-Clone writes it). Do not use assume-unchanged.")
    }
}

function Assert-UpstreamCiGreen([string]$sha) {
    $short = $sha.Substring(0, 8)
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw (New-Refusal "could not read upstream check runs for $sha." `
                           "gh auth status   or re-run with -SkipUpstreamCiCheck")
    }
    $runs = @(gh api --paginate "repos/Valtora/Nojoin/commits/$sha/check-runs" `
                --jq '.check_runs[] | "\(.name): \(.conclusion)"' 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "could not read upstream check runs for $sha." `
                           "gh auth status   or re-run with -SkipUpstreamCiCheck")
    }

    $parsed = @()
    foreach ($line in $runs) {
        $text = ([string]$line).Trim()
        if (-not $text) { continue }
        $idx = $text.LastIndexOf(': ')
        if ($idx -lt 1) { continue }
        $parsed += [pscustomobject]@{
            Name = $text.Substring(0, $idx)
            Conclusion = $text.Substring($idx + 2).Trim()
        }
    }

    if ($parsed.Count -eq 0) {
        throw (New-Refusal "Upstream has no CI results for $short yet." `
                           "wait, or re-run with -SkipUpstreamCiCheck")
    }

    $success = @($parsed | Where-Object { $_.Conclusion -eq 'success' })
    $bad = @($parsed | Where-Object { $_.Conclusion -notin @('success', 'skipped', 'neutral') })
    $nonGreen = @($parsed | Where-Object { $_.Conclusion -ne 'success' })
    if ($bad.Count -gt 0 -or $success.Count -eq 0) {
        $listed = @($nonGreen | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Conclusion }) -join '; '
        if (-not $listed) { $listed = 'no successful check' }
        throw (New-Refusal "Upstream CI is not green for ${short}: $listed" `
                           "re-run with -SkipUpstreamCiCheck")
    }
    foreach ($row in $nonGreen) {
        Write-Host ('  {0}: {1}' -f $row.Name, $row.Conclusion)
    }
    Write-Pass 'ci' "upstream green for $short ($($success.Count) succeeded, $($parsed.Count) total)"
}

function Update-PublishedPin([string]$Branch) {
    $published = Get-LatestPublishedTag
    if (-not $published) {
        throw (New-Refusal "No fetched vX.Y.Z tag has api, worker, worker-io, and frontend images on GHCR." `
                           "wait for the release images, or pin by hand: .\contrib\maku.ps1 images pin <tag> -SkipInspect")
    }
    $current = Get-NojoinTag
    if ([version]$published -le [version]$current) {
        Write-Host "Pin stays at $current. Newest published tag is $published."
        Write-Pass 'pin' $current
        return
    }

    Write-Host "Repinning $current -> $published."
    $touched = @(Set-NojoinTag $published)
    if ($touched.Count -eq 0) {
        Write-Pass 'pin' "$published already written"
        return
    }
    & git add -- @touched
    if ($LASTEXITCODE -ne 0) { throw "could not stage the pin ($($touched -join ', '))" }
    & git commit -m "contrib: pin Nojoin images to $published"
    if ($LASTEXITCODE -ne 0) { throw "could not commit the pin on $Branch" }
    if (-not (Push-GitBranch $Branch)) {
        throw (New-Refusal "the pin commit on $Branch was not pushed." `
                           "git status; this command does not force-push")
    }
    Add-Action 'pinned' "$current -> $published"
    Write-Pass 'pin' $published
}

$startingBranch = $null
$succeeded = $false
Push-Location $repoRoot
try {
    $startingBranch = Get-CurrentBranch
    Assert-ForkOrigin
    Assert-UpstreamRemote

    if ($SkipIdentityCheck) {
        Write-Warn 'identity' "check skipped. Pushing as $(& git config user.name)."
    } elseif (Get-Command gid -ErrorAction SilentlyContinue) {
        & gid
        if ($LASTEXITCODE -ne 0) {
            throw (New-Refusal "Identity check failed." "fix it, or re-run with -SkipIdentityCheck")
        }
    } else {
        Write-Warn 'identity' "gid is not installed, so the identity was not verified here."
    }

    Assert-CleanTree

    # Only main. Fetching every upstream branch breaks on Windows when two names
    # differ only by case. Tags are fetched and never pushed.
    & git fetch upstream --tags --prune '+refs/heads/main:refs/remotes/upstream/main'
    if ($LASTEXITCODE -ne 0) { throw "git fetch upstream failed" }

    & git rev-parse --verify --quiet main | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "This clone has no local main branch." `
                           "git branch main origin/main")
    }

    $ahead = (& git rev-list --count upstream/main..main).Trim()
    if ($LASTEXITCODE -ne 0) { throw "could not compare main with upstream/main" }
    if ($ahead -ne '0') {
        throw (New-Refusal "main has $ahead local commit(s), so it is no longer a mirror of upstream." `
                           "move them onto another branch and reset main to upstream/main")
    }

    $target = (& git rev-parse upstream/main).Trim()
    if ($SkipUpstreamCiCheck) {
        Write-Warn 'ci' "check skipped for $($target.Substring(0, 8))."
    } else {
        Assert-UpstreamCiGreen $target
    }

    Invoke-Checkout main
    & git merge --ff-only upstream/main
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "main could not fast-forward to upstream/main." `
                           "git status   on main")
    }
    if (Push-GitBranch 'main') { Add-Action 'pushed' 'origin/main' }

    & git rev-parse --verify --quiet $ReleaseBranch | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "Branch '$ReleaseBranch' does not exist." `
                           "git checkout -b $ReleaseBranch main")
    }

    Invoke-Checkout $ReleaseBranch
    $behind = (& git rev-list --count "$ReleaseBranch..main").Trim()
    if ($LASTEXITCODE -ne 0) { throw "could not compare $ReleaseBranch with main" }
    if ($behind -eq '0') {
        Write-Host "$ReleaseBranch already contains main. Nothing to merge."
    } else {
        Write-Host "Merging $behind commit(s) from main into $ReleaseBranch."
        & git merge --no-edit main
        if ($LASTEXITCODE -ne 0) {
            throw (New-Refusal "Merge conflict. The partial merge must not be pushed. This fork changes no upstream file, so a conflict means contrib/ collided with something new." `
                               "git merge --abort")
        }
        Add-Action 'merged' "main into $ReleaseBranch ($behind commits)"
    }
    # Also retries a release-branch push that failed on an earlier run.
    if (Push-GitBranch $ReleaseBranch) { Add-Action 'pushed' "origin/$ReleaseBranch" }

    Update-PublishedPin $ReleaseBranch

    & (Join-Path $PSScriptRoot 'status.ps1') -Branch $ReleaseBranch
    Write-Pass 'sync' 'complete'
    $succeeded = $true
    exit 0
}
finally {
    if (-not $succeeded -and $startingBranch) {
        $checkout = (& git checkout --quiet $startingBranch 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            Write-Warn 'branch' "could not check out $startingBranch again. If a merge is in progress, the partial merge must not be pushed."
            Write-Host '  fix: git merge --abort'
            if ($checkout) { Write-Host $checkout }
        }
    }
    Pop-Location
}

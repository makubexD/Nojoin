# Setting up a machine

From a machine that has never seen this fork to one that is serving Nojoin on Podman.

| Track | For |
| --- | --- |
| Part 1 | Run the stack |
| Part 2 | Push from this clone, and the one-time GitHub settings |

Part 1 makes no commits.

## Part 1 — Run it

### 1. Podman 5 on Windows

Podman Desktop, then a WSL machine with enough RAM for the models. This tooling targets Podman 5.x.

`podman machine inspect` records the memory the machine was created with (2048 MiB on this workstation). That number is not the RAM WSL gives the VM. With no `%USERPROFILE%\.wslconfig`, WSL2 uses 50% of the host RAM, and `podman machine set --memory` does not change it.

Create `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
memory=16GB
```

Then:

```powershell
wsl --shutdown
podman machine start
podman --version
podman info --format "{{.Host.MemTotal}}"
```

`stack doctor` fails when that value is below 8 GiB (8589934592 bytes). It prints the recorded inspect value as information. It does not write `.wslconfig` and it does not shut WSL down.

**Check:** `podman info` succeeds, and `.Host.MemTotal` is at least 8 GiB.

### 2. Clone, and switch branch

```powershell
git clone https://github.com/makubexD/Nojoin.git
cd Nojoin
git checkout podman
```

The checkout is required. `main` is a mirror of upstream and has no `contrib/`. You also need PowerShell 7 (`pwsh`).

**Check:** `ls contrib` lists `maku.ps1`, `lib`, `commands`, `fork`, `podman`.

### 3. Install and prove it

```powershell
.\contrib\maku.ps1 stack install
```

That copies `.env.example` to `.env` when needed, generates `DATA_ENCRYPTION_KEY`, `REDIS_PASSWORD`, and `FIRST_RUN_PASSWORD`, prints the first-run password once, pulls the pinned images, starts the stack, and runs `stack verify`.

`stack verify` must end with `DEPLOYMENT CHECK PASSED`. Then open <https://localhost:14443/setup> and enter the first-run password.

GPU stays off until a start, install, or update passes `-Gpu`. Later commands reuse that saved mode. `-Gpu:$false` turns it off. Recordings stay on `./data` unless verify reports that uid 1000 cannot write it, in which case:

```powershell
.\contrib\maku.ps1 stack start -DataVolume
```

If `./data` is not empty, copy those recordings first or add `-IgnoreExistingData`. `-Gpu` does not clear DataVolume.

Details: [../podman/DEPLOY.md](../podman/DEPLOY.md).

## Part 2 — Push, and the GitHub settings

Do this once per clone you commit from, and once on the GitHub repository.

### Remotes

```powershell
git remote add upstream https://github.com/Valtora/Nojoin.git
git remote set-url --push upstream DISABLED
```

`fork sync` does the same thing if you skip it. Confirm with `git remote -v`. The upstream push URL must be `DISABLED`.

### Workflows, in the repository settings

These are UI switches. They are not commits, because a commit would modify upstream files.

On <https://github.com/makubexD/Nojoin/actions>:

- Disable `site-deploy.yml`. It needs a Cloudflare secret and would fail on its schedule.
- Disable `release.yml`. A `v*` tag, including one pushed by accident, would publish images and a release from the fork.
- Disable `held-pin-watch.yml`.
- Disable `repo-audit-reminder.yml`.
- Leave `ci.yml` enabled. It runs on `main` and on pull requests.

Disable Dependabot under Settings → Code security and analysis. A Dependabot pull request would edit upstream files on a branch cut from `main`.

### The resolver script

`contrib/podman/nginx/05-podman-resolver.sh` is run with `sh` from the nginx entrypoint, so the git execute bit is not required. `contrib/.gitattributes` forces LF line endings. A CRLF shebang still fails. `fork status` prints the index mode when the file is tracked, and that line is informational.

### The bundled-model phantom diff

`bundled_models/**/*.bin` shows as modified because those folders' own `.gitattributes` set `*.bin filter=lfs`. The blob is unchanged. Do not commit it, and do not mark it `assume-unchanged`.

`fork sync` and `stack update` call `Initialize-Clone` before they decide the tree is clean. That writes one line into `.git/info/attributes` (the path from `git rev-parse --git-path info/attributes`):

```
bundled_models/** -filter -diff -merge
```

The file is local. The function appends that line once, clears any assume-unchanged bit already set on `bundled_models` paths, and runs `git update-index --refresh`. `Assert-CleanTree` still ignores `bundled_models/` when it looks for uncommitted changes.

### What sync refuses

Uncommitted tracked changes outside `bundled_models/`. Local commits on `main`. A red or empty upstream check run, unless you pass `-SkipUpstreamCiCheck`. A merge conflict. An installed `gid` that fails, unless you pass `-SkipIdentityCheck`.

After Part 2:

```powershell
.\contrib\maku.ps1 fork status
.\contrib\maku.ps1 images verify
```

# The branch model

`main` is a mirror of `Valtora/Nojoin`. `podman` is that mirror plus `contrib/`. No upstream file is modified, so merging `main` into `podman` has nothing to conflict with.

## Branches

| Branch | Role |
| --- | --- |
| `main` | Mirror of `upstream/main`. Updated only by fast-forward. Default branch, so GitHub's Sync fork stays a fast-forward |
| `podman` | The release branch. Carries `contrib/` only. Merged into, never rebased |

`contrib/` names this fork's branches, its upstream, and its image pin, so it stays off `main`.

## Remotes

`upstream` is `https://github.com/Valtora/Nojoin.git` with its push URL set to `DISABLED`. A remote without a push URL pushes to its fetch URL. `fork sync` adds the remote and disables the push URL when either is missing.

Upstream tags are fetched to find the release version. They are never pushed to `origin`. A `v*` tag on the fork would start `release.yml`.

## `fork sync`

```powershell
.\contrib\maku.ps1 fork sync
```

1. Fetch `upstream/main` and tags.
2. Refuse if `origin` points at `Valtora/Nojoin` (https or ssh, with or without `.git`). The fork origin must not be upstream.
3. Refuse if `main` has commits of its own.
4. Read upstream's check runs with `gh api --paginate`. At least one run must be `success`. Any run that is not `success` is printed as `name: conclusion`. `-SkipUpstreamCiCheck` skips this. Without `gh`, the gate refuses unless that switch is set.
5. Fast-forward `main` and push `origin/main` with `--no-follow-tags`. The push is a success only after `origin/main..main` is 0.
6. Merge `main` into `podman` with `--no-edit`. If `podman` is ahead of `origin/podman` — including a push that failed last time — push it with `--no-follow-tags` and the same check. A merge conflict stops for `git merge --abort`. The partial merge is not pushed.
7. Move `NojoinTag` to the newest `vX.Y.Z` whose api, worker, worker-io, and frontend images are already on GHCR. The check is an anonymous token from `https://ghcr.io/token` and a HEAD of the manifest URL. HTTP 404, or 401/403 on that HEAD, means the tag is not published. A timeout, 429, 5xx, or token failure throws, so a transient registry error cannot pin an older release. It does not use `podman manifest inspect` and does not need the Podman machine. The image tag drops the leading `v`, because that is what `release.yml` publishes. The pin only moves forward. The change is committed on `podman` and pushed with `--no-follow-tags`.

`main` stays fast-forward-only. Nothing is force-pushed. On failure the checkout returns to the branch the command started on.

It also refuses a dirty tree. `Initialize-Clone` unsets the `bundled_models/` LFS filter in `.git/info/attributes` first, and `Assert-CleanTree` still ignores that path. See [SETUP.md](SETUP.md). When `gid` is installed, a failed identity check refuses the push. When `gid` is absent, sync warns and continues.

## Ahead and behind

```powershell
.\contrib\maku.ps1 fork status
```

| Number | Meaning | Should it be zero? |
| --- | --- | --- |
| behind | Upstream has commits this branch has not taken | Yes. That is `fork sync` |
| ahead | This branch has commits upstream does not | On `podman`, no. Those commits are `contrib/` |

`main` is `0 ahead, 0 behind` after a sync.

## Image pin

`contrib/images.psd1` is the source of truth. `contrib/podman/compose.podman.yml` repeats the tag as `${NOJOIN_IMAGE_TAG:-<tag>}` because Compose cannot read the data file. `images verify` fails when they disagree. `images pin v2.5.1` rewrites both and does not commit. `fork sync` is what commits a moved pin.

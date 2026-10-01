# contrib — Podman on the `podman` branch

This directory is the whole fork. Upstream files are not modified. It exists only on `podman`.

## Quick start

```powershell
git clone https://github.com/makubexD/Nojoin.git
cd Nojoin
git checkout podman
.\contrib\maku.ps1 stack install
```

Then open <https://localhost:14443/setup>. The WSL2 VM needs at least 8 GiB before that command can succeed. [fork/SETUP.md](fork/SETUP.md) has the `.wslconfig` steps and the one-time GitHub settings.

## Commands

```
maku <resource> <action> [options]
```

```powershell
.\contrib\maku.ps1
.\contrib\maku.ps1 stack
```

| Resource | Actions | What it does |
| --- | --- | --- |
| `stack` | `doctor` `install` `start` `stop` `logs` `update` `verify` `backup` `timing` | run the compose stack on the Windows Podman machine |
| `fork` | `sync` `status` | fast-forward `main`, merge it into `podman`, keep the image pin current |
| `images` | `show` `pin` `verify` | the pinned GHCR tag in [images.psd1](images.psd1) |

`stack start` is safe to re-run. It reuses the saved GPU and data-volume mode. `-Gpu` or `-DataVolume` turns that mode on; `-Gpu:$false` or `-DataVolume:$false` turns one off. `-Gpu` does not clear DataVolume. `-DataVolume` stores recordings in the `nojoin_data` volume when the `./data` bind cannot be written from inside the machine. A non-empty `./data` blocks that switch until the files are copied, or `-IgnoreExistingData` is set.

Full help for any command:

```powershell
Get-Help .\contrib\commands\stack\start.ps1 -Full
```

## What is in here

| Path | What it is |
| --- | --- |
| `maku.ps1` | the only entry point; it discovers commands from the tree below |
| `commands/<resource>/<action>.ps1` | one file per command |
| `lib/*.psm1` | shared behaviour: podman, git, images, argument binding |
| `images.psd1` | the image tag and the fully qualified image names |
| `fork/` | setup and the branch rules |
| `podman/` | the compose overrides, the nginx resolver, and the deployment notes |

The stack is upstream's `docker-compose.example.yml` plus [podman/compose.podman.yml](podman/compose.podman.yml). New upstream services arrive with the next merge. The override only patches what Podman needs.

# Running Nojoin on the Windows Podman machine

The stack is upstream's compose file plus one override:

```powershell
podman compose -f docker-compose.example.yml -f contrib/podman/compose.podman.yml --env-file .env up -d
```

`.\contrib\maku.ps1 stack start` is that command. It also exports `NOJOIN_IMAGE_TAG` from `contrib/images.psd1` and `PODMAN_SOCKET` from `podman info --format '{{.Host.RemoteSocket.Path}}'`, so those two values have one source each. The defaults in the override exist so `compose config` still renders when the variables are unset.

Compose has to be Docker Compose v2.24 or newer (`!reset`, `!override`, `service_healthy`). Podman Desktop's `docker-compose` is that line, including the v5 build. `podman-compose` is not. `stack doctor` checks.

## What the override changes

| Upstream | On Podman |
| --- | --- |
| `redis:alpine`, `nginx:alpine`, `tecnativa/docker-socket-proxy`, `pgvector/pgvector:...` | `docker.io/...` |
| `ghcr.io/valtora/nojoin-*:latest` | the same names at `${NOJOIN_IMAGE_TAG}` |
| nginx `resolver 127.0.0.11` | `contrib/podman/nginx/05-podman-resolver.sh` rewrites it to every nameserver in `/etc/resolv.conf` (IPv6 in brackets) before nginx starts. `docker/init-ssl.sh` runs from the same entrypoint, not from `/docker-entrypoint.d` |
| `/var/run/docker.sock` | the machine's rootless socket, mounted at `/var/run/docker.sock` with `label=disable` |
| `worker-gpu` `deploy:` NVIDIA reservation | removed. CPU is the default |
| `OMP_NUM_THREADS` and the four sibling caps, all `2` | `worker-gpu` uses `${NOJOIN_ASR_THREADS:-8}`. The other workers stay at 2 |
| `logging: json-file` | removed, so Podman keeps k8s-file |
| `host.docker.internal:host-gateway` | unchanged. Podman 5 resolves `host-gateway` |

`./data` stays a bind mount so recordings stay visible on the host. `stack verify` checks that uid 1000 can write `/app/data`, and that uid 1000 can write `/home/appuser/.cache` in `nojoin-worker-cpu`. When the data write fails, the drvfs mount is the usual cause:

```powershell
.\contrib\maku.ps1 stack start -DataVolume
```

That adds `compose.datavolume.yml`, which puts the same data in the named volume `nojoin_data`. It does not move files that are already in `./data`. If `./data` exists and is not empty, `stack start`, `stack install`, and `stack update` refuse the switch: those recordings would no longer be visible. Copy them first, or pass `-IgnoreExistingData`. `stack backup` copies `./data`, or exports `nojoin_data` when that mode is on.

`stack start`, `stack install`, and `stack update` reuse the mode saved under `contrib/.local/` (gitignored). Passing `-Gpu` or `-DataVolume` turns that one mode on and remembers it. Passing `-Gpu` does not turn DataVolume off. Turning a mode off takes an explicit false: `-Gpu:$false` or `-DataVolume:$false`.

## Rootless gotchas

A rootful machine (`podman machine init --rootful`, or this default) means container root is real root in the VM, so the rootless uid-mapping notes apply only to rootless machines.

- The socket path has to be the path **inside** the machine (`/run/user/1000/podman/podman.sock` on the default rootless machine). A Windows `npipe` path cannot be mounted into the container. `doctor` prints the path it will use.
- `security_opt: [label=disable]` is on the socket-proxy because a bind of the Podman socket can be blocked when SELinux is enforcing. WSL is normally not enforcing. `stack doctor` prints `podman info` `.Host.Security.SELinuxEnabled` and warns, without failing, when it is true: bind mounts from `/mnt/c` may need `label=disable`.
- The nginx entrypoint is an `sh -c` list. It runs `05-podman-resolver.sh` and `docker/init-ssl.sh` with `sh` from `/opt/maku/`, then `exec /docker-entrypoint.sh nginx -g 'daemon off;'`. Those scripts are not mounted under `/docker-entrypoint.d`, so a missing execute bit does not skip them and they do not run twice. Upstream nginx has no `command:`, so that line is the image default (`nginx -g 'daemon off;'`). A CRLF shebang still fails as `/bin/sh\r`. `contrib/.gitattributes` forces LF for `05-podman-resolver.sh`. `fork status` prints the git mode and does not fail on it.
- Ports `14141` and `14443` are bound to `127.0.0.1` unless `NOJOIN_BIND_ADDRESS` says otherwise.
- `stack stop` stops containers. It does not delete volumes or `./data`.

## GPU (experimental, untested)

This path is experimental and has not been tested here. CPU is the default. The override deletes the upstream `deploy` reservation so Compose does not ask for an NVIDIA device Docker-style.

`stack start -Gpu` adds `compose.gpu.yml`:

```yaml
devices:
  - nvidia.com/gpu=all
```

That device form (`nvidia.com/gpu=all`) may be rejected by some Compose providers. Check the rendered service before relying on it:

```powershell
podman compose -f docker-compose.example.yml -f contrib/podman/compose.podman.yml -f contrib/podman/compose.gpu.yml config
```

Look at `worker-gpu` `devices`. If the provider drops or rejects `nvidia.com/gpu=all`, do not use `-Gpu`. Fall back to running a container with `podman run --device nvidia.com/gpu=all` (the same CDI name) and leave the stack on CPU.

The CDI spec has to exist inside the machine before the worker starts. Podman Desktop's GPU steps, run on the machine rather than on the Windows host:

```powershell
podman machine ssh
```

```sh
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | tee /etc/yum.repos.d/nvidia-container-toolkit.repo
yum install -y nvidia-container-toolkit
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list
```

The Windows host needs a current NVIDIA driver. WSL2 is required; Hyper-V is not. Then, back on the host:

```powershell
podman run --rm --device nvidia.com/gpu=all --security-opt=label=disable docker.io/nvidia/cuda:11.0.3-base-ubuntu20.04 nvidia-smi
.\contrib\maku.ps1 stack start -Gpu
```

`compose.gpu.yml` also sets `label=disable` on `worker-gpu`. When SELinux is enforcing, the CDI device nodes are otherwise blocked. WSL is normally not enforcing; `stack doctor` still reports the flag. The source for the install lines is Podman Desktop's GPU page.

If `nvidia-ctk cdi list` shows `nvidia.com/gpu=all` but `podman run --device nvidia.com/gpu=all` says the device is unresolvable, the CDI spec is newer than the parser in this Podman. Regenerate it with `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` after upgrading Podman. `doctor` requires Podman 5.x.

## Transcription speed on CPU

Whisper turbo is the default model. On a CPU it runs in fp32, because fp16 is used only when CUDA is present. Upstream compose sets `OMP_NUM_THREADS`, `MKL_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `NUMEXPR_NUM_THREADS`, and `VECLIB_MAXIMUM_THREADS` to 2 on every worker, so the ASR process stays near one or two cores however many the machine has.

The Podman override raises those five on `worker-gpu` only, to `${NOJOIN_ASR_THREADS:-8}`. `worker-cpu`, `worker-io`, and `worker-parse` keep 2. Set `NOJOIN_ASR_THREADS` in `.env`, then run `stack start` so Compose recreates `worker-gpu`. The default is 8. Do not set it above the CPU count `stack doctor` prints (`podman info` `.Host.CPUs`). Leave room for the other workers.

`stack timing` prints per-stage seconds from the `nojoin-worker-gpu` logs for recent recordings, then the total and the share taken by `final_asr_invocation`.

If that share is still most of the total:

1. Settings > AI > Whisper model > Small. Turbo is the default and suits NVIDIA GPUs. The setup wizard recommends Small or Base on a CPU-only machine.
2. The Parakeet engine is optional, from the same Settings > AI screen.
3. `WHISPER_ENABLE_WORD_TIMESTAMPS=false` in `.env`, then `stack start`. The trade-off is word-level alignment.

## Backup and restore

`stack backup` writes a directory under `contrib/.local/backups/<timestamp>`:

- `postgres.dump` — `pg_dump -Fc` from the running `nojoin-db` container. This is a consistent snapshot. The live `postgres_data` volume is not exported.
- `data/` — a copy of `./data`, or `nojoin_data.tar` when the saved mode uses the named volume.
- `model_cache.tar` when that volume exists.

Redis is not backed up. It is a broker and a cache. The stack recreates it empty.

`POSTGRES_USER` and `POSTGRES_DB` are read from `.env`. The defaults are `postgres` and `nojoin`. The command does not print them.

Restore the database into a running `nojoin-db`. Use the same user and database as `.env`:

```powershell
podman cp .\contrib\.local\backups\<timestamp>\postgres.dump nojoin-db:/tmp/postgres.dump
podman exec nojoin-db pg_restore -U postgres -d nojoin --clean --if-exists /tmp/postgres.dump
podman exec nojoin-db rm -f /tmp/postgres.dump
```

`pg_restore` may exit 1 when `--clean` mentions an object that is not there yet. Read the messages before treating that as a failed restore.

Restore `nojoin_data.tar` only while the stack is stopped. The volume name is the one labeled `com.docker.compose.volume=nojoin_data` (project `nojoin`), not a bare `nojoin_data` that might belong to another project:

```powershell
podman volume import <volume> .\contrib\.local\backups\<timestamp>\nojoin_data.tar
```

A host `./data` backup is a directory. Put it back at `./data`. `model_cache.tar` imports the same way when you need the warmed cache.

## Troubleshooting

| Symptom | What it means |
| --- | --- |
| `podman compose` says it cannot connect to the socket | The machine is stopped. `stack start` starts the default machine. It does not change memory or CPU |
| doctor fails memory | `podman info` `.Host.MemTotal` is below 8 GiB. The MiB value in `podman machine inspect` is only what was recorded when the machine was created. On WSL, `podman machine set --memory` does not apply. Create `%USERPROFILE%\.wslconfig` with `[wsl2]` and `memory=16GB`, then `wsl --shutdown`. [../fork/SETUP.md](../fork/SETUP.md) |
| `/api` returns 502 and the nginx error log says `host not found in upstream` or `api could not be resolved` | The resolver is still `127.0.0.11`, or `05-podman-resolver.sh` did not run. `podman exec nojoin-nginx grep resolver /etc/nginx/nginx.conf` should show the address from `resolv.conf`, and the upstream copy at `/etc/nginx/nginx.conf.upstream` should still say `127.0.0.11` |
| Admin log viewer is empty or the API log says the Docker client is unavailable | `PODMAN_SOCKET` is wrong, or SELinux blocked it. `stack verify` reads `nojoin-api` logs through `socket-proxy:2375` |
| `uid 1000 cannot write /app/data` | Rootless chown on the `/mnt/c` mount. Use `-DataVolume`. If `./data` is not empty, copy those recordings first or pass `-IgnoreExistingData` |
| `uid 1000 cannot write /home/appuser/.cache` | The worker cache directory is not writable by uid 1000. `stack verify` checks `nojoin-worker-cpu` |
| `host.docker.internal` does not resolve | Podman is older than 5, or `extra_hosts: host-gateway` was dropped. This override does not touch that line |
| `images verify` fails | `compose.podman.yml` drifted from `images.psd1`. `images pin` rewrites the tag default |

`stack update` pulls with `--ff-only`, pulls images only when the pin changed, runs `compose up -d` (which recreates only the services whose config changed), and runs `stack verify`.

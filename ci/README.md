# Resource-limited linux-tkg CI on oheaven.ru

## Behavior

- Woodpecker repository: `StreamVersus/linux-tkg`, branch `master`.
- A systemd timer observes `Frogging-Family/linux-tkg` master roughly once a minute.
- Each newly observed upstream HEAD queues a manual Woodpecker pipeline with its exact SHA.
  Multiple pushes between polls can collapse to the latest HEAD; this is not an upstream webhook.
- One workflow runs at a time. Extra upstream revisions queue in Woodpecker.
- Builds run unprivileged in an Arch container, without Docker socket or CI credentials.
- All agent-created containers, including checkout, have CPU quota 150000/100000
  (1.5 cores), memory 2684354560 bytes (2.5 GiB), and no swap allowance.
- Host cache, artifact directory, and read-only runner/config are the only global mounts.
  Repository trust permissions remain disabled. This agent currently serves this repository only.
- The local fixed config is copied byte-for-byte from `~/.config/frogminer/linux-tkg.cfg`.
  It specifies Clang, thin LTO, BORE, and Zen 4. Resulting kernels target Zen 4,
  not generic x86-64. Config checksum is checked before every build.
- Explicitly approved target override: `_NR_CPUS_value=16`, not VPS `nproc=2`.
- Other CI runtime settings: no menuconfig/diffconfig, two make jobs, one ThinLTO
  backend job, and the first maintained kernel series listed by upstream.
- A free-space watchdog stops builds below 3 GiB reserve. Thin LTO may still OOM
  at this memory ceiling; never raise limits or disable LTO silently.
- Completed kernel/header packages, checksums, and build configs are staged under
  `/root/linux-tkg/artifacts/<pipeline>-<upstream-sha>/`. Failed diagnostics have
  a hidden `.incomplete` directory. No kernel is installed on the VPS.
- Arch repository publication, signing, and serving are intentionally not implemented
  until complete kernel builds have been verified. Package extraction is not a boot test.

## Operations

```sh
/root/linux-tkg/ci/poll-upstream.py --status
/root/linux-tkg/ci/poll-upstream.py --force  # explicitly retry current upstream
journalctl -u linux-tkg-upstream.service -n 30 --no-pager
systemctl stop linux-tkg-upstream.timer    # stop new polling; running jobs continue
```

CI credentials stay in Woodpecker's existing root-only database. Host-only API
helper lives under `/root/.local/libexec`; it is not mounted into build jobs.
The existing Caddy service is not started or modified by this setup.

`bootstrap-image.sh` provisions an Arch builder with explicit Docker resource
limits and commits it as `local/linux-tkg-builder:20261103`. Installed toolchain
versions are recorded in `toolchain-packages.txt`; image digest in `builder-image.txt`.

#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
readonly upstream=https://github.com/Frogging-Family/linux-tkg.git
readonly cache=/cache artifacts=/artifacts
readonly min_free_kib=$((3 * 1024 * 1024))
readonly expected_config_sha=5d44e4fa94f0cd742cae19b88f1c1318d7de871d9bbd8f5ecc3fb36885d2b7d1
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) != 0 ]] || fail 'makepkg must not run as root'
[[ $(sha256sum /etc/linux-tkg.cfg | cut -d' ' -f1) == "$expected_config_sha" ]] || fail 'fixed config checksum changed'
[[ $(df -Pk "$cache" | awk 'END {print $4}') -gt "$min_free_kib" ]] || fail 'less than 3 GiB free disk'
mkdir -p "$cache/ccache" "$cache/sources" "$artifacts"
exec 9>"$cache/build.lock"
flock -n 9 || fail 'another build is running'
commit=${TKG_UPSTREAM_COMMIT:-}
[[ -n "$commit" ]] || commit=$(git ls-remote "$upstream" refs/heads/master | awk '{print $1}')
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail 'invalid upstream revision'
build_number=${CI_PIPELINE_NUMBER:-manual}
[[ "$build_number" =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid pipeline number'
readonly output="$artifacts/${build_number}-${commit:0:12}"
[[ ! -e "$output" ]] || fail 'artifact destination already exists'
# These two directories contain disposable generated files only.
rm -rf "$cache/work" "$cache/build"
mkdir -p "$cache/work"
cd "$cache/work"
git init -q
git remote add origin "$upstream"
git fetch --depth=1 origin "$commit"
git checkout --detach FETCH_HEAD
[[ $(git rev-parse HEAD) == "$commit" ]] || fail 'unexpected revision'
export HOME=/home/builder
export CCACHE_DIR="$cache/ccache" CCACHE_MAXSIZE=1G
ccache --max-size=1G
# Fixed config is mounted read-only. Runtime settings avoid prompts and
# retain the target workstation's 16 CPUs rather than the VPS's 2 CPUs.
export _EXT_CONFIG_PATH=/etc/linux-tkg.cfg _NR_CPUS_value=16
export _menunconfig=false _diffconfig=false _force_all_threads=false _nofallback=true
export _kernel_work_folder="$cache/build" _kernel_source_folder="$cache/sources"
export MAKEFLAGS=-j2 ZSTD_NBTHREADS=1 XZ_DEFAULTS=-T1
export _version
_version=$(bash -c 'source linux-tkg-config/prepare; printf "%s-latest" "${_current_kernels[0]}"')
[[ "$_version" =~ ^[0-9]+\.[0-9]+-latest$ ]] || fail 'cannot determine current kernel series'
printf 'Upstream commit: %s\nKernel series: %s\nTarget CPUs: %s\n' "$commit" "$_version" "$_NR_CPUS_value"
printf 'CPU quota: '; cat /sys/fs/cgroup/cpu.max
printf 'Memory limit: '; cat /sys/fs/cgroup/memory.max
staging="$artifacts/.${build_number}-${commit:0:12}.incomplete"
mkdir -p "$staging"
cp /etc/linux-tkg.cfg "$staging/linux-tkg.cfg"
printf '%s\n' "$commit" > "$staging/upstream-commit.txt"
watchdog=
cleanup() {
    rc=$?
    trap - EXIT
    [[ -z "$watchdog" ]] || { kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true; }
    if ((rc != 0)); then
        mkdir -p "$staging/logs"
        [[ ! -d logs ]] || cp -a logs/. "$staging/logs/"
        [[ ! -f BIG_UGLY_FROGMINER ]] || cp BIG_UGLY_FROGMINER "$staging/effective-config.cfg"
        printf '%s\n' "$rc" > "$staging/failed-exit-code.txt"
        printf 'Build failed; diagnostics: %s\n' "$staging" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT
# Feed default answers; build Arch packages only, never install them.
setsid bash -c 'set +e; yes "" | makepkg --nodeps --noconfirm --cleanbuild; result=${PIPESTATUS[1]}; exit "$result"' &
builder=$!
(
    while sleep 20; do
        free_kib=$(df -Pk "$cache" | awk 'END {print $4}')
        if ((free_kib < min_free_kib)); then
            printf 'ERROR: disk reserve below 3 GiB; stopping build\n' >&2
            kill -TERM -- "-$builder" 2>/dev/null || true
            sleep 10
            kill -KILL -- "-$builder" 2>/dev/null || true
            exit 1
        fi
    done
) &
watchdog=$!
wait "$builder"
shopt -s nullglob
packages=( ./*.pkg.tar.zst )
((${#packages[@]} >= 2)) || fail 'missing kernel or headers package'
for package in "${packages[@]}"; do
    pacman -Qip "$package" >/dev/null
    bsdtar -tf "$package" >/dev/null
    cp "$package" "$staging/"
done
cp BIG_UGLY_FROGMINER "$staging/effective-config.cfg"
[[ ! -f kernelconfig.new ]] || cp kernelconfig.new "$staging/kernel.config"
[[ ! -d logs ]] || cp -a logs "$staging/"
(cd "$staging"; sha256sum -- *.pkg.tar.zst > SHA256SUMS; sha256sum -c SHA256SUMS)
mv "$staging" "$output"
printf 'SUCCESS: packages in %s; repository publishing disabled.\n' "$output"

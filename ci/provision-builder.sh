#!/usr/bin/env bash
set -Eeuo pipefail
pacman -Syu --noconfirm --needed archlinux-keyring
pacman -S --noconfirm --needed base-devel git bc cpio gettext libelf libgcc openssl pahole perl python xxhash xz zlib zstd clang llvm lld rust rust-bindgen rust-src ccache curl util-linux
useradd --create-home --uid 1000 --shell /bin/bash builder
install -d -o builder -g builder /build
# Limit ThinLTO's own thread pool independently of make -j2.
cat > /usr/local/bin/ld.lld <<'WRAPPER'
#!/bin/sh
exec /usr/bin/ld.lld --threads=2 --thinlto-jobs=1 "$@"
WRAPPER
chmod 755 /usr/local/bin/ld.lld
pacman -Scc --noconfirm
printf '%s\n' 'Builder image provisioning complete.'

#!/usr/bin/env bash
set -Eeuo pipefail
cd /root/linux-tkg
name=linux-tkg-image-bootstrap
if docker container inspect "$name" >/dev/null 2>&1; then
    printf 'Container %s already exists; inspect it before retrying.\n' "$name" >&2
    exit 1
fi
docker run --name "$name" --cpus=1.5 --memory=2684354560 --memory-swap=2684354560 --pids-limit=1024 \
    --volume /root/linux-tkg/ci/provision-builder.sh:/provision.sh:ro \
    archlinux:base-devel bash /provision.sh
docker commit --change 'USER 1000:1000' --change 'WORKDIR /build' \
    --change 'ENV HOME=/home/builder' "$name" local/linux-tkg-builder:20261103
docker rm "$name"

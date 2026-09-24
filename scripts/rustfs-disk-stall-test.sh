#!/usr/bin/env bash
# Does a RustFS build survive a disk stall? (bead cnpg-playground-e84t)
#
# Throwaway RustFS whose /data is an ext4 loop device. A scoped user keeps doing
# PUT + LIST; fsfreeze then blocks the filesystem's I/O for <freeze-secs> while
# RustFS keeps running - the shape of the WSL2 host stall that killed
# objectstore-local. Checks S3 (auth, list, put) before, and 30s/2m/5m after thaw.
# A healthy build is back at list=1500/1500 put=ok by "thaw + 30s".
#
# Touches nothing in the cluster. Needs docker + privileged containers (losetup,
# fsfreeze); cleans up its container, volume and loop device on exit.
#
# usage: scripts/rustfs-disk-stall-test.sh <label> <freeze-secs> <image> [docker -e args...]
#   source scripts/common.sh; scripts/rustfs-disk-stall-test.sh ga 45 "$RUSTFS_IMAGE"
set -uo pipefail
[ $# -ge 3 ] || { sed -n '2,14p' "$0"; exit 2; }
LABEL=$1; FREEZE=$2; IMG=$3; shift 3
MC="${MC_IMAGE:-quay.io/minio/mc:latest}"
W=$(mktemp -d)
N=rustfs-stall-$LABEL; C=mc-stall-$LABEL; V=vol-stall-$LABEL
HELPER="docker run --rm --privileged -v $W:/w debian:bookworm-slim"
log() { echo "[$LABEL $(date -u +%H:%M:%S)] $*"; }

cleanup() {
  docker rm -f "$N" "$C" >/dev/null 2>&1
  docker volume rm "$V" >/dev/null 2>&1
  [ -n "${LOOP:-}" ] && $HELPER losetup -d "$LOOP" >/dev/null 2>&1
  rm -rf "$W"
}
trap cleanup EXIT

# 1. loop-backed ext4, owned by the rustfs uid (10001)
LOOP=$($HELPER sh -c "truncate -s 2G /w/$LABEL.img && mkfs.ext4 -q /w/$LABEL.img && losetup -f --show /w/$LABEL.img") || { log "losetup failed"; exit 1; }
$HELPER sh -c "mkdir -p /m && mount $LOOP /m && chown 10001:10001 /m && umount /m"
docker volume create --driver local --opt type=ext4 --opt device="$LOOP" "$V" >/dev/null
log "loop=$LOOP"

# 2. RustFS on it
docker run -d --name "$N" --network bridge -v "$V:/data" \
  -e RUSTFS_ACCESS_KEY=frzadmin -e RUSTFS_SECRET_KEY=frzsecret123 "$@" "$IMG" /data >/dev/null
sleep 10
IP=$(docker inspect "$N" --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')
log "rustfs $(docker exec "$N" rustfs --version 2>/dev/null | head -1) at $IP"

# 3. client: bulk-seed 1500 objects in a Loki-like layout, scoped user, then PUT+LIST forever
docker run -d --name "$C" --network bridge --entrypoint sh "$MC" -c "
  mkdir -p /seed && i=0; while [ \$i -lt 1500 ]; do d=/seed/platform/fp\$((i % 150)); mkdir -p \$d; echo x > \$d/chunk\$i; i=\$((i+1)); done
  mc alias set s http://$IP:9000 frzadmin frzsecret123 >/dev/null
  mc mb s/loki-direct >/dev/null && mc cp --recursive --quiet /seed/ s/loki-direct/ >/dev/null
  mc admin user add s lokidirect lokiDirectSecret >/dev/null; mc admin policy attach s readwrite --user lokidirect >/dev/null
  mc alias set u http://$IP:9000 lokidirect lokiDirectSecret >/dev/null
  echo SEEDED
  j=0; while true; do echo y | mc pipe u/loki-direct/live/o\$j >/dev/null 2>&1; mc ls --recursive u/loki-direct >/dev/null 2>&1; j=\$((j+1)); done" >/dev/null
until docker logs "$C" 2>&1 | grep -q SEEDED; do sleep 2; done

check() {
  docker run --rm --network bridge --entrypoint sh "$MC" -c "
    mc alias set u http://$IP:9000 lokidirect lokiDirectSecret >/dev/null 2>&1 || { echo 'AUTH=FAIL'; exit; }
    n=\$(mc ls --recursive u/loki-direct/platform 2>/dev/null | wc -l); echo \"list=\$n/1500\"
    echo z | mc pipe u/loki-direct/probe\$\$ >/dev/null 2>&1 && echo put=ok || echo put=FAIL" | tr '\n' ' '
}
log "before:          $(check)"

# 4. freeze the filesystem (same superblock as RustFS's /data) for FREEZE seconds
docker run --rm --privileged -v "$V:/mnt" debian:bookworm-slim sh -c "fsfreeze -f /mnt && sleep $FREEZE && fsfreeze -u /mnt"
log "thawed after ${FREEZE}s freeze"

sleep 30;  log "thaw + 30s:      $(check)"
sleep 90;  log "thaw + 2m:       $(check)"
sleep 180; log "thaw + 5m:       $(check)"
# RustFS logs to /logs inside the container, not to stdout.
L=$(docker exec "$N" sh -c 'cat /logs/*.log 2>/dev/null')
log "log: disk-timeouts=$(grep -c 'isk operation timed out' <<<"$L") faulty=$(grep -c 'health is faulty' <<<"$L")"

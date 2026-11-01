#!/bin/sh
# Drop privileges to PUID:PGID when started as root, so bind mounts owned by
# the host user stay writable. Set USER in compose instead if you prefer.
set -eu

PUID=${PUID:-1000}
PGID=${PGID:-1000}

if [ "$(id -u)" = "0" ]; then
  STAGE_DIR=${YT2ABS_STAGE_DIR:-${TMPDIR:-/tmp}/yt2abs-staging}
  mkdir -p /var/lib/yt2abs/logs "$STAGE_DIR" 2>/dev/null || true
  # Both must belong to the dropped user: mkdir above ran as root, and the
  # worker creates per-job directories inside the staging dir.
  chown -R "$PUID:$PGID" /var/lib/yt2abs "$STAGE_DIR" 2>/dev/null || true

  if command -v setpriv >/dev/null 2>&1; then
    exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups \
      env HOME=/tmp python3 /app/web.py
  fi
  echo "yt2abs: setpriv not found; refusing to run as root" >&2
  exit 1
fi

exec python3 /app/web.py

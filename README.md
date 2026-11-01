# yt2abs

Turn a YouTube link into a chaptered audiobook in your Audiobookshelf library.

A tiny web UI plus a CLI, one Python stdlib process, no database server, no
external services. Paste a link; out comes a single `.m4b` with embedded cover,
title/author/year, real chapters, and the source URL at the end of the
description.

```
┌─ YouTube → Audiobookshelf ──────────┐
│  https://youtube.com/watch?v=…      │
│  Title (optional)                   │
│  Mode: Auto / Merge / Split         │
│            [  Add audiobook  ]      │
│  Queue: 2 done, 1 downloading…      │
└─────────────────────────────────────┘
```

## Quick start (Docker)

```bash
mkdir -p yt2abs && cd yt2abs
curl -fsSLO https://raw.githubusercontent.com/harmolipi/yt2abs/main/docker-compose.yml
curl -fsSLO https://raw.githubusercontent.com/harmolipi/yt2abs/main/.env.example
cp .env.example .env
# edit .env: set YT2ABS_WEB_TOKEN and AUDIOBOOKS_DIR
docker compose up -d
```

Open `http://<host>:8087`, paste the token from `.env`, and submit a link.
The token is exchanged for an HttpOnly session cookie, so you only enter it
once per browser.

The container writes finished books straight into the mounted library folder.
If Audiobookshelf watches that folder, the book appears on its own; otherwise
set `ABS_URL`/`ABS_TOKEN` below and yt2abs asks ABS to scan.

### docker-compose.yml

```yaml
services:
  yt2abs:
    image: ghcr.io/harmolipi/yt2abs:latest
    ports: ["8087:8087"]
    environment:
      YT2ABS_WEB_TOKEN: ${YT2ABS_WEB_TOKEN}
      YT2ABS_OUTPUT_DIR: /audiobooks
      PUID: 1000
      PGID: 1000
      # ABS_URL: http://audiobookshelf:80
      # ABS_TOKEN: your-admin-token
      # ABS_LIBRARY_ID: optional
    volumes:
      - /path/to/audiobooks:/audiobooks
      - yt2abs-data:/var/lib/yt2abs
    restart: unless-stopped
volumes:
  yt2abs-data:
```

If Audiobookshelf runs in another compose project, attach both services to a
shared network (or use the host's IP and published port for `ABS_URL`).

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `YT2ABS_WEB_TOKEN` | — | Required access token. `openssl rand -hex 24` |
| `YT2ABS_ALLOW_UNAUTHENTICATED` | `0` | `1` disables auth — only behind a proxy that authenticates |
| `YT2ABS_COOKIE_SECURE` | `0` | `1` adds `Secure` to the session cookie (HTTPS deployments) |
| `YT2ABS_SESSION_TTL` | `2592000` | Session lifetime in seconds |
| `YT2ABS_WEB_HOST` / `_PORT` | `0.0.0.0` / `8087` | Listen address |
| `YT2ABS_OUTPUT_DIR` | `/audiobooks` | Where book folders are written |
| `YT2ABS_VERIFY_DIR` | `$YT2ABS_OUTPUT_DIR` | Where the book is checked after an ingest hook |
| `YT2ABS_INGEST_SCRIPT` | — | Optional post-publish hook (e.g. a drop-zone ingester) |
| `YT2ABS_INGEST_ARGS` | `--min-age-min 0 --lock-wait 240` | Arguments for that hook |
| `YT2ABS_BITRATE` | `128k` | AAC bitrate used when transcoding |
| `YT2ABS_COOKIES` | — | Netscape `cookies.txt` for age-restricted videos |
| `ABS_URL` | — | Audiobookshelf base URL, e.g. `http://audiobookshelf:80` |
| `ABS_TOKEN` | — | ABS API token. **Must be admin or root** for scans |
| `ABS_LIBRARY_ID` | auto | Pins the library instead of finding the first "book" library |
| `YT2ABS_SCAN` | `1` | `0` disables the ABS scan trigger |
| `PUID` / `PGID` | `1000` / `1000` | Container drops to these ids |
| `TZ` | container default | Timestamps in logs |

State lives in `/var/lib/yt2abs` (queue database and per-job logs).

## Playlists

A single video becomes one book. A playlist becomes **one book with one chapter
per video** by default. Use `--split` for one book per video, and `--limit N` to
cap it.

## CLI (no Docker)

Requires `bash`, `ffmpeg`, `jq`, `curl`, and `yt-dlp`:

```bash
sudo install -m 0755 app/yt2abs.sh /usr/local/bin/yt2abs
yt2abs 'https://www.youtube.com/watch?v=VIDEOID'
yt2abs 'https://www.youtube.com/playlist?list=PL...' --title 'Lectures'
yt2abs 'https://youtu.be/ID' --author 'Someone Else'
yt2abs 'https://www.youtube.com/playlist?list=PL...' --split --limit 5
```

Useful flags: `--dry-run`, `--no-cover`, `--no-ingest`, `--bitrate 96k`,
`--cookies cookies.txt`, `--keep-work`.

## Audiobookshelf scan

`ABS_TOKEN` must belong to an **admin or root** user. A normal library-scoped
user gets HTTP 403 from the scan endpoint; yt2abs logs that distinctly rather
than pretending it worked. When `ABS_LIBRARY_ID` is unset, the first library
with `mediaType == "book"` is used.

## How it works

1. `yt-dlp` resolves the URL and downloads the best audio stream.
2. AAC streams are remuxed without re-encoding; everything else is transcoded
   to AAC 128k.
3. `ffmpeg` muxes to `.m4b` with cover art and chapters, then writes the book
   folder atomically (`.part` until complete).
4. It either runs your ingest hook or asks ABS to scan.

## Troubleshooting

- **Downloads suddenly fail** — YouTube changed; rebuild with a newer
  `YTDLP_VERSION`, or `docker compose build --build-arg YTDLP_VERSION=<tag> .`
  (see [yt-dlp releases](https://github.com/yt-dlp/yt-dlp/releases)).
- **`Permission denied` writing to /audiobooks** — set `PUID`/`PGID` to the
  owner of the mounted directory.
- **ABS scan returns 401/403** — the token's user is not admin/root.
- **Age-restricted / members-only video** — export a `cookies.txt` and point
  `YT2ABS_COOKIES` at it.
- **Live streams** are refused; only finished videos can become audiobooks.

## License

MIT — see [LICENSE](LICENSE).

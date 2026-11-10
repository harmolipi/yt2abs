# syntax=docker/dockerfile:1
FROM python:3.12-slim-bookworm

# Pin the extractor: YouTube breaks old yt-dlp builds constantly. Bump this
# argument (or rebuild with --build-arg) when downloads start failing.
ARG YTDLP_VERSION=2026.10.26

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ffmpeg jq curl ca-certificates util-linux \
 && rm -rf /var/lib/apt/lists/*

# The universal zipapp runs on amd64 and arm64 alike.
RUN curl -fsSL --retry 3 -o /usr/local/bin/yt-dlp \
      "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp" \
 && chmod 0755 /usr/local/bin/yt-dlp \
 && yt-dlp --version

WORKDIR /app
COPY app/yt2abs.sh app/web.py app/entrypoint.sh /app/
RUN chmod 0755 /app/yt2abs.sh /app/entrypoint.sh

ENV PUID=1000 \
    PGID=1000 \
    YT2ABS_OUTPUT_DIR=/audiobooks \
    YT2ABS_STAGE_DIR=/tmp/yt2abs-staging \
    YT2ABS_LOG_DIR=/var/lib/yt2abs/logs \
    YT2ABS_LOCK_FILE=/var/lib/yt2abs/yt2abs.lock \
    YT2ABS_DB=/var/lib/yt2abs/queue.db \
    YT2ABS_JOB_LOG_DIR=/var/lib/yt2abs/logs \
    YT2ABS_BIN=/app/yt2abs.sh \
    YT2ABS_YTDLP=/usr/local/bin/yt-dlp \
    PYTHONUNBUFFERED=1

RUN mkdir -p /var/lib/yt2abs/logs /audiobooks
VOLUME ["/audiobooks", "/var/lib/yt2abs"]
EXPOSE 8087

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${YT2ABS_WEB_PORT:-8087}/healthz" || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]

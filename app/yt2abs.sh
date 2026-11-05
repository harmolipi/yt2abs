#!/usr/bin/env bash
# yt2abs.sh — turn a YouTube link into an Audiobookshelf audiobook.
#
#   yt2abs <url> [options]
#
# Downloads best audio with yt-dlp, muxes it into a single .m4b (AAC, embedded
# cover, real chapters), writes it into a folder named after the book, and
# optionally triggers your ingest hook or an Audiobookshelf library scan.
#
# A single video becomes one book. A playlist becomes ONE book with one chapter
# per video by default (--split makes one book per video instead).
#
# Options:
#   --title T        override the title
#   --author A       override the author/artist (default: channel name)
#   --merge          playlist -> one book with chapters (default for playlists)
#   --split          playlist -> one book per video
#   --limit N        process at most N playlist/search entries
#   --bitrate K      AAC bitrate used when transcoding (default 128k)
#   --no-cover       do not embed the thumbnail
#   --cookies FILE   Netscape cookies.txt for age-restricted/members-only videos
#   --dry-run        print the plan; download nothing
#   --no-ingest      only write the book; do not run the ingest hook or scan
#   --keep-work      keep the staging directory on failure
#   -h, --help       this text
#
# Environment (all optional except where noted):
#   YT2ABS_OUTPUT_DIR      where the finished book folder is written  (/audiobooks)
#   YT2ABS_VERIFY_DIR      where the book is expected afterwards      ($OUTPUT_DIR)
#   YT2ABS_INGEST_SCRIPT   post-publish hook (e.g. a drop-zone ingest) (unset)
#   YT2ABS_INGEST_ARGS     arguments passed to that hook
#                                                         (--min-age-min 0 --lock-wait 240)
#   YT2ABS_STAGE_DIR       download/transcode scratch  ($TMPDIR/yt2abs-staging)
#   YT2ABS_LOG_DIR         log directory               (/var/lib/yt2abs/logs)
#   YT2ABS_LOCK_FILE       concurrency lock            (/tmp/yt2abs.lock)
#   YT2ABS_YTDLP           yt-dlp binary               (yt-dlp)
#   YT2ABS_FFMPEG/_FFPROBE ffmpeg / ffprobe            (ffmpeg / ffprobe)
#   YT2ABS_BITRATE         AAC bitrate                 (128k)
#   YT2ABS_COOKIES         cookies.txt path             (unset)
#   ABS_URL                Audiobookshelf base URL      (unset)
#   ABS_TOKEN              ABS API token (admin)        (unset)
#   ABS_LIBRARY_ID         ABS library id               (auto-detect "book" library)
#   YT2ABS_SCAN            1/0: POST a library scan after writing a book (1)
#
# A file at ~/.config/yt2abs/env is sourced automatically if it exists (set
# YT2ABS_ENV_FILE to use another path), which is how a host install supplies
# the paths above without a wrapper script.
#
# Examples:
#   yt2abs 'https://www.youtube.com/watch?v=VIDEOID'
#   yt2abs 'https://www.youtube.com/playlist?list=PL...' --title 'Lectures'
#   yt2abs 'https://www.youtube.com/watch?v=VIDEOID&list=RD...'   # takes the video
#   yt2abs 'https://www.youtube.com/playlist?list=PL...' --split --limit 5

set -euo pipefail

# Optional per-user config, so the CLI needs no wrapper script:
#   ~/.config/yt2abs/env   (override with YT2ABS_ENV_FILE)
ENV_FILE=${YT2ABS_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/yt2abs/env}
if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

OUTPUT_DIR=${YT2ABS_OUTPUT_DIR:-/audiobooks}
VERIFY_DIR=${YT2ABS_VERIFY_DIR:-$OUTPUT_DIR}
INGEST_SCRIPT=${YT2ABS_INGEST_SCRIPT:-}
INGEST_ARGS=${YT2ABS_INGEST_ARGS:---min-age-min 0 --lock-wait 240}
STAGE_DIR=${YT2ABS_STAGE_DIR:-${TMPDIR:-/tmp}/yt2abs-staging}
LOG_DIR=${YT2ABS_LOG_DIR:-/var/lib/yt2abs/logs}
LOG_FILE=${YT2ABS_LOG_FILE:-$LOG_DIR/yt2abs.log}
LOCK_FILE=${YT2ABS_LOCK_FILE:-/tmp/yt2abs.lock}
YTDLP=${YT2ABS_YTDLP:-${YTDLP:-yt-dlp}}
FFMPEG=${YT2ABS_FFMPEG:-${FFMPEG:-ffmpeg}}
FFPROBE=${YT2ABS_FFPROBE:-${FFPROBE:-ffprobe}}
BITRATE=${YT2ABS_BITRATE:-128k}
COOKIES_FILE=${YT2ABS_COOKIES:-}
ABS_URL=${YT2ABS_ABS_URL:-${ABS_URL:-}}
ABS_TOKEN=${YT2ABS_ABS_TOKEN:-${ABS_TOKEN:-}}
ABS_LIBRARY_ID=${YT2ABS_ABS_LIBRARY_ID:-${ABS_LIBRARY_ID:-}}
SCAN=${YT2ABS_SCAN:-1}

COVER=1
DRY_RUN=0
RUN_INGEST=1
KEEP_WORK=0
MODE=auto
LIMIT=0
TITLE_OVERRIDE=
AUTHOR_OVERRIDE=
URL=
WORK_DIR=
PLAYLIST_TITLE=
YTDLP_AUTH=()

usage() { sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'; }

log() {
  [[ -n "$LOG_FILE" ]] || return 0
  [[ -w "$LOG_FILE" || -w "$(dirname "$LOG_FILE")" ]] || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

say() { printf '%s\n' "$*"; log "$*"; }

cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]] || return 0
  if [[ $KEEP_WORK -eq 1 ]]; then
    printf 'kept staging dir: %s\n' "$WORK_DIR" >&2
    return 0
  fi
  rm -rf -- "$WORK_DIR"
  WORK_DIR=
}
trap cleanup EXIT

die() {
  printf 'ERROR: %s\n' "$*" >&2
  log "ERROR: $*"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)      TITLE_OVERRIDE=${2:?--title needs a value}; shift ;;
    --author)     AUTHOR_OVERRIDE=${2:?--author needs a value}; shift ;;
    --merge)      MODE=merge ;;
    --split)      MODE=split ;;
    --limit)      LIMIT=${2:?--limit needs a value}; shift ;;
    --bitrate)    BITRATE=${2:?--bitrate needs a value}; shift ;;
    --no-cover)   COVER=0 ;;
    --cookies)    COOKIES_FILE=${2:?--cookies needs a path}; shift ;;
    --dry-run)    DRY_RUN=1 ;;
    --no-ingest)  RUN_INGEST=0 ;;
    --keep-work)  KEEP_WORK=1 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "unknown option: $1 (try --help)" ;;
    *)            [[ -z "$URL" ]] || die "only one URL at a time"; URL=$1 ;;
  esac
  shift
done

[[ -n "$URL" ]] || { usage >&2; exit 2; }
command -v "$YTDLP" >/dev/null || die "yt-dlp not found ($YTDLP)"
command -v "$FFMPEG" >/dev/null || die "ffmpeg not found"
[[ -n "$COOKIES_FILE" ]] && YTDLP_AUTH=(--cookies "$COOKIES_FILE")
[[ -n "$ABS_URL" ]] && ABS_URL=${ABS_URL%/}

mkdir -p "$STAGE_DIR" "$OUTPUT_DIR" "$LOG_DIR" 2>/dev/null || true
[[ -d "$STAGE_DIR" ]] || die "cannot create staging dir: $STAGE_DIR"
[[ -d "$OUTPUT_DIR" ]] || die "output dir does not exist: $OUTPUT_DIR"

# One job at a time: a download + transcode is heavy, and two runs writing into
# the same library at once would race each other and the scanner.
exec 9>"$LOCK_FILE"
flock -n 9 || die "another yt2abs job is already running"

# ── helpers ──────────────────────────────────────────────────────────────────

sanitize() {
  # Filesystem-safe, length-safe folder/file name from a video title.
  local s=$1
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  s=${s//$'\t'/ }
  s=${s//\//-}
  s=${s//\\/-}
  s=${s//:/ -}
  s=$(printf '%s' "$s" | LC_ALL=C sed 's/[[:cntrl:]]//g')
  s=$(printf '%s' "$s" | sed -E 's/[[:space:]]+/ /g')
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  s=${s%"${s##*[!.]}"}
  # 150 bytes is comfortably under the 255-byte filename limit; iconv -c drops
  # a multi-byte character that got cut in half.
  if [[ $(printf '%s' "$s" | wc -c) -gt 150 ]]; then
    s=$(printf '%s' "$s" | cut -b1-150 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true)
    s=${s%"${s##*[![:space:]]}"}
  fi
  printf '%s' "$s"
}

ffmeta_escape() {
  # ffmpeg ffmetadata escaping: backslash first, then the specials.
  local v=$1
  v=${v//\\/\\\\}
  v=${v//=/\\=}
  v=${v//;/\\;}
  v=${v//#/\\#}
  v=${v//$'\n'/ }
  v=${v//$'\r'/ }
  printf '%s' "$v"
}

add_meta() {
  [[ -n "${3:-}" ]] || return 0
  printf '%s=%s\n' "$2" "$(ffmeta_escape "$3")" >>"$1"
}

add_chapter() {
  [[ "$3" -gt "$2" ]] || return 0
  {
    printf '[CHAPTER]\nTIMEBASE=1/1000\nSTART=%s\nEND=%s\ntitle=%s\n' \
      "$2" "$3" "$(ffmeta_escape "$4")"
  } >>"$1"
}

probe_codec() {
  local c
  c=$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=codec_name \
      -of csv=p=0 "$1" 2>/dev/null | head -1 || true)
  printf '%s' "${c:-unknown}"
}

probe_duration_ms() {
  local d
  d=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | head -1 || true)
  awk -v d="$d" 'BEGIN{ if (d ~ /^[0-9.]+$/) printf "%d", d*1000; else print 0 }'
}

fetch_json() {
  local url=$1; shift
  "$YTDLP" -J --no-warnings "$@" "$url"
}

download_audio() {
  local url=$1 base=$2 work=$3
  local -a args=(
    --no-warnings --no-playlist --no-progress
    --socket-timeout 30 --retries 10
    -f 'bestaudio[ext=m4a]/bestaudio'
    -o "$base.%(ext)s"
  )
  [[ $COVER -eq 1 ]] && args+=(--write-thumbnail --convert-thumbnails jpg)
  ( cd "$work" && "$YTDLP" "${args[@]}" "${YTDLP_AUTH[@]}" "$url" ) >&2 \
    || die "yt-dlp failed for $url"
  find "$work" -maxdepth 1 -type f -name "$base.*" \
    ! -name '*.json' ! -name '*.jpg' ! -name '*.part' -print -quit
}

normalize_audio() {
  # AAC in -> remux (no re-encode); anything else -> AAC transcode.
  local in=$1 out=$2 codec
  codec=$(probe_codec "$in")
  if [[ "$codec" == "aac" ]]; then
    "$FFMPEG" -hide_banner -loglevel error -y -i "$in" -vn -c:a copy "$out"
  else
    "$FFMPEG" -hide_banner -loglevel error -y -i "$in" -vn \
      -c:a aac -b:a "$BITRATE" -ar 44100 -ac 2 "$out"
  fi
  [[ -s "$out" ]] || die "ffmpeg produced no audio for $in"
}

mux_book() {
  # $1 audio, $2 ffmetadata, $3 cover|"", $4 output, $5 description|""
  local audio=$1 meta=$2 cover=$3 out=$4 description=${5:-} codec
  codec=$(probe_codec "$audio")
  # ALL inputs first, then output options: a -map between two -i flags is read
  # as an input option for the next input and ffmpeg aborts.
  local -a args=(
    -hide_banner -loglevel error -y
    -i "$audio"
    -f ffmetadata -i "$meta"
  )
  if [[ -n "$cover" && -f "$cover" ]]; then
    args+=(-i "$cover")
  fi
  args+=(-map 0:a -map_metadata 1)
  if [[ -n "$cover" && -f "$cover" ]]; then
    args+=(-map 2:v -c:v mjpeg -disposition:v attached_pic)
  fi
  if [[ "$codec" == "aac" ]]; then
    args+=(-c:a copy)
  else
    args+=(-c:a aac -b:a "$BITRATE" -ar 44100 -ac 2)
  fi
  # ffmetadata cannot carry newlines; -metadata on the command line can, which
  # is how the source URL gets its own line at the end of the description.
  [[ -n "$description" ]] && args+=(-metadata "description=$description")
  args+=(-movflags +faststart -f ipod "$out")
  "$FFMPEG" "${args[@]}"
  [[ -s "$out" ]] || die "ffmpeg produced no m4b at $out"
}

add_source_chapters() {
  # $1 info JSON, $2 duration ms, $3 fallback title, $4 meta file
  local json=$1 dur=$2 fallback=$3 meta=$4
  local count i start end title last=0
  count=$(jq -r '(.chapters // []) | length' <<<"$json" 2>/dev/null || echo 0)
  if [[ "${count:-0}" -eq 0 ]]; then
    add_chapter "$meta" 0 "$dur" "$fallback"
    return 0
  fi
  for ((i = 0; i < count; i++)); do
    start=$(jq -r ".chapters[$i].start_time // 0" <<<"$json")
    end=$(jq -r ".chapters[$i].end_time // 0" <<<"$json")
    title=$(jq -r ".chapters[$i].title // empty" <<<"$json")
    start=$(awk -v s="$start" 'BEGIN{printf "%d", (s+0)*1000}')
    end=$(awk -v e="$end" 'BEGIN{printf "%d", (e+0)*1000}')
    [[ -n "$title" ]] || title="Chapter $((i + 1))"
    [[ "$i" -eq 0 ]] && start=0
    [[ "$start" -lt "$last" ]] && start=$last
    [[ "$i" -eq $((count - 1)) ]] && end=$dur
    [[ "$end" -gt "$dur" ]] && end=$dur
    [[ "$end" -gt "$start" ]] || continue
    add_chapter "$meta" "$start" "$end" "$title"
    last=$end
  done
}

# ── post-publish: ingest hook or ABS scan ────────────────────────────────────

abs_scan() {
  [[ -n "$ABS_URL" && -n "$ABS_TOKEN" ]] || return 0
  command -v curl >/dev/null || { say "WARN: curl not found; cannot trigger an ABS scan"; return 0; }
  local lib=$ABS_LIBRARY_ID code
  if [[ -z "$lib" ]]; then
    command -v jq >/dev/null || { say "WARN: jq not found; set ABS_LIBRARY_ID to trigger scans"; return 0; }
    lib=$(curl -s --max-time 15 -H "Authorization: Bearer $ABS_TOKEN" \
      "$ABS_URL/api/libraries" 2>/dev/null \
      | jq -r '[.libraries[]? | select(.mediaType == "book") | .id][0] // empty' 2>/dev/null)
  fi
  if [[ -z "$lib" ]]; then
    say "WARN: could not determine the ABS library id — set ABS_LIBRARY_ID"
    return 0
  fi
  code=$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $ABS_TOKEN" "$ABS_URL/api/libraries/$lib/scan" 2>/dev/null)
  case "$code" in
    200) say "✓ ABS library scan triggered" ;;
    401|403) say "WARN: ABS rejected the scan (HTTP $code) — the token needs admin/root" ;;
    *)   say "WARN: ABS scan returned HTTP ${code:-none}" ;;
  esac
}

post_publish() {
  local name=$1
  if [[ -n "$INGEST_SCRIPT" ]]; then
    [[ -x "$INGEST_SCRIPT" ]] || { say "WARN: ingest script not executable: $INGEST_SCRIPT"; return 0; }
    say "→ ingest"
    local -a args=()
    read -r -a args <<<"$INGEST_ARGS"
    if "$INGEST_SCRIPT" "${args[@]}" >>"$LOG_FILE" 2>&1; then
      if [[ -e "$VERIFY_DIR/$name" ]]; then
        say "✓ linked into the library: $name"
      else
        say "WARN: ingest exited cleanly but '$name' is not in $VERIFY_DIR — check $LOG_FILE"
      fi
    else
      say "WARN: ingest pass exited non-zero — check $LOG_FILE"
    fi
    return 0
  fi
  [[ "$SCAN" == "1" ]] && abs_scan
  return 0
}

# ── publish ─────────────────────────────────────────────────────────────────

publish() {
  local outfile=$1 name=$2 target="$OUTPUT_DIR/$name"

  if [[ -e "$target" ]]; then
    if compgen -G "$target/*.m4b" >/dev/null; then
      say "SKIP: '$name' already exists in $OUTPUT_DIR (nothing overwritten)"
      return 0
    fi
    # A folder containing nothing but .part files is debris from an interrupted
    # run and may be replaced. Anything else is left strictly alone.
    if [[ -z "$(find "$target" -mindepth 1 -maxdepth 1 ! -name '*.part' -print -quit 2>/dev/null)" ]]; then
      say "→ replacing an unfinished previous attempt: $target"
      rm -rf -- "$target"
    else
      say "SKIP: '$name' already exists (and is not an unfinished yt2abs output)"
      return 0
    fi
  fi

  mkdir -p "$target"
  chmod 755 -- "$target"
  # .part until the copy is complete, so a scanner can never pick up a
  # half-written audiobook.
  cp -p -- "$outfile" "$target/$name.m4b.part"
  chmod 644 -- "$target/$name.m4b.part"
  mv -f -- "$target/$name.m4b.part" "$target/$name.m4b"
  say "✓ wrote: $target/$name.m4b"
  post_publish "$name"
}

# ── single video ─────────────────────────────────────────────────────────────

do_single() {
  local url=$1
  local json title author upload_date description duration_s duration_ms name
  json=$(fetch_json "$url" --no-playlist "${YTDLP_AUTH[@]}") || die "could not read video info"
  [[ "$(jq -r '.is_live // false' <<<"$json")" == "true" ]] && die "live stream — nothing to download"

  title=$(jq -r '.title // empty' <<<"$json")
  [[ -n "$TITLE_OVERRIDE" ]] && title=$TITLE_OVERRIDE
  [[ -n "$title" ]] || die "video has no title"
  author=$(jq -r '.uploader // .channel // empty' <<<"$json")
  [[ -n "$AUTHOR_OVERRIDE" ]] && author=$AUTHOR_OVERRIDE
  upload_date=$(jq -r '.upload_date // empty' <<<"$json")
  description=$(jq -r '.description // empty' <<<"$json" | head -c 1800)
  # The source link goes at the end of the description on its own line.
  if [[ -n "$description" ]]; then
    description="$description"$'\n\n'"Source: $url"
  else
    description="Source: $url"
  fi
  duration_s=$(jq -r '.duration // 0' <<<"$json")
  duration_ms=$(awk -v d="$duration_s" 'BEGIN{printf "%d", (d+0)*1000}')
  name=$(sanitize "$title")
  [[ -n "$name" ]] || name=$(jq -r '.id // "video"' <<<"$json")

  if [[ $DRY_RUN -eq 1 ]]; then
    local chapters; chapters=$(jq -r '(.chapters // []) | length' <<<"$json")
    say "DRY-RUN single: '$name' by '${author:-unknown}' — ${duration_s}s, $chapters chapters"
    say "        target: $OUTPUT_DIR/$name/$name.m4b"
    return 0
  fi

  WORK_DIR=$(mktemp -d "$STAGE_DIR/run.XXXXXX")
  say "↓ downloading '$name' (${duration_s}s)"
  local src; src=$(download_audio "$url" audio "$WORK_DIR")
  [[ -n "$src" ]] || die "no audio file was downloaded"

  local audio="$WORK_DIR/audio-normalized.m4a" cover="$WORK_DIR/audio.jpg"
  normalize_audio "$src" "$audio"
  [[ $COVER -eq 1 && -f "$cover" ]] || cover=""
  [[ "$duration_ms" -gt 0 ]] || duration_ms=$(probe_duration_ms "$audio")

  local meta="$WORK_DIR/meta.txt"
  : >"$meta"
  add_meta "$meta" title "$title"
  add_meta "$meta" artist "$author"
  add_meta "$meta" album_artist "$author"
  add_meta "$meta" album "$title"
  add_meta "$meta" genre "Audiobook"
  [[ -n "$upload_date" && "$upload_date" != "NA" ]] && add_meta "$meta" date "${upload_date:0:4}"
  add_meta "$meta" comment "$url"
  add_source_chapters "$json" "$duration_ms" "$title" "$meta"

  mux_book "$audio" "$meta" "$cover" "$WORK_DIR/$name.m4b" "$description"
  publish "$WORK_DIR/$name.m4b" "$name"
  cleanup
}

# ── playlist merged into one book ────────────────────────────────────────────

do_merge() {
  local json=$ROOT_JSON title='' author=''
  title=${PLAYLIST_TITLE:-}
  [[ -n "$TITLE_OVERRIDE" ]] && title=$TITLE_OVERRIDE
  [[ -n "$title" ]] || title="YouTube playlist $(date +%F)"

  local n=$ENTRY_COUNT
  [[ "$LIMIT" -gt 0 && "$n" -gt "$LIMIT" ]] && n=$LIMIT

  if [[ $DRY_RUN -eq 1 ]]; then
    say "DRY-RUN merge: '$title' — $n entries -> one book with $n chapters"
    say "        target: $OUTPUT_DIR/$(sanitize "$title")/"
    return 0
  fi

  WORK_DIR=$(mktemp -d "$STAGE_DIR/run.XXXXXX")
  mkdir -p "$WORK_DIR/parts" "$WORK_DIR/norm"

  local i=0 pbase id entry_url part_json etitle dur_ms src cover=""
  local -a audio_files=() chapter_durs=() chapter_titles=()
  while IFS=$'\t' read -r id entry_url; do
    i=$((i + 1))
    pbase=$(printf '%03d' "$i")
    say "↓ [$i/$n] $entry_url"
    part_json=$(fetch_json "$entry_url" --no-playlist "${YTDLP_AUTH[@]}") || die "could not read entry $i"
    etitle=$(jq -r '.title // empty' <<<"$part_json")
    [[ -n "$etitle" ]] || etitle="Part $i"
    src=$(download_audio "$entry_url" "$pbase" "$WORK_DIR/parts")
    [[ -n "$src" ]] || die "no audio for entry $i"
    normalize_audio "$src" "$WORK_DIR/norm/$pbase.m4a"
    dur_ms=$(probe_duration_ms "$WORK_DIR/norm/$pbase.m4a")
    [[ "$dur_ms" -gt 0 ]] || die "could not read duration for entry $i"
    [[ -z "$author" ]] && author=$(jq -r '.uploader // .channel // empty' <<<"$part_json")
    [[ -z "$cover" && -f "$WORK_DIR/parts/$pbase.jpg" ]] && cover="$WORK_DIR/parts/$pbase.jpg"
    audio_files+=("$WORK_DIR/norm/$pbase.m4a")
    chapter_durs+=("$dur_ms")
    chapter_titles+=("$etitle")
  done < <(jq -r '(.entries // [])[:'"$n"'] | .[] | [(.id // ""), (.url // ("https://www.youtube.com/watch?v=" + .id))] | @tsv' <<<"$json")

  [[ ${#audio_files[@]} -gt 0 ]] || die "nothing downloaded"

  say "⇄ concatenating ${#audio_files[@]} parts"
  local list="$WORK_DIR/concat.txt" f
  : >"$list"
  for f in "${audio_files[@]}"; do
    printf "file '%s'\n" "${f//\'/\'\\\'\'}" >>"$list"
  done
  local merged="$WORK_DIR/merged.m4a"
  "$FFMPEG" -hide_banner -loglevel error -y -f concat -safe 0 -i "$list" -c:a copy "$merged"
  [[ -s "$merged" ]] || die "concat produced no audio"

  local meta="$WORK_DIR/meta.txt"
  : >"$meta"
  add_meta "$meta" title "$title"
  add_meta "$meta" artist "$author"
  add_meta "$meta" album_artist "$author"
  add_meta "$meta" album "$title"
  add_meta "$meta" genre "Audiobook"
  add_meta "$meta" comment "$URL"
  local start=0 j
  for ((j = 0; j < ${#audio_files[@]}; j++)); do
    dur_ms=${chapter_durs[$j]}
    add_chapter "$meta" "$start" "$((start + dur_ms))" "${chapter_titles[$j]}"
    start=$((start + dur_ms))
  done

  local name; name=$(sanitize "$title")
  [[ -n "$name" ]] || name="YouTube playlist"
  mux_book "$merged" "$meta" "$cover" "$WORK_DIR/$name.m4b" "Source: $URL"
  publish "$WORK_DIR/$name.m4b" "$name"
  cleanup
}

# ── split playlist: one book per video ───────────────────────────────────────

do_split() {
  local n=$ENTRY_COUNT
  [[ "$LIMIT" -gt 0 && "$n" -gt "$LIMIT" ]] && n=$LIMIT
  say "→ split mode: $n books"
  local i=0 id entry_url
  while IFS=$'\t' read -r id entry_url; do
    i=$((i + 1))
    say "── [$i/$n] ──"
    do_single "$entry_url"
  done < <(jq -r '(.entries // [])[:'"$n"'] | .[] | [(.id // ""), (.url // ("https://www.youtube.com/watch?v=" + .id))] | @tsv' <<<"$ROOT_JSON")
}

# ── plan: video or playlist? ─────────────────────────────────────────────────

say "→ resolving $URL"
resolve_args=(--flat-playlist)
case "$MODE" in
  merge|split) ;;
  auto)
    # A watch/shorts/youtu.be URL means "this video", even with &list=; anything
    # else (/playlist, channels, searches) may resolve to a playlist.
    if [[ "$URL" =~ ^https?://([^/]*\.)?(youtube\.com/(watch\?|shorts/)|youtu\.be/) ]]; then
      resolve_args+=(--no-playlist)
    fi
    ;;
esac
[[ "$LIMIT" -gt 0 ]] && resolve_args+=(--playlist-end "$LIMIT")

ROOT_JSON=$(fetch_json "$URL" "${resolve_args[@]}" "${YTDLP_AUTH[@]}") || die "could not resolve URL"
ROOT_TYPE=$(jq -r '._type // "video"' <<<"$ROOT_JSON")
ENTRY_COUNT=$(jq -r 'if ._type == "playlist" then (.entries // [] | length) else 1 end' <<<"$ROOT_JSON")

if [[ "$ROOT_TYPE" == "playlist" ]]; then
  [[ "$ENTRY_COUNT" -gt 0 ]] || die "playlist is empty (or private)"
  [[ "$MODE" == auto ]] && MODE=merge
  PLAYLIST_TITLE=$(jq -r '.title // empty' <<<"$ROOT_JSON")
  say "  playlist: ${PLAYLIST_TITLE:-untitled} — $ENTRY_COUNT entries (mode: $MODE)"
else
  MODE=single
fi

case "$MODE" in
  single) do_single "$URL" ;;
  merge)  do_merge ;;
  split)  do_split ;;
  *)      die "internal: bad mode $MODE" ;;
esac

say "done."

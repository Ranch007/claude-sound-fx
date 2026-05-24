#!/bin/bash
# Claude Code hook event handler.
# Usage: hook.sh <event_type>
#
# Reads user config from ~/.claude/sound-fx.local.json:
#   theme:   "mix" | "jarvis" | "glados" | ... (default: mix)
#   mode:    "full" | "minimal"                (default: full)
#   enabled: true | false                      (default: true)
#
# Each theme directory under assets/ contains a manifest.json
# that maps event names to sound files. Adding a new theme =
# adding a new directory with manifest.json + wav files.
#
# Environment: CLAUDE_SOUND_VOLUME (0-100, default 60)

# Resolve plugin root
if [ -n "$CLAUDE_PLUGIN_ROOT" ]; then
  PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

ASSETS_DIR="$PLUGIN_ROOT/assets"
CONFIG_FILE="$HOME/.claude/sound-fx.local.json"
SOUND_VOLUME=${CLAUDE_SOUND_VOLUME:-60}
SOUND_PORT=${CLAUDE_SOUND_PORT:-19876}
RELAY_HOST=${CLAUDE_SOUND_RELAY_HOST:-127.0.0.1}

# 为 Windows Python 兼容性转换路径（Git Bash / MSYS2 / Cygwin）
IS_MINGW=false
case "$(uname)" in
  MINGW*|MSYS*|CYGWIN*)
    IS_MINGW=true
    CONFIG_FILE=$(cygpath -m "$CONFIG_FILE" 2>/dev/null || echo "$CONFIG_FILE")
    ASSETS_DIR=$(cygpath -m "$ASSETS_DIR" 2>/dev/null || echo "$ASSETS_DIR")
    ;;
esac

# 自动检测 Python 命令
# MINGW：python3 可能是 Windows Store 占位符（无法执行），优先用 python
if [ "$IS_MINGW" = true ]; then
  PYTHON=$(command -v python || command -v python3 || echo "python")
else
  PYTHON=$(command -v python3 || command -v python || echo "python")
fi

EVENT="$1"
[ -z "$EVENT" ] && exit 0

# Sanitize event name
EVENT=$(echo "$EVENT" | tr -cd 'a-zA-Z0-9_')
[ -z "$EVENT" ] && exit 0

# Read user config
THEME="mix"
MODE="full"
ENABLED="True"
if [ -f "$CONFIG_FILE" ]; then
  THEME=$($PYTHON -c "
import json
c = json.load(open('$CONFIG_FILE', encoding='utf-8'))
print(c.get('theme', 'mix'))
" 2>/dev/null || echo "mix")
  MODE=$($PYTHON -c "
import json
c = json.load(open('$CONFIG_FILE', encoding='utf-8'))
print(c.get('mode', 'full'))
" 2>/dev/null || echo "full")
  ENABLED=$($PYTHON -c "
import json
c = json.load(open('$CONFIG_FILE', encoding='utf-8'))
print(c.get('enabled', True))
" 2>/dev/null || echo "True")
fi

# Disabled mode: exit silently
[ "$ENABLED" = "False" ] && exit 0

# Minimal mode: only essential events
if [ "$MODE" = "minimal" ]; then
  case "$EVENT" in
    start|complete|notification) ;;
    *) exit 0 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Fire-and-forget winget install with multiple fallback sources.
# Runs in background; the current hook invocation skips playback entirely.
# Next event will pick up the newly installed ffplay.exe.
# ---------------------------------------------------------------------------
_winget_install() {
  local WGET=""
  if command -v winget.exe >/dev/null 2>&1; then
    WGET="winget.exe"
  elif command -v winget >/dev/null 2>&1; then
    WGET="winget"
  else
    return
  fi
  echo "[sound-fx] ffplay.exe not found, installing FFmpeg (background)..." >&2
  (
    # 0. 官方 winget 源 — Gyan build（gyan.dev 托管）
    "$WGET" install --scope user --source winget Gyan.FFmpeg \
      --accept-source-agreements --accept-package-agreements --silent 2>/dev/null && exit 0
    # 1. BtbN build（GitHub 托管，国内可能更快）
    "$WGET" install --scope user --source winget BtbN.FFmpeg \
      --accept-source-agreements --accept-package-agreements --silent 2>/dev/null && exit 0
    # 2. Gyan Shared build（备用）
    "$WGET" install --scope user --source winget Gyan.FFmpeg.Shared \
      --accept-source-agreements --accept-package-agreements --silent 2>/dev/null && exit 0
    # 3. 通用 ffmpeg（让 winget 自行匹配最佳版本）
    "$WGET" install --scope user --source winget ffmpeg \
      --accept-source-agreements --accept-package-agreements --silent 2>/dev/null && exit 0
  ) &
}

# Detect audio player: local player if available, otherwise relay
PLAYER=""
IS_WSL=false
if [ "$(uname)" = "Darwin" ]; then
  PLAYER="afplay"
else
  # WSL: use ffplay.exe via interop.  If missing, install and skip playback.
  if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
    if command -v ffplay.exe >/dev/null 2>&1; then
      PLAYER="ffplay.exe"
    else
      _winget_install
      exit 0
    fi
  fi
  # Linux native players (also works if WSL has PulseAudio via WSLg)
  if [ -z "$PLAYER" ]; then
    for cmd in paplay ffplay aplay; do
      if command -v "$cmd" >/dev/null 2>&1; then
        PLAYER="$cmd"
        break
      fi
    done
  fi
  # MINGW: use ffplay.exe.  If missing, install and skip playback.
  if [ -z "$PLAYER" ] && [ "$IS_MINGW" = true ]; then
    if command -v ffplay.exe >/dev/null 2>&1; then
      PLAYER="ffplay.exe"
    else
      _winget_install
      exit 0
    fi
  fi
fi

# No local player found — forward to relay (remote SSH / headless)
if [ -z "$PLAYER" ]; then
  curl -s --connect-timeout 1 "http://${RELAY_HOST}:${SOUND_PORT}/${EVENT}" &>/dev/null &
  exit 0
fi

# Collect candidates from manifest.json files
# If theme=mix, scan all directories; otherwise only the matching one
CANDIDATES=$($PYTHON -c "
import json, os, sys

assets_dir = '$ASSETS_DIR'
theme = '$THEME'
event = '$EVENT'

candidates = []
for d in sorted(os.listdir(assets_dir)):
    theme_dir = os.path.join(assets_dir, d)
    manifest = os.path.join(theme_dir, 'manifest.json')
    if not os.path.isfile(manifest):
        continue
    # Filter by theme: 'mix' uses all, otherwise match directory name
    if theme != 'mix' and d != theme:
        continue
    try:
        m = json.load(open(manifest, encoding='utf-8'))
        for f in m.get(event, []):
            path = os.path.join(theme_dir, f)
            if os.path.exists(path):
                candidates.append(path)
    except (json.JSONDecodeError, IOError):
        continue

for c in candidates:
    print(c)
" 2>/dev/null)

[ -z "$CANDIDATES" ] && exit 0

# Pick random candidate (compatible with bash 3.x on macOS)
IFS=$'\n' read -r -d '' -a FILES <<< "$CANDIDATES" || true
COUNT=${#FILES[@]}
[ "$COUNT" -eq 0 ] && exit 0
FILE="${FILES[$((RANDOM % COUNT))]}"

[ -z "$FILE" ] && exit 0

# Convert path for WSL players that need Windows paths
PLAY_FILE="$FILE"
if [ "$IS_WSL" = true ] && [ "$PLAYER" = "ffplay.exe" ]; then
  PLAY_FILE=$(wslpath -w "$FILE" 2>/dev/null || echo "$FILE")
fi
# Play with volume control (cross-platform)
case "$PLAYER" in
  afplay)
    VOL=$(printf '%.2f' "$(echo "$SOUND_VOLUME / 100" | bc -l)")
    afplay -v "$VOL" "$FILE" &
    ;;
  paplay)
    PA_VOL=$((SOUND_VOLUME * 65536 / 100))
    paplay --volume="$PA_VOL" "$FILE" &
    ;;
  ffplay)
    ffplay -nodisp -autoexit -loglevel quiet -volume "$SOUND_VOLUME" "$FILE" &
    ;;
  ffplay.exe)
    ffplay.exe -nodisp -autoexit -loglevel quiet -volume "$SOUND_VOLUME" "$PLAY_FILE" &>/dev/null &
    ;;
  aplay)
    aplay -q "$FILE" &
    ;;
esac
exit 0

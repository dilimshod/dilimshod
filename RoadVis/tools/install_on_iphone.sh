#!/usr/bin/env bash
# Builds the app and installs it on the iPhone connected to this Mac — no clicking in Xcode.
#
# Requirements (one-time):
#   1. Xcode 26 installed and started once.
#   2. Your Apple ID added in Xcode → Settings → Accounts (a free Apple ID is enough).
#   3. iPhone connected by cable (or paired over Wi-Fi), unlocked, "Trust This Computer" accepted,
#      Developer Mode on (Settings → Privacy & Security → Developer Mode).
#
# Usage (from the repository root or anywhere):
#   bash <repo>/RoadVis/tools/install_on_iphone.sh            # or RoadVis/tools/… before the rename
# Optional overrides:
#   TEAM_ID=ABCDE12345 BUNDLE_ID=uz.example.roadvis DEVICE_ID=<udid> bash install_on_iphone.sh
# Natural voice (Microsoft Edge neural clips, see tools/VOICE_CLIPS.md):
#   bash install_on_iphone.sh --voices     # if RoadVis/VoiceClips has no clips yet, generate them first
#   VOICE_ARGS="--uz-voice uz-UZ-SardorNeural" bash install_on_iphone.sh --voices
set -euo pipefail

WANT_VOICES=0
for arg in "$@"; do
  case "$arg" in
    --voices) WANT_VOICES=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) printf 'Неизвестный параметр: %s (допустимо: --voices)\n' "$arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
PROJECT="$(ls -d *.xcodeproj 2>/dev/null | head -n 1)"
[ -n "$PROJECT" ] || fail "Не найден .xcodeproj в $PROJECT_DIR"
SCHEME="${PROJECT%.xcodeproj}"
say "Проект: $PROJECT_DIR/$PROJECT (схема $SCHEME)"

command -v xcodebuild >/dev/null || fail "Нет xcodebuild. Установите Xcode из App Store и запустите его один раз."
if xcode-select -p | grep -q CommandLineTools; then
  fail "Активны только Command Line Tools. Выполните: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi
xcodebuild -version | head -n 1

# --- 0. Voice clips (optional) ----------------------------------------------------------------------
CLIPS_DIR="$PROJECT_DIR/$SCHEME/VoiceClips"
clip_count() { { find "$CLIPS_DIR" -maxdepth 1 \( -name '*.m4a' -o -name '*.mp3' \) 2>/dev/null || true; } | wc -l | tr -d ' '; }
if [ "$(clip_count)" -eq 0 ]; then
  if [ "$WANT_VOICES" -eq 1 ]; then
    if ! command -v python3 >/dev/null; then
      printf 'python3 не найден — голосовые клипы пропущены (будет системный голос).\n'
    elif ! curl -sS -m 8 -o /dev/null https://speech.platform.bing.com 2>/dev/null; then
      printf 'Нет доступа к speech.platform.bing.com — голосовые клипы пропущены (будет системный голос).\n'
    else
      say "Генерация естественного голоса (Microsoft Edge, один раз ~2–4 мин)…"
      python3 -c 'import edge_tts' 2>/dev/null || python3 -m pip install --user --quiet edge-tts \
        || printf 'Не удалось установить edge-tts (python3 -m pip install --user edge-tts).\n'
      # shellcheck disable=SC2086
      python3 "$PROJECT_DIR/tools/generate_voice_clips.py" ${VOICE_ARGS:-} \
        || printf 'Генерация клипов завершилась с ошибкой — недостающие фразы прозвучат системным голосом.\n'
      say "Голосовых клипов: $(clip_count)"
    fi
  else
    printf 'Подсказка: естественный голос — запустите скрипт с флагом --voices (см. tools/VOICE_CLIPS.md).\n'
  fi
else
  say "Голосовых клипов: $(clip_count)"
fi

# --- 1. Development team -------------------------------------------------------------------------
TEAM_ID="${TEAM_ID:-}"
if [ -z "$TEAM_ID" ]; then
  # Teams of the accounts added in Xcode → Settings → Accounts.
  TEAM_ID="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
            | grep -Eo 'teamID = "?[A-Z0-9]{10}' | grep -Eo '[A-Z0-9]{10}' | head -n 1 || true)"
fi
if [ -z "$TEAM_ID" ]; then
  TEAM_ID="$(defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null \
            | grep -Eo 'teamID = "?[A-Z0-9]{10}' | grep -Eo '[A-Z0-9]{10}' | head -n 1 || true)"
fi
if [ -z "$TEAM_ID" ]; then
  TEAM_ID="$(defaults read com.apple.dt.Xcode 2>/dev/null \
            | grep -Eo 'teamID = "?[A-Z0-9]{10}' | grep -Eo '[A-Z0-9]{10}' | head -n 1 || true)"
fi
if [ -z "$TEAM_ID" ]; then
  # Fallback: organisational unit (= team ID) of an installed "Apple Development" certificate.
  TEAM_ID="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null | grep -Eo 'OU ?= ?[A-Z0-9]{10}' | grep -Eo '[A-Z0-9]{10}' | head -n 1 || true)"
fi
[ -n "$TEAM_ID" ] || fail "Не найдена команда разработчика. Откройте Xcode → Settings → Accounts → «+» → Apple ID, войдите и запустите скрипт ещё раз."
say "Команда разработчика (Team ID): $TEAM_ID"

# --- 2. Bundle identifier (must be unique for free Apple IDs) -------------------------------------
if [ -z "${BUNDLE_ID:-}" ]; then
  USER_PART="$(printf '%s' "${USER:-user}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  BUNDLE_ID="uz.${USER_PART:-user}.roadvis"
fi
say "Bundle ID: $BUNDLE_ID"

# --- 3. Connected iPhone ----------------------------------------------------------------------------
DEVICE_ID="${DEVICE_ID:-}"
if [ -z "$DEVICE_ID" ]; then
  TMP_JSON="$(mktemp -t roadvis-devices).json"
  xcrun devicectl list devices --json-output "$TMP_JSON" >/dev/null 2>&1 || true
  if [ -s "$TMP_JSON" ]; then
    DEVICE_ID="$(/usr/bin/python3 - "$TMP_JSON" <<'PY' 2>/dev/null || true
import json, sys
data = json.load(open(sys.argv[1]))
best = None
for d in data.get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") == "virtual":
        continue
    score = (conn.get("tunnelState") == "connected", conn.get("transportType") == "wired")
    if best is None or score > best[0]:
        best = (score, hw.get("udid") or d.get("identifier"))
print(best[1] if best else "")
PY
)"
  fi
fi
if [ -z "$DEVICE_ID" ]; then
  # Fallback for older tools: "iPhone (18.1) (00008110-0012345678901234)".
  DEVICE_ID="$(xcrun xctrace list devices 2>/dev/null | grep -E '^(iPhone|iPad)' | grep -v Simulator | head -n 1 \
              | grep -Eo '\([0-9A-Fa-f-]{24,}\)' | tr -d '()' || true)"
fi
[ -n "$DEVICE_ID" ] || fail "iPhone не найден. Подключите его кабелем, разблокируйте, нажмите «Доверять» и включите Режим разработчика."
say "iPhone: $DEVICE_ID"

# --- 4. Build & sign ---------------------------------------------------------------------------------
DERIVED="$PROJECT_DIR/build/DerivedData"
mkdir -p "$PROJECT_DIR/build"
say "Сборка (первый раз может занять несколько минут)…"
set -o pipefail
xcodebuild \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build | tee "$PROJECT_DIR/build/xcodebuild.log" | grep -E "error:|warning: .*(sign|provision)|BUILD (SUCCEEDED|FAILED)" || true
grep -q "BUILD SUCCEEDED" "$PROJECT_DIR/build/xcodebuild.log" \
  || fail "Сборка не удалась. Подробности: $PROJECT_DIR/build/xcodebuild.log"

APP="$(ls -d "$DERIVED"/Build/Products/Debug-iphoneos/*.app | head -n 1)"
[ -d "$APP" ] || fail "Не найден собранный .app"

# --- 5. Install & launch ------------------------------------------------------------------------------
say "Установка на iPhone…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
say "Запуск…"
if ! xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1; then
  printf '\nПриложение установлено, но iOS не дала его запустить: сначала доверьте сертификату разработчика.\n'
  printf 'iPhone → Настройки → Основные → VPN и управление устройством → ваш Apple ID → «Доверять», затем откройте приложение.\n'
fi
say "Готово. С бесплатным Apple ID приложение работает 7 дней — затем просто запустите этот скрипт снова."

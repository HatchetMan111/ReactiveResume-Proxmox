#!/usr/bin/env bash
#
# reactive-resume-inner.sh – provisioniert Reactive Resume im Gast (LXC/VM).
#
# Wird vom Host-Installer per pct exec bzw. ssh aufgerufen. Kann auf einem
# Debian/Ubuntu-Host auch direkt als root ausgeführt werden.
#
set -Eeuo pipefail

APP_ID="reactive-resume"
APP_DIR="/opt/reactive-resume"
APP_PORT="3000"
APP_URL=""
APP_IMAGE="amruthpillai/reactive-resume:latest"
LOG_FILE="/var/log/reactive-resume-install.log"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main}"
# shellcheck disable=SC2034
DEBUG=0
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  # shellcheck disable=SC2034
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
die()       { msg_error "$*"; exit 1; }

usage() {
  cat <<EOF
Reactive Resume – In-Guest-Installer

Usage: bash reactive-resume-inner.sh [OPTIONEN]

  --port N            Web-UI-Port (Default: ${APP_PORT})
  --app-url URL       Öffentliche URL (Default: http://<erkannte-IP>:<port>)
  --app-image REF     App-Image inkl. Tag (Default: ${APP_IMAGE})
  --app-dir PATH      Installationsverzeichnis (Default: ${APP_DIR})
  --debug             bash -x aktivieren
  -h, --help          diese Hilfe
EOF
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

normalize_port() {
  local p="${1:-}"
  is_uint "$p" && (( p >= 1 && p <= 65535 )) || die "Ungültiger Port: ${p}"
  printf '%s\n' "$p"
}

detect_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  printf '%s\n' "$ip"
}

normalize_app_url() {
  local url="${1:-}"
  url="${url%/}"
  [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || die "APP_URL muss mit http:// oder https:// beginnen: ${url}"
  printf '%s\n' "$url"
}

env_get() {
  local key="$1" file="$2" line
  [[ -f "$file" ]] || return 1
  line="$(grep -E "^${key}=" "$file" | tail -n1 || true)"
  [[ -n "$line" ]] || return 1
  line="${line#*=}"
  line="${line%\"}"
  line="${line#\"}"
  printf '%s\n' "$line"
}

env_set() {
  local key="$1" val="$2" file="$3" tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    grep -vE "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s="%s"\n' "$key" "$val" >> "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

gen_hex() { openssl rand -hex 32; }

write_env() {
  local file="$1" pg auth enc db
  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file"
  pg="$(env_get POSTGRES_PASSWORD "$file" || true)"
  auth="$(env_get AUTH_SECRET "$file" || true)"
  enc="$(env_get ENCRYPTION_SECRET "$file" || true)"
  [[ -n "$pg" ]] || pg="$(gen_hex)"
  [[ -n "$auth" ]] || auth="$(gen_hex)"
  [[ -n "$enc" ]] || enc="$(gen_hex)"
  [[ "$auth" != "$enc" ]] || die "AUTH_SECRET und ENCRYPTION_SECRET müssen verschieden sein."
  db="postgresql://postgres:${pg}@postgres:5432/postgres"
  env_set POSTGRES_PASSWORD "$pg" "$file"
  env_set DATABASE_URL "$db" "$file"
  env_set AUTH_SECRET "$auth" "$file"
  env_set ENCRYPTION_SECRET "$enc" "$file"
  env_set APP_URL "$APP_URL" "$file"
  env_set PORT "$APP_PORT" "$file"
  env_set APP_IMAGE "$APP_IMAGE" "$file"
}

redact_env() {
  [[ -f "${APP_DIR}/.env" ]] || return 0
  sed -E 's/^(POSTGRES_PASSWORD|AUTH_SECRET|ENCRYPTION_SECRET|DATABASE_URL)=.*/\1="***"/' "${APP_DIR}/.env"
}

on_error() {
  local ec=$? line="$1" cmd="$2"
  trap - ERR
  msg_error "FEHLER: »${cmd}« in Zeile ${line} (Exit ${ec})."
  msg_error "Installer-Log: ${LOG_FILE}"
  echo "--- docker compose ps ---" >&2
  ( cd "$APP_DIR" 2>/dev/null && docker compose ps 2>&1 || true ) >&2
  echo "--- docker compose logs (tail 200) ---" >&2
  ( cd "$APP_DIR" 2>/dev/null && docker compose logs --tail=200 2>&1 || true ) >&2
  echo "--- systemctl status ---" >&2
  systemctl status "$APP_ID" --no-pager -l 2>&1 | tail -n 100 >&2 || true
  echo "--- journalctl (tail 100) ---" >&2
  journalctl -u "$APP_ID" -n 100 --no-pager 2>&1 || true
  echo "--- .env (maskiert) ---" >&2
  redact_env >&2 || true
  msg_error "Erneut mit --debug ausführen: bash /tmp/reactive-resume-inner.sh --debug"
  exit "$ec"
}

if [[ "${REACTIVE_RESUME_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

# main folgt in Task 4
main() {
  die "noch nicht implementiert"
}
main "$@"

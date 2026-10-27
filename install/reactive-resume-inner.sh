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
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
ASSET_DIR=""
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main}"
DIAG_READY=0
# DEBUG and SCRIPT_DIR are consumed by Task 4 (CLI parsing and asset lookup).
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
die() {
  local ec=1
  msg_error "$*"
  if [[ "${DIAG_READY:-0}" == "1" ]] && declare -F on_error >/dev/null 2>&1; then
    on_error "${BASH_LINENO[0]:-?}" "die" "$ec"
  fi
  exit "$ec"
}

usage() {
  cat <<EOF
Reactive Resume – In-Guest-Installer

Usage: bash reactive-resume-inner.sh [OPTIONEN]

  --port N            Web-UI-Port (Default: ${APP_PORT})
  --app-url URL       Öffentliche URL (Default: http://<erkannte-IP>:<port>)
  --app-image REF     App-Image inkl. Tag (Default: ${APP_IMAGE})
  --app-dir PATH      Installationsverzeichnis (Default: ${APP_DIR})
  --asset-dir PATH    Verzeichnis mit compose.yml und systemd-Unit
  --debug             bash -x aktivieren
  -h, --help          diese Hilfe
EOF
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

normalize_port() {
  local p="${1:-}"
  is_uint "$p" && (( 10#$p >= 1 && 10#$p <= 65535 )) || die "Ungültiger Port: ${p}"
  printf '%s\n' "$((10#$p))"
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
  [[ -n "$url" ]] || die "APP_URL darf nicht leer sein."
  [[ "$url" != *[[:space:]]* ]] || die "APP_URL darf keine Leerzeichen enthalten: ${url}"
  while [[ "$url" == */ ]]; do url="${url%/}"; done
  [[ "$url" =~ ^https?://[^/?#[:space:]:][^/?#[:space:]]*([/?#][^[:space:]]*)?$ ]] || die "APP_URL muss mit http:// oder https:// beginnen: ${url}"
  printf '%s\n' "$url"
}

env_get() {
  local key="$1" file="$2" line rc=0
  [[ -f "$file" ]] || return 1
  [[ -r "$file" ]] || return 2
  line="$(grep -E "^([[:space:]]*export[[:space:]]+)?${key}=" "$file")" || rc=$?
  case "$rc" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  [[ -n "$line" ]] || return 1
  line="$(printf '%s\n' "$line" | tail -n1)"
  line="${line#*=}"
  line="${line%\"}"
  line="${line#\"}"
  printf '%s\n' "$line"
}

env_set() {
  local key="$1" val="$2" file="$3" tmp rc=0
  tmp="$(mktemp "${file}.XXXXXX")" || die "Temp-Datei für ${file} konnte nicht erstellt werden."
  if [[ -f "$file" ]]; then
    grep -vE "^([[:space:]]*export[[:space:]]+)?${key}=" "$file" > "$tmp" || rc=$?
    case "$rc" in
      0|1) ;;
      *) rm -f "$tmp"; die "${file} konnte nicht gelesen werden (Exit ${rc}); keine Änderung geschrieben." ;;
    esac
  fi
  printf '%s="%s"\n' "$key" "$val" >> "$tmp" || { rm -f "$tmp"; die "Schreiben nach ${tmp} fehlgeschlagen."; }
  chmod 600 "$tmp" || { rm -f "$tmp"; die "chmod auf ${tmp} fehlgeschlagen."; }
  mv -f "$tmp" "$file" || { rm -f "$tmp"; die "${file} konnte nicht ersetzt werden."; }
}

gen_hex() { openssl rand -hex 32; }

write_env() {
  local file="$1" pg auth enc db rc=0
  mkdir -p "$(dirname "$file")"
  APP_URL="$(normalize_app_url "${APP_URL:-}")" || exit 1

  rc=0; pg="$(env_get POSTGRES_PASSWORD "$file")" || rc=$?
  case "$rc" in
    0) ;;
    1) pg="" ;;
    *) die "POSTGRES_PASSWORD in ${file} nicht lesbar (Exit ${rc}); keine Secrets neu erzeugt." ;;
  esac
  rc=0; auth="$(env_get AUTH_SECRET "$file")" || rc=$?
  case "$rc" in
    0) ;;
    1) auth="" ;;
    *) die "AUTH_SECRET in ${file} nicht lesbar (Exit ${rc}); keine Secrets neu erzeugt." ;;
  esac
  rc=0; enc="$(env_get ENCRYPTION_SECRET "$file")" || rc=$?
  case "$rc" in
    0) ;;
    1) enc="" ;;
    *) die "ENCRYPTION_SECRET in ${file} nicht lesbar (Exit ${rc}); keine Secrets neu erzeugt." ;;
  esac

  touch "$file"
  chmod 600 "$file"
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
  sed -E 's/^((export[[:space:]]+)?(([A-Za-z_][A-Za-z0-9_]*)?(PASSWORD|SECRET|TOKEN|KEY)[A-Za-z0-9_]*|DATABASE_URL))=.*/\1="***"/' "${APP_DIR}/.env"
}

on_error() {
  local ec="${3:-$?}" line="${1:-?}" cmd="${2:-?}"
  trap - ERR
  if [[ "$cmd" != "die" ]]; then
    msg_error "FEHLER: »${cmd}« in Zeile ${line} (Exit ${ec})."
  fi
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

install_docker() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates openssl >/dev/null
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    msg_ok "Docker und Compose sind bereits vorhanden."
  else
    msg_info "Installiere Docker CE ..."
    curl -fsSL --retry 3 https://get.docker.com | sh
  fi
  systemctl enable --now docker
  docker compose version >/dev/null 2>&1 || die "docker compose Plugin fehlt nach der Installation."
}

install_compose_file() {
  local dst="${APP_DIR}/compose.yml" src="" tmp
  tmp="$(mktemp "${dst}.XXXXXX")" \
    || die "Temporäre compose.yml konnte nicht erstellt werden."
  if [[ -n "$ASSET_DIR" && -s "${ASSET_DIR}/compose.yml" ]]; then
    src="${ASSET_DIR}/compose.yml"
  elif [[ -s "${SCRIPT_DIR}/../compose/compose.yml" ]]; then
    src="${SCRIPT_DIR}/../compose/compose.yml"
  fi
  if [[ -n "$src" ]]; then
    if ! cp "$src" "$tmp"; then
      rm -f "$tmp"
      die "compose.yml konnte nicht aus ${src} kopiert werden."
    fi
  elif ! curl -fsSL --retry 3 -o "$tmp" "${RAW_BASE}/compose/compose.yml"; then
    rm -f "$tmp"
    die "compose.yml konnte nicht geladen werden."
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    die "compose.yml ist leer."
  fi
  if ! ( cd "$APP_DIR" && docker compose -f "$tmp" config -q ); then
    rm -f "$tmp"
    die "compose.yml ist ungültig."
  fi
  if ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$dst"; then
    rm -f "$tmp"
    die "compose.yml konnte nicht installiert werden."
  fi
}

cleanup_unit_stage() {
  local new="$1" tmp="$2" src="$3"
  rm -f "$new"
  [[ "$tmp" == "$src" ]] || rm -f "$tmp"
}

install_unit() {
  local src=""
  local unit="${UNIT_DIR}/${APP_ID}.service" tmp new dir verify_out
  mkdir -p "$UNIT_DIR" || die "Verzeichnis ${UNIT_DIR} konnte nicht erstellt werden."
  if [[ -n "$ASSET_DIR" && -s "${ASSET_DIR}/reactive-resume.service" ]]; then
    src="${ASSET_DIR}/reactive-resume.service"
  else
    src="${SCRIPT_DIR}/../systemd/reactive-resume.service"
  fi
  if [[ -f "$src" ]]; then
    tmp="$src"
  else
    tmp="$(mktemp)"
    if ! curl -fsSL --retry 3 -o "$tmp" "${RAW_BASE}/systemd/reactive-resume.service"; then
      rm -f "$tmp"
      die "systemd-Unit konnte nicht geladen werden."
    fi
  fi
  dir="${APP_DIR//\\/\\\\}"
  dir="${dir//&/\\&}"
  dir="${dir//|/\\|}"
  if ! new="$(mktemp "${unit%.service}.XXXXXX.service")"; then
    [[ "$tmp" == "$src" ]] || rm -f "$tmp"
    die "Temporäre Unit-Datei konnte nicht erstellt werden."
  fi
  if ! sed "s|@APP_DIR@|${dir}|g" "$tmp" > "$new"; then
    cleanup_unit_stage "$new" "$tmp" "$src"
    die "systemd-Unit konnte nicht erzeugt werden."
  fi
  if [[ ! -s "$new" ]]; then
    cleanup_unit_stage "$new" "$tmp" "$src"
    die "systemd-Unit konnte nicht installiert werden."
  fi
  if grep -Eq '@[[:alnum:]_]+@' "$new"; then
    cleanup_unit_stage "$new" "$tmp" "$src"
    die "systemd-Unit enthält unersetzte Platzhalter: ${unit}"
  fi
  if command -v systemd-analyze >/dev/null 2>&1; then
    if ! verify_out="$(systemd-analyze verify "$new" 2>&1)"; then
      printf '%s\n' "$verify_out" >&2
      cleanup_unit_stage "$new" "$tmp" "$src"
      die "systemd-analyze verify ist für ${unit} fehlgeschlagen."
    fi
  fi
  if ! chmod 0644 "$new"; then
    cleanup_unit_stage "$new" "$tmp" "$src"
    die "chmod auf ${unit} fehlgeschlagen."
  fi
  if ! mv -f "$new" "$unit"; then
    cleanup_unit_stage "$new" "$tmp" "$src"
    die "systemd-Unit konnte nicht installiert werden."
  fi
  [[ "$tmp" == "$src" ]] || rm -f "$tmp"
  systemctl daemon-reload
  systemctl enable "$APP_ID" >/dev/null 2>&1 || die "Unit ${APP_ID} konnte nicht aktiviert werden."
}

verify() {
  local code root
  for _ in $(seq 1 90); do
    if systemctl is-active --quiet "$APP_ID"; then
      code="$(curl -s -o /tmp/reactive-resume-health.json -m 5 -w '%{http_code}' \
        "http://127.0.0.1:${APP_PORT}/api/health" 2>/dev/null || true)"
      root="$(curl -s -o /dev/null -m 5 -w '%{http_code}' \
        "http://127.0.0.1:${APP_PORT}/" 2>/dev/null || true)"
      if [[ "$code" == "200" && "$root" =~ ^(200|301|302|303|307|308)$ ]] \
        && grep -Eq '"status"[[:space:]]*:[[:space:]]*"healthy"' /tmp/reactive-resume-health.json; then
        msg_ok "Healthcheck OK (HTTP 200, status healthy); Web-UI HTTP ${root}."
        return 0
      fi
    fi
    sleep 2
  done
  die "Healthcheck fehlgeschlagen (Health: ${code:-000}, Web-UI: ${root:-000}); Dienststatus: $(systemctl is-active "$APP_ID" 2>/dev/null || true)."
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) APP_PORT="$2"; shift 2 ;;
      --app-url) APP_URL="$2"; shift 2 ;;
      --app-image) APP_IMAGE="$2"; shift 2 ;;
      --app-dir) APP_DIR="$2"; shift 2 ;;
      --asset-dir) ASSET_DIR="$2"; shift 2 ;;
      --debug) DEBUG=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unbekannte Option: $1" ;;
    esac
  done

  APP_PORT="$(normalize_port "$APP_PORT")"
  [[ -n "$APP_IMAGE" ]] || die "APP_IMAGE darf nicht leer sein."
  [[ "$(id -u)" == "0" ]] || die "Bitte als root ausführen."

  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -i "$LOG_FILE") 2>&1
  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
  DIAG_READY=1
  if [[ "$DEBUG" == "1" ]]; then set -x; fi

  if [[ -z "$APP_URL" ]]; then
    APP_URL="http://$(detect_ip || die "IP konnte nicht ermittelt werden."):${APP_PORT}"
  fi
  APP_URL="$(normalize_app_url "$APP_URL")"
  msg_info "APP_URL: ${APP_URL}"
  msg_info "APP_IMAGE: ${APP_IMAGE}"
  if ! getent hosts deb.debian.org >/dev/null 2>&1; then
    local ns
    ns="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ' || true)"
    die "DNS-Auflösung fehlgeschlagen (Nameserver: ${ns:-unbekannt}). Installer auf dem Host mit --nameserver <DNS> erneut ausführen."
  fi

  install_docker
  mkdir -p "$APP_DIR"
  chmod 0755 "$APP_DIR"
  local xtrace_on=0
  [[ $- == *x* ]] && xtrace_on=1
  set +x
  write_env "${APP_DIR}/.env"
  if (( xtrace_on )); then set -x; fi
  install_compose_file

  msg_info "Ziehe Images ..."
  ( cd "$APP_DIR" && docker compose pull )

  install_unit

  msg_info "Starte Compose-Stack ..."
  ( cd "$APP_DIR" && docker compose up -d --remove-orphans --wait --wait-timeout 300 )
  systemctl restart "$APP_ID"

  verify

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${APP_PORT}/tcp" >/dev/null 2>&1 || true
    msg_ok "ufw: Port ${APP_PORT}/tcp freigegeben."
  fi

  msg_ok "Reactive Resume läuft unter ${APP_URL}"
}

if [[ "${REACTIVE_RESUME_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"

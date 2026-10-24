#!/usr/bin/env bash
#
# reactive-resume.sh – Proxmox-VE-Installer für Reactive Resume.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main/install/reactive-resume.sh)"
#
# Standard: LXC (Debian 13), 2 vCPU / 4 GB / 16 GB, Port 3000, nächste freie ID.
# Optional: --vm erzeugt eine Ubuntu-24.04-Cloud-Init-VM.
#
REACTIVE_RESUME_LIB_SAVED_OPTS="$(set +o)"
set -Eeuo pipefail

APP="Reactive Resume"
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
APP_ID="reactive-resume"
MODE="lxc"
VMID=""
CT_HOSTNAME="reactive-resume"
CORES=2
RAM_MB=4096
DISK_GB=""
BRIDGE="vmbr0"
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
STORAGE=""
APP_PORT=3000
APP_IMAGE="amruthpillai/reactive-resume:latest"
STATIC_IP=""
GATEWAY=""
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
SSH_KEY_PATH="/root/.ssh/reactive-resume_vm_ed25519"
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
CI_USER="ubuntu"
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
FORCE=0
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
DEBUG=0
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
IP=""
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
WAIT_IP=""
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
ROOT_PW=""
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
CREDS_FILE=""
INSTALLER_REPO="${INSTALLER_REPO:-https://github.com/HatchetMan111/ReactiveResume-Proxmox}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main}"
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
LOG_FILE="/var/log/reactive-resume-proxmox-install.log"
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  # shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
SSH_KEYS_TMP=""
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
INNER_TMP=""
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
SSH_PUB=""
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
SSH_OPTS=()
# shellcheck disable=SC2034 # consumed by Task 6/7 provisioning
CLOUD_IMAGE=""

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

msg_info()  { printf '%s\n' "${C_BLUE}[INFO]${C_RESET}  $*" >&2; }
msg_ok()    { printf '%s\n' "${C_GREEN}[OK]${C_RESET}    $*" >&2; }
msg_warn()  { printf '%s\n' "${C_YELLOW}[WARN]${C_RESET}  $*" >&2; }
msg_error() { printf '%s\n' "${C_RED}[ERROR]${C_RESET} $*" >&2; }
die()       { msg_error "$*"; exit 1; }

usage() {
  cat <<EOF
${APP} – Proxmox VE Installer

Usage: bash reactive-resume.sh [OPTIONEN]

  --vmid ID            Ziel-ID (Default: kleinste freie >= 100)
  --vm                 VM statt LXC erzeugen
  --hostname NAME      Hostname (Default: ${CT_HOSTNAME})
  --cores N            vCPUs (Default: ${CORES})
  --ram, --memory MB   RAM in MiB (Default: ${RAM_MB})
  --disk GB            Disk in GiB (Default: 16 LXC / 20 VM)
  --storage NAME       Proxmox-Storage (Default: automatisch)
  --bridge NAME        Linux-Bridge (Default: ${BRIDGE})
  --port N             Web-UI-Port (Default: ${APP_PORT})
  --image REF          App-Image inkl. Tag (Default: ${APP_IMAGE})
  --ip CIDR            statische IP inkl. Präfix (z. B. 192.168.1.50/24)
  --gw IP              Gateway (nur mit --ip)
  --ssh-key PATH       privater SSH-Key (nur VM)
  --force              fremde/existierende ID überschreiben
  --debug              bash -x + erweiterte Diagnose
  -h, --help           diese Hilfe
EOF
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

is_ipv4() {
  local ip="$1" o
  local -a octets=()
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$ip"
  for o in "${octets[@]}"; do
    (( 10#$o <= 255 )) || return 1
  done
  return 0
}

ct_exists() { pct status "$1" >/dev/null 2>&1; }
vm_exists() { qm status "$1" >/dev/null 2>&1; }

next_free_id() {
  local id=100
  while ct_exists "$id" || vm_exists "$id"; do
    id=$((id + 1))
    (( id <= 999999999 )) || die "Keine freie ID im Bereich 100..999999999 gefunden."
  done
  printf '%s\n' "$id"
}

pick_storage() {
  local content="$1" s c
  local -a cands=()
  mapfile -t cands < <(pvesm status --content "$content" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
  for s in local-lvm local; do
    for c in "${cands[@]}"; do
      if [[ "$c" == "$s" ]]; then
        printf '%s\n' "$s"
        return 0
      fi
    done
  done
  if ((${#cands[@]})); then
    printf '%s\n' "${cands[0]}"
    return 0
  fi
  return 1
}

ensure_template() {
  pveam update >/dev/null 2>&1 || msg_warn "pveam update fehlgeschlagen (offline?)."
  local tmpl tstore
  tmpl="$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E '^debian-13-standard_.*_amd64\.tar\.(zst|gz)$' | sort -V | tail -n1 || true)"
  if [[ -z "$tmpl" ]]; then
    tmpl="$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E '^debian-12-standard_.*_amd64\.tar\.(zst|gz)$' | sort -V | tail -n1 || true)"
  fi
  [[ -n "$tmpl" ]] || die "Kein Debian-Template gefunden (pveam available --section system)."
  tstore="$(pick_storage vztmpl)" || die "Kein Storage für vztmpl gefunden."
  if ! pvesm list "$tstore" --content vztmpl 2>/dev/null | grep -F -- "$tmpl" >/dev/null; then
    msg_info "Lade Template ${tmpl} nach ${tstore} ..."
    pveam download "$tstore" "$tmpl" >&2 || die "Download von ${tmpl} fehlgeschlagen."
  fi
  pvesm path "${tstore}:vztmpl/${tmpl}" || die "Pfad für ${tmpl} nicht ermittelbar."
}

random_password() {
  openssl rand -hex 24
}

need_value() {
  local opt="$1"
  [[ -n "${2:-}" ]] || die "Option ${opt} benötigt einen Wert."
}

on_error() {
  local ec=$? line="$1" cmd="$2"
  trap - ERR
  msg_error "FEHLER: »${cmd}« in Zeile ${line} (Exit ${ec})."
  msg_error "Host-Log: ${LOG_FILE}"
  if [[ -n "${VMID:-}" ]]; then
    if ct_exists "$VMID"; then
      echo "--- pct status/config ---" >&2
      pct status "$VMID" >&2 || true
      pct config "$VMID" 2>&1 | sed -n '1,25p' >&2 || true
      echo "--- Innen-Log (tail 120) ---" >&2
      pct exec "$VMID" -- tail -n 120 /var/log/reactive-resume-install.log 2>&1 || true
      echo "--- Dienststatus ---" >&2
      pct exec "$VMID" -- systemctl status reactive-resume --no-pager -l 2>&1 | tail -n 80 >&2 || true
      echo "--- Compose-Logs (tail 200) ---" >&2
      pct exec "$VMID" -- bash -lc 'cd /opt/reactive-resume && docker compose logs --tail=200' 2>&1 || true
      echo "Diagnose: pct enter ${VMID}" >&2
    elif vm_exists "$VMID"; then
      echo "--- qm status/config ---" >&2
      qm status "$VMID" >&2 || true
      qm config "$VMID" 2>&1 | sed -n '1,25p' >&2 || true
      if [[ -n "${IP:-}" && ${#SSH_OPTS[@]} -gt 0 ]]; then
        echo "--- Innen-Log (tail 120) ---" >&2
        ssh "${SSH_OPTS[@]}" "${CI_USER}@${IP}" 'sudo tail -n 120 /var/log/reactive-resume-install.log' 2>&1 || true
        ssh "${SSH_OPTS[@]}" "${CI_USER}@${IP}" 'sudo systemctl status reactive-resume --no-pager -l | tail -n 80' 2>&1 || true
      fi
      echo "Diagnose: qm terminal ${VMID}" >&2
    fi
  fi
  msg_error "Erneut mit --debug für bash -x: bash reactive-resume.sh --debug"
  exit "$ec"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vmid) need_value "$1" "${2:-}"; VMID="$2"; shift 2 ;;
      --vm) MODE="vm"; shift ;;
      --hostname) need_value "$1" "${2:-}"; CT_HOSTNAME="$2"; shift 2 ;;
      --cores) need_value "$1" "${2:-}"; CORES="$2"; shift 2 ;;
      --ram|--memory) need_value "$1" "${2:-}"; RAM_MB="$2"; shift 2 ;;
      --disk) need_value "$1" "${2:-}"; DISK_GB="$2"; shift 2 ;;
      --storage)
        need_value "$1" "${2:-}"
        # shellcheck disable=SC2034 # consumed by Task 6/7
        STORAGE="$2"
        shift 2
        ;;
      --bridge) need_value "$1" "${2:-}"; BRIDGE="$2"; shift 2 ;;
      --port) need_value "$1" "${2:-}"; APP_PORT="$2"; shift 2 ;;
      --image) need_value "$1" "${2:-}"; APP_IMAGE="$2"; shift 2 ;;
      --ip) need_value "$1" "${2:-}"; STATIC_IP="$2"; shift 2 ;;
      --gw) need_value "$1" "${2:-}"; GATEWAY="$2"; shift 2 ;;
      --ssh-key)
        need_value "$1" "${2:-}"
        # shellcheck disable=SC2034 # consumed by Task 6/7
        SSH_KEY_PATH="$2"
        shift 2
        ;;
      --force)
        # shellcheck disable=SC2034 # consumed by Task 6/7
        FORCE=1
        shift
        ;;
      --debug)
        # shellcheck disable=SC2034 # consumed by Task 6/7
        DEBUG=1
        shift
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unbekannte Option: $1" ;;
    esac
  done
}

validate_config() {
  [[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
  [[ -d /etc/pve ]] || die "/etc/pve fehlt – kein Proxmox-VE-Host?"
  command -v pvesm >/dev/null 2>&1 || die "pvesm nicht gefunden."
  command -v pveam >/dev/null 2>&1 || die "pveam nicht gefunden."
  command -v openssl >/dev/null 2>&1 || die "openssl nicht gefunden."
  command -v curl >/dev/null 2>&1 || die "curl nicht gefunden."
  if [[ "$MODE" == "lxc" ]]; then
    command -v pct >/dev/null 2>&1 || die "pct nicht gefunden."
  else
    command -v qm >/dev/null 2>&1 || die "qm nicht gefunden."
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img nicht gefunden."
    command -v ssh >/dev/null 2>&1 || die "ssh nicht gefunden."
    command -v scp >/dev/null 2>&1 || die "scp nicht gefunden."
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen nicht gefunden."
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum nicht gefunden."
    command -v ping >/dev/null 2>&1 || die "ping nicht gefunden."
  fi
  if [[ -n "$STORAGE" ]]; then
    [[ "$STORAGE" =~ ^[A-Za-z0-9._-]+$ ]] || die "--storage enthält ungültige Zeichen."
    local content_type="rootdir"
    if [[ "$MODE" == "vm" ]]; then
      content_type="images"
    fi
    pvesm status --content "$content_type" 2>/dev/null \
      | awk 'NR>1 && $3=="active" {print $1}' \
      | grep -Fx -- "$STORAGE" >/dev/null \
      || die "Storage ${STORAGE} ist nicht aktiv für ${content_type}."
  fi
  is_uint "$CORES" && (( 10#$CORES >= 1 && 10#$CORES <= 128 )) || die "--cores muss 1..128 sein."
  is_uint "$RAM_MB" && (( 10#$RAM_MB >= 1024 )) || die "--ram muss >= 1024 MiB sein."
  is_uint "$APP_PORT" && (( 10#$APP_PORT >= 1 && 10#$APP_PORT <= 65535 )) || die "--port muss 1..65535 sein."
  [[ ${#CT_HOSTNAME} -le 63 ]] || die "--hostname darf maximal 63 Zeichen haben."
  [[ "$CT_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "--hostname ist kein gültiger DNS-Name."
  [[ "$APP_IMAGE" != -* ]] || die "--image darf nicht mit '-' beginnen."
  [[ "$APP_IMAGE" != *..* ]] || die "--image darf keine '..'-Pfade enthalten."
  [[ "$APP_IMAGE" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*(:[A-Za-z0-9_][A-Za-z0-9._-]*)?$ ]] || die "--image enthält ungültige Zeichen."
  if [[ -n "$VMID" ]]; then
    is_uint "$VMID" && (( 10#$VMID >= 100 )) || die "--vmid muss eine Zahl >= 100 sein."
  fi
  if [[ -z "$DISK_GB" ]]; then
    if [[ "$MODE" == "vm" ]]; then DISK_GB=20; else DISK_GB=16; fi
  fi
  is_uint "$DISK_GB" && (( 10#$DISK_GB >= 4 )) || die "--disk muss >= 4 GiB sein."
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge ${BRIDGE} existiert nicht."
  if [[ -n "$STATIC_IP" || -n "$GATEWAY" ]]; then
    [[ -n "$STATIC_IP" && -n "$GATEWAY" ]] || die "--ip und --gw müssen gemeinsam angegeben werden."
    [[ "$STATIC_IP" == */* ]] || die "--ip erwartet CIDR, z. B. 192.168.1.50/24."
    local ip_part="${STATIC_IP%/*}" prefix="${STATIC_IP##*/}"
    is_ipv4 "$ip_part" || die "--ip enthält keine gültige IPv4-Adresse (Oktette 0..255)."
    is_uint "$prefix" && (( 10#$prefix <= 32 )) || die "--ip Präfix muss 0..32 sein."
    is_ipv4 "$GATEWAY" || die "--gw enthält keine gültige IPv4-Adresse (Oktette 0..255)."
  fi
}

setup_logging() {
  umask 077
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -i "$LOG_FILE") 2>&1
  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
  msg_info "Host-Log: ${LOG_FILE}"
  if [[ "$DEBUG" == "1" ]]; then set -x; fi
}

cleanup() {
  if [[ -n "$SSH_KEYS_TMP" && -f "$SSH_KEYS_TMP" ]]; then rm -f "$SSH_KEYS_TMP"; fi
  if [[ -n "$INNER_TMP" && -f "$INNER_TMP" ]]; then rm -f "$INNER_TMP"; fi
  return 0
}

wait_for_ct() {
  local i
  for i in $(seq 1 60); do
    pct exec "$VMID" -- true >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

detect_ct_ip() {
  local ip=""
  ip="$(pct exec "$VMID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  [[ -n "$ip" ]] || ip="$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  printf '%s\n' "$ip"
}

wait_for_ip() {
  local i ip
  for i in $(seq 1 60); do
    ip="$(detect_ct_ip)"
    if is_ipv4 "$ip" && [[ "$ip" != 169.254.* && "$ip" != 0.0.0.0 ]]; then
      WAIT_IP="$ip"
      return 0
    fi
    sleep 2
  done
  return 1
}

is_ours_ct() {
  local cfg
  cfg="$(pct config "$1" 2>/dev/null || true)"
  grep -Fq -- "${APP} – installiert von" <<< "$cfg" \
    || grep -Fxq -- "hostname: ${CT_HOSTNAME}" <<< "$cfg"
}

ensure_unique_name() {
  local n
  if [[ "$MODE" == "lxc" ]]; then
    n="$(pct list 2>/dev/null | awk 'NR>1 {print $NF}' | grep -x "$CT_HOSTNAME" || true)"
  else
    n="$(qm list 2>/dev/null | awk 'NR>1 {print $2}' | grep -x "$CT_HOSTNAME" || true)"
  fi
  if [[ -n "$n" ]]; then
    msg_warn "Name ${CT_HOSTNAME} ist vergeben – nutze ${CT_HOSTNAME}-${VMID}."
    CT_HOSTNAME="${CT_HOSTNAME}-${VMID}"
    [[ ${#CT_HOSTNAME} -le 63 ]] \
      || die "Hostname ${CT_HOSTNAME} überschreitet 63 Zeichen – bitte --hostname kürzer wählen."
  fi
}

create_lxc() {
  local tmpl net
  local xtrace_on=0
  [[ $- == *x* ]] && xtrace_on=1
  tmpl="$(ensure_template)"
  [[ -n "$STORAGE" ]] || STORAGE="$(pick_storage rootdir)" || die "Kein Storage für rootdir gefunden."
  pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage ${STORAGE} existiert nicht."
  net="ip=dhcp"
  [[ -n "$STATIC_IP" ]] && net="ip=${STATIC_IP},gw=${GATEWAY}"
  msg_info "Erstelle LXC ${VMID} (${CT_HOSTNAME}) auf ${STORAGE} ..."
  pct create "$VMID" "$tmpl" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" --memory "$RAM_MB" --swap 512 \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},${net},firewall=0" \
    --nameserver 1.1.1.1 \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 --onboot 1 \
    --description "${APP} – installiert von ${INSTALLER_REPO}"
  pct start "$VMID"
  wait_for_ct || die "Container ${VMID} bootet nicht (pct exec fehlgeschlagen)."
  CREDS_FILE="/root/reactive-resume-${VMID}.creds"
  set +x
  ROOT_PW="$(random_password)"
  printf 'root:%s\n' "$ROOT_PW" | pct exec "$VMID" -- chpasswd \
    || die "Root-Passwort konnte im Container nicht gesetzt werden."
  install -m 600 /dev/null "$CREDS_FILE"
  {
    echo "${APP} – Zugangsdaten"
    echo "CTID: ${VMID}"
    echo "Root-Passwort: ${ROOT_PW}"
    echo "Konsole: pct enter ${VMID}"
  } > "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  ROOT_PW=""
  if (( xtrace_on )); then set -x; fi
  msg_ok "LXC erstellt. Root-Passwort: ${CREDS_FILE}"
}

update_lxc() {
  local cur add newf
  cur="$(pct config "$VMID" 2>/dev/null | awk -F': ' '/^features:/{print $2}' || true)"
  add=""
  [[ ",$cur," == *",nesting=1,"* ]] || add+="${add:+,}nesting=1"
  [[ ",$cur," == *",keyctl=1,"* ]] || add+="${add:+,}keyctl=1"
  pct set "$VMID" --onboot 1
  if [[ -n "$add" ]]; then
    newf="${cur:+${cur},}${add}"
    pct set "$VMID" --features "$newf"
    if [[ "$(pct status "$VMID" | awk '{print $2}')" == "running" ]]; then
      msg_warn "Features geändert – starte Container neu."
      pct reboot "$VMID"
      wait_for_ct || die "Container ${VMID} nach Feature-Änderung nicht erreichbar."
    fi
  fi
  if [[ "$(pct status "$VMID" | awk '{print $2}')" != "running" ]]; then
    msg_info "Starte bestehenden LXC ${VMID} ..."
    pct start "$VMID"
  fi
  wait_for_ct || die "Bestehender Container ${VMID} ist nicht erreichbar."
}

run_inner() {
  local inner
  local -a args
  if [[ -f "${SCRIPT_DIR}/reactive-resume-inner.sh" ]]; then
    inner="${SCRIPT_DIR}/reactive-resume-inner.sh"
  else
    INNER_TMP="$(mktemp)"
    msg_info "Lade Innenscript aus ${RAW_BASE} ..."
    curl -fsSL --retry 3 -o "$INNER_TMP" "${RAW_BASE}/install/reactive-resume-inner.sh"
    inner="$INNER_TMP"
  fi
  [[ -s "$inner" ]] || die "Innenscript nicht gefunden."
  args=(--port "$APP_PORT" --app-url "http://${IP}:${APP_PORT}" --app-image "$APP_IMAGE")
  [[ "$DEBUG" == "1" ]] && args+=(--debug)

  if [[ "$MODE" == "lxc" ]]; then
    pct push "$VMID" "$inner" /tmp/reactive-resume-inner.sh --perms 700
    if ! pct exec "$VMID" -- bash /tmp/reactive-resume-inner.sh "${args[@]}"; then
      die "Innenscript ist fehlgeschlagen (siehe Diagnose oben)."
    fi
  else
    scp "${SSH_OPTS[@]}" "$inner" "${CI_USER}@${IP}:/tmp/reactive-resume-inner.sh"
    # shellcheck disable=SC2029 # args are shell-quoted here and expanded client-side by design
    if ! ssh "${SSH_OPTS[@]}" "${CI_USER}@${IP}" "sudo bash /tmp/reactive-resume-inner.sh $(printf '%q ' "${args[@]}")"; then
      die "Innenscript ist fehlgeschlagen (siehe Diagnose oben)."
    fi
  fi
}

verify_outer() {
  local i code
  for ((i = 1; i <= 24; i++)); do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${IP}:${APP_PORT}/api/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      msg_ok "Web-UI von außen erreichbar (HTTP 200)."
      return 0
    fi
    sleep 5
  done
  msg_error "Web-UI von außen nicht erreichbar (letzter HTTP-Code: ${code:-000})."
  return 1
}

summary() {
  echo ""
  echo "════════════ ${APP} BEREIT ════════════"
  echo "  Typ         : $([[ "$MODE" == "lxc" ]] && echo LXC || echo VM)"
  echo "  ID          : ${VMID}"
  echo "  Hostname    : ${CT_HOSTNAME}"
  echo "  Ressourcen  : ${CORES} vCPU / ${RAM_MB} MiB RAM / ${DISK_GB} GiB Disk"
  echo "  IP          : ${IP}"
  echo "  Web UI      : http://${IP}:${APP_PORT}/"
  echo "  Health      : http://${IP}:${APP_PORT}/api/health"
  if [[ "$MODE" == "lxc" ]]; then
    echo "  Konsole     : pct enter ${VMID}"
    echo "  Credentials : ${CREDS_FILE:-/root/reactive-resume-${VMID}.creds}"
  else
    echo "  SSH         : ssh -i ${SSH_KEY_PATH} ${CI_USER}@${IP}"
    echo "  Konsole     : qm terminal ${VMID}"
  fi
  echo "  Dienst      : systemctl status ${APP_ID}"
  echo "  Update      : dieses Script mit --vmid ${VMID}$([[ "$MODE" == "vm" ]] && echo ' --vm') erneut ausführen"
  echo "  Reboot-Test : bash tests/reboot-test.sh ${VMID} ${IP} ${APP_PORT}"
  echo "  Entfernen   : $([[ "$MODE" == "lxc" ]] && echo "pct stop ${VMID}; pct destroy ${VMID}" || echo "qm stop ${VMID}; qm destroy ${VMID} --purge")"
  echo "  OpenRouter  : Settings → AI & developer → Add provider → OpenRouter"
  echo "═══════════════════════════════════════"
}

prepare_ssh_key() {
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  if [[ ! -f "$SSH_KEY_PATH" ]]; then
    msg_info "Erzeuge SSH-Key ${SSH_KEY_PATH} ..."
    ssh-keygen -q -t ed25519 -N "" -C "${APP_ID}-proxmox" -f "$SSH_KEY_PATH"
  fi
  grep -q '^ssh-' "$SSH_KEY_PATH" 2>/dev/null && die "--ssh-key erwartet einen privaten Key."
  chmod 600 "$SSH_KEY_PATH"
  SSH_PUB="$(ssh-keygen -y -P "" -f "$SSH_KEY_PATH" </dev/null)" \
    || die "Konnte keinen Public Key aus ${SSH_KEY_PATH} lesen (Passphrase?)."
  [[ "$SSH_PUB" == ssh-* ]] || die "Ungültiger Public Key aus ${SSH_KEY_PATH}."
  SSH_OPTS=(
    -i "$SSH_KEY_PATH"
    -o IdentitiesOnly=yes
    -o PreferredAuthentications=publickey
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5
    -o BatchMode=yes
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=20
  )
}

ensure_cloud_image() {
  local arch="amd64" codename="noble" name url sums_url sums expected
  [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
  name="${codename}-server-cloudimg-${arch}.img"
  url="https://cloud-images.ubuntu.com/${codename}/current/${name}"
  CLOUD_IMAGE="/var/lib/vz/template/iso/${name}"
  install -d -m 0755 "$(dirname "$CLOUD_IMAGE")"
  if [[ ! -s "$CLOUD_IMAGE" ]]; then
    msg_info "Lade Ubuntu 24.04 Cloud-Image ..."
    rm -f "${CLOUD_IMAGE}.part"
    if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 -o "${CLOUD_IMAGE}.part" "$url"; then
      rm -f "${CLOUD_IMAGE}.part"
      die "Download des Cloud-Images fehlgeschlagen: ${url}"
    fi
    sums_url="https://cloud-images.ubuntu.com/${codename}/current/SHA256SUMS"
    if ! sums="$(curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 "$sums_url")"; then
      rm -f "${CLOUD_IMAGE}.part"
      die "Download der Prüfsummen fehlgeschlagen: ${sums_url}"
    fi
    expected="$(printf '%s\n' "$sums" | awk -v n="$name" '$2 == n || $2 == "*" n {print $1; exit}')"
    if [[ -z "$expected" ]]; then
      rm -f "${CLOUD_IMAGE}.part"
      die "SHA256-Eintrag für ${name} nicht gefunden."
    fi
    if ! printf '%s  %s\n' "$expected" "${CLOUD_IMAGE}.part" | sha256sum -c - >/dev/null 2>&1; then
      rm -f "${CLOUD_IMAGE}.part"
      die "SHA256-Prüfsumme für ${name} stimmt nicht."
    fi
    mv "${CLOUD_IMAGE}.part" "$CLOUD_IMAGE"
  else
    msg_ok "Cloud-Image vorhanden: ${CLOUD_IMAGE}"
  fi
  qemu-img info "$CLOUD_IMAGE" >/dev/null 2>&1 || die "Cloud-Image ist ungültig."
}

create_vm() {
  local import_out disk net
  ensure_cloud_image
  prepare_ssh_key
  [[ -n "$STORAGE" ]] || STORAGE="$(pick_storage images)" || die "Kein Storage für VM-Images gefunden."
  pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage ${STORAGE} existiert nicht."
  net="ip=dhcp"
  [[ -n "$STATIC_IP" ]] && net="ip=${STATIC_IP},gw=${GATEWAY}"

  msg_info "Erstelle VM ${VMID} (${CT_HOSTNAME}) ..."
  qm create "$VMID" \
    --name "$CT_HOSTNAME" \
    --ostype l26 \
    --cpu host \
    --sockets 1 --cores "$CORES" \
    --memory "$RAM_MB" --balloon 0 \
    --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=${BRIDGE},firewall=0" \
    --agent enabled=1 \
    --serial0 socket \
    --vga std \
    --onboot 1 \
    --description "${APP} – installiert von ${INSTALLER_REPO}"

  if ! import_out="$(qm importdisk "$VMID" "$CLOUD_IMAGE" "$STORAGE" 2>&1)"; then
    printf '%s\n' "$import_out" >&2
    die "qm importdisk für VM ${VMID} fehlgeschlagen."
  fi
  printf '%s\n' "$import_out"
  disk="$(qm config "$VMID" | awk -F': ' '/^unused0:/ {print $2}')"
  if [[ -z "$disk" ]]; then
    disk="$(printf '%s\n' "$import_out" | sed -n "s/.*as '\([^']*\)'.*/\1/p" | tail -n1 | sed -E 's/^unused[0-9]+://')"
  fi
  [[ -n "$disk" ]] || die "Importierte Disk konnte nicht ermittelt werden."

  qm set "$VMID" --scsi0 "${disk},discard=on,ssd=1"
  qm disk resize "$VMID" scsi0 "${DISK_GB}G"
  qm set "$VMID" --boot "order=scsi0"
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"

  SSH_KEYS_TMP="$(mktemp)"
  chmod 600 "$SSH_KEYS_TMP"
  printf '%s\n' "$SSH_PUB" > "$SSH_KEYS_TMP"
  qm set "$VMID" --ciuser "$CI_USER"
  qm set "$VMID" --sshkeys "$SSH_KEYS_TMP"
  rm -f "$SSH_KEYS_TMP"; SSH_KEYS_TMP=""
  qm set "$VMID" --ipconfig0 "$net"
  qm set "$VMID" --nameserver "1.1.1.1 9.9.9.9"
  qm set "$VMID" --ciupgrade 0

  qm start "$VMID"
  msg_ok "VM gestartet."
}

update_vm() {
  qm config "$VMID" | grep -q '^scsi0:' \
    || die "VM ${VMID} ist unvollständig (kein scsi0). Mit 'qm destroy ${VMID} --purge' neu beginnen."
  qm config "$VMID" | grep -q '^ide2:.*cloudinit' \
    || die "VM ${VMID} ist unvollständig (keine Cloud-Init-Disk). Mit 'qm destroy ${VMID} --purge' neu beginnen."
  qm set "$VMID" --onboot 1
  if [[ -n "$STATIC_IP" ]]; then
    qm set "$VMID" --ipconfig0 "ip=${STATIC_IP},gw=${GATEWAY}"
    qm cloudinit update "$VMID" >/dev/null || die "Cloud-Init-Update für ${VMID} fehlgeschlagen."
    if [[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]]; then
      msg_warn "IP-Konfiguration geändert – starte VM neu."
      qm reboot "$VMID"
    fi
  fi
  if [[ "$(qm status "$VMID" | awk '{print $2}')" != "running" ]]; then
    msg_info "Starte bestehende VM ${VMID} ..."
    qm start "$VMID"
  fi
  prepare_ssh_key
}

is_ours_vm() {
  local cfg
  cfg="$(qm config "$1" 2>/dev/null || true)"
  grep -Fq -- "description: ${APP} – installiert von" <<< "$cfg" \
    || grep -Fxq -- "name: ${CT_HOSTNAME}" <<< "$cfg"
}

agent_ping() {
  timeout 10 qm agent "$VMID" ping >/dev/null 2>&1
}

detect_vm_ip() {
  local json ip mac
  if agent_ping; then
    json="$(timeout 20 qm guest cmd "$VMID" network-get-interfaces 2>/dev/null || true)"
  else
    json=""
  fi
  if [[ -n "$json" ]] && command -v python3 >/dev/null 2>&1; then
    ip="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for iface in data:
    name = iface.get("name", "")
    if name == "lo" or name.startswith(("docker", "br-", "veth", "virbr", "tun", "tap")):
        continue
    for addr in iface.get("ip-addresses", []):
        if addr.get("ip-address-type") == "ipv4":
            v = addr.get("ip-address", "")
            if v and not v.startswith(("127.", "169.254.")):
                print(v)
                sys.exit(0)
sys.exit(1)
' 2>/dev/null || true)"
    if [[ -n "$ip" ]] && is_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi
  mac="$(qm config "$VMID" 2>/dev/null | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -n1 || true)"
  if [[ -n "$mac" ]]; then
    ip="$(ip neigh show dev "$BRIDGE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | grep -v '^169\.254\.' | head -n1 || true)"
    if [[ -n "$ip" ]] && is_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi
  return 1
}

sweep_bridge() {
  local subnet i
  local -a pids=()
  subnet="$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | awk 'NR==1 {print $4}' | cut -d/ -f1 | cut -d. -f1-3 || true)"
  [[ "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  for i in $(seq 1 254); do
    ping -n -c1 -W1 "${subnet}.${i}" >/dev/null 2>&1 &
    pids+=("$!")
  done
  ((${#pids[@]})) && { wait "${pids[@]}" 2>/dev/null || true; }
  return 0
}

wait_vm_ssh() {
  local deadline=$((SECONDS + 600)) i=0 candidate
  while (( SECONDS < deadline )); do
    i=$((i + 1))
    if (( i == 1 || i % 12 == 0 )); then sweep_bridge; fi
    candidate="$(detect_vm_ip 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      WAIT_IP="$candidate"
    else
      WAIT_IP=""
    fi
    if [[ -n "${WAIT_IP:-}" ]] && ssh "${SSH_OPTS[@]}" "${CI_USER}@${WAIT_IP}" true >/dev/null 2>&1; then
      return 0
    fi
    if (( i % 6 == 0 )); then
      msg_info "  ... warte auf SSH (${i}, ${SECONDS}s/600s, IP: ${WAIT_IP:-?})"
    fi
    sleep 5
  done
  return 1
}

wait_for_vm_ip() {
  wait_vm_ssh
}

main() {
  local exists=0
  parse_args "$@"
  validate_config
  setup_logging
  trap cleanup EXIT

  if [[ -z "$VMID" ]]; then
    VMID="$(next_free_id)"
  fi
  msg_info "Ziel-ID: ${VMID} (Modus: ${MODE})"

  if ct_exists "$VMID"; then
    [[ "$MODE" == "lxc" ]] || die "ID ${VMID} ist ein LXC; nutze ohne --vm."
    if [[ "$FORCE" != "1" ]] && ! is_ours_ct "$VMID"; then
      die "ID ${VMID} gehört nicht zu ${APP}. Mit --force überschreiben."
    fi
    exists=1
    msg_info "Aktualisiere bestehenden LXC ${VMID} ..."
    update_lxc
  elif vm_exists "$VMID"; then
    [[ "$MODE" == "vm" ]] || die "ID ${VMID} ist eine VM; nutze --vm."
    if [[ "$FORCE" != "1" ]] && ! is_ours_vm "$VMID"; then
      die "ID ${VMID} gehört nicht zu ${APP}. Mit --force überschreiben."
    fi
    exists=1
    msg_info "Aktualisiere bestehende VM ${VMID} ..."
    update_vm
  else
    ensure_unique_name
    if [[ "$MODE" == "lxc" ]]; then
      create_lxc
    else
      create_vm
    fi
  fi

  if [[ "$MODE" == "lxc" ]]; then
    wait_for_ip || die "Keine IPv4-Adresse im Container ${VMID} gefunden."
    IP="$WAIT_IP"
  else
    wait_for_vm_ip \
      || die "VM ${VMID} nicht per SSH erreichbar (Ziel: ${CI_USER}@<vm-ip>, Key: ${SSH_KEY_PATH})."
    IP="$WAIT_IP"
  fi
  msg_ok "IP: ${IP}"

  run_inner
  verify_outer || die "Verifikation von außen fehlgeschlagen."
  summary
  msg_ok "Installation abgeschlossen (bestehend: ${exists})."
}

if [[ "${REACTIVE_RESUME_LIB_ONLY:-0}" == "1" ]]; then
  eval "$REACTIVE_RESUME_LIB_SAVED_OPTS"
  return 0 2>/dev/null || exit 0
fi

main "$@"

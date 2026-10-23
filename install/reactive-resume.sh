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
  local rc=$?
  trap - ERR
  msg_error "FEHLER in ${BASH_SOURCE[0]}:${BASH_LINENO[0]} (rc=${rc}): ${BASH_COMMAND}"
  exit "$rc"
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
  if [[ "$MODE" == "lxc" ]]; then
    command -v pct >/dev/null 2>&1 || die "pct nicht gefunden."
  else
    command -v qm >/dev/null 2>&1 || die "qm nicht gefunden."
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img nicht gefunden."
    command -v ssh >/dev/null 2>&1 || die "ssh nicht gefunden."
    command -v scp >/dev/null 2>&1 || die "scp nicht gefunden."
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

if [[ "${REACTIVE_RESUME_LIB_ONLY:-0}" == "1" ]]; then
  eval "$REACTIVE_RESUME_LIB_SAVED_OPTS"
  return 0 2>/dev/null || exit 0
fi

# Rest folgt in Task 6/7
main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac
  die "noch nicht implementiert"
}

trap 'on_error' ERR
main "$@"

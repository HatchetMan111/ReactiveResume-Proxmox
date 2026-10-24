#!/usr/bin/env bash
#
# reboot-test.sh – prüft Installation, Reboot und erneute Erreichbarkeit.
#
#   bash tests/reboot-test.sh <ID> [IP] [PORT]
#
set -Eeuo pipefail

ID="${1:-}"
IP="${2:-}"
PORT="${3:-3000}"
APP_ID="reactive-resume"
TYPE=""

SSH_KEY="${SSH_KEY_PATH:-/root/.ssh/reactive-resume_vm_ed25519}"
# Host-Key-Prüfung bewusst aus: der Test spricht einen Wegwerf-Gast an, dessen
# Host-Key sich beim Neuaufsetzen ändert; IdentitiesOnly begrenzt den Key.
SSH_OPTS=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey
          -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5)

die() { echo "FEHLER: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: reboot-test.sh <ID> [IP] [PORT]

Umgebung:
  SSH_KEY_PATH=<pfad>  privater SSH-Key für VM (Default: /root/.ssh/reactive-resume_vm_ed25519)
  REBOOT_TEST_FORCE=1  überspringt nur die Ownership-Prüfung
EOF
  exit 1
}

is_ipv4() {
  local ip="$1" o
  local -a octets=()
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$ip"
  for o in "${octets[@]}"; do
    (( 10#$o <= 255 )) || return 1
  done
  return 0
}

[[ -n "$ID" ]] || usage
[[ "$ID" =~ ^[0-9]+$ ]] || die "ID muss numerisch sein."
[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT muss numerisch sein."
(( 10#$PORT >= 1 && 10#$PORT <= 65535 )) || die "PORT muss zwischen 1 und 65535 liegen."
PORT=$((10#$PORT))
if [[ -n "$IP" ]]; then
  is_ipv4 "$IP" || die "IP '${IP}' ist keine gültige IPv4-Adresse."
fi

if pct status "$ID" >/dev/null 2>&1; then
  TYPE="lxc"
elif qm status "$ID" >/dev/null 2>&1; then
  TYPE="vm"
else
  die "ID ${ID} ist weder LXC noch VM."
fi

if [[ "$TYPE" == "vm" ]]; then
  [[ -r "$SSH_KEY" ]] || die "SSH-Key ${SSH_KEY} nicht lesbar (VM-Modus)."
fi

run_in() {
  local ip="$1" cmd="$2"
  if [[ "$TYPE" == "lxc" ]]; then
    pct exec "$ID" -- bash -lc "$cmd"
  else
    printf '%s\n' "$cmd" | ssh "${SSH_OPTS[@]}" "ubuntu@${ip}" 'sudo bash -s'
  fi
}

boot_marker() {
  local ip="$1"
  if [[ "$TYPE" == "lxc" ]]; then
    run_in "$ip" "awk '{print \$22}' /proc/1/stat"
  else
    run_in "$ip" "cat /proc/sys/kernel/random/boot_id"
  fi
}

detect_ip() {
  local json="" ip="" mac=""
  if [[ "$TYPE" == "lxc" ]]; then
    pct exec "$ID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
  else
    json="$(timeout 20 qm guest cmd "$ID" network-get-interfaces 2>/dev/null || true)"
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
    mac="$(qm config "$ID" 2>/dev/null | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -n1 || true)"
    if [[ -n "$mac" ]]; then
      ip="$(ip neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | grep -v '^169\.254\.' | head -n1 || true)"
      if [[ -n "$ip" ]] && is_ipv4 "$ip"; then
        printf '%s\n' "$ip"
        return 0
      fi
    fi
  fi
}

is_ours() {
  local ip="$1" cfg="" guest_hostname=""
  if [[ "$TYPE" == "lxc" ]]; then
    cfg="$(pct config "$ID" 2>/dev/null || true)"
    if grep -Fq -- "description: Reactive Resume – installiert von" <<< "$cfg"; then return 0; fi
    if grep -Fxq 'hostname: reactive-resume' <<< "$cfg"; then return 0; fi
    guest_hostname="$(run_in "$ip" 'hostname' 2>/dev/null || true)"
    [[ "$guest_hostname" == "reactive-resume" ]]
    return
  fi
  cfg="$(qm config "$ID" 2>/dev/null || true)"
  if grep -Fq -- "description: Reactive Resume – installiert von" <<< "$cfg"; then return 0; fi
  if grep -Fxq 'name: reactive-resume' <<< "$cfg"; then return 0; fi
  return 1
}

check_all() {
  local phase="$1" ip="$2" code health app_url app_url_rc=0
  echo "--- ${phase}: Status ---"
  if [[ "$TYPE" == "lxc" ]]; then
    pct status "$ID"
    pct config "$ID" | grep -E '^(onboot|features|hostname):' || true
  else
    qm status "$ID"
    qm config "$ID" | grep -E '^(onboot|name):' || true
  fi

  echo "--- ${phase}: systemd ---"
  run_in "$ip" "systemctl is-active ${APP_ID}" || die "Dienst ${APP_ID} nicht aktiv."
  run_in "$ip" "systemctl status ${APP_ID} --no-pager -l | tail -n 20"

  echo "--- ${phase}: Compose ---"
  run_in "$ip" "cd /opt/reactive-resume && docker compose ps"

  echo "--- ${phase}: Health lokal ---"
  health="$(run_in "$ip" "curl -fsS -m 5 http://127.0.0.1:${PORT}/api/health")" \
    || die "Lokaler Health-Check fehlgeschlagen."
  printf '%s\n' "$health"
  printf '%s\n' "$health" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"healthy"' \
    || die "Health-Antwort ohne status=healthy."

  echo "--- ${phase}: Web-UI lokal ---"
  root="$(run_in "$ip" "curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:${PORT}/" || true)"
  echo "HTTP ${root}"
  [[ "$root" =~ ^(200|302)$ ]] || die "Lokale Web-UI lieferte HTTP ${root:-?} statt 200/302."

  echo "--- ${phase}: Health von außen (${ip}) ---"
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${ip}:${PORT}/api/health" || true)"
  echo "HTTP ${code}"
  [[ "$code" == "200" ]] || die "Externer Health-Check lieferte HTTP ${code:-?} statt 200."

  echo "--- ${phase}: Web-UI von außen (${ip}) ---"
  root="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${ip}:${PORT}/" || true)"
  echo "HTTP ${root}"
  [[ "$root" =~ ^(200|302)$ ]] || die "Externe Web-UI lieferte HTTP ${root:-?} statt 200/302."

  echo "--- ${phase}: APP_URL ---"
  app_url="$(run_in "$ip" "grep '^APP_URL=' /opt/reactive-resume/.env" 2>/dev/null)" \
    || app_url_rc=$?
  if (( app_url_rc != 0 )); then
    echo "WARNUNG: APP_URL konnte nicht gelesen werden." >&2
  else
    printf '%s\n' "$app_url"
    if [[ "$app_url" != "APP_URL=\"http://${ip}:${PORT}\"" ]]; then
      echo "WARNUNG: APP_URL passt nicht zur aktuellen IP ${ip}. Login kann fehlschlagen." >&2
    fi
  fi
}

echo "== Vor dem Reboot =="
if [[ "$TYPE" == "vm" ]]; then
  detected="$(detect_ip || true)"
  if [[ -n "$IP" ]]; then
    if [[ -z "$detected" ]]; then
      echo "WARNUNG: IP ${IP} konnte nicht an VM ${ID} gebunden werden (keine erkannte IP)." >&2
    elif [[ "$detected" != "$IP" ]]; then
      die "IP ${IP} gehört nicht zu VM ${ID} (erkannt: ${detected})."
    fi
  else
    IP="$detected"
  fi
  [[ -n "$IP" ]] || die "IP nicht ermittelbar; bitte als Argument angeben."
else
  [[ -n "$IP" ]] || IP="$(detect_ip || true)"
  [[ -n "$IP" ]] || die "IP nicht ermittelbar; bitte als Argument angeben."
fi
last_notified_ip="$IP"

if [[ "${REBOOT_TEST_FORCE:-0}" != "1" ]] && ! is_ours "$IP"; then
  die "ID ${ID} gehört nicht zu Reactive Resume (Marker/Hostname fehlt). Mit REBOOT_TEST_FORCE=1 überschreibbar."
fi

check_all "vorher" "$IP"
OLD_MARKER="$(boot_marker "$IP" 2>/dev/null || true)"
[[ -n "$OLD_MARKER" ]] || die "Neustart-Marker vor Reboot nicht lesbar."
echo "Neustart-Marker vor Reboot: ${OLD_MARKER}"

echo "== Reboot =="
if [[ "$TYPE" == "lxc" ]]; then
  pct reboot "$ID" || die "pct reboot ${ID} fehlgeschlagen."
else
  qm reboot "$ID" || die "qm reboot ${ID} fehlgeschlagen."
fi

echo "== Nach dem Reboot =="
NEW_IP=""
NEW_MARKER=""
DEADLINE=$((SECONDS + 600))
while ((SECONDS < DEADLINE)); do
  detected="$(detect_ip || true)"
  if [[ -n "$detected" ]]; then
    if [[ "$detected" != "$last_notified_ip" ]]; then
      prev="$last_notified_ip"
      echo "HINWEIS: IP hat sich geändert: ${prev} -> ${detected}"
      last_notified_ip="$detected"
    fi
    NEW_IP="$detected"
  fi
  probe_ip="${NEW_IP:-$IP}"
  NEW_MARKER="$(boot_marker "$probe_ip" 2>/dev/null || true)"
  if [[ -n "$NEW_MARKER" && "$NEW_MARKER" != "$OLD_MARKER" ]]; then
    IP="$probe_ip"
    break
  fi
  if [[ "$TYPE" == "lxc" ]]; then sleep 2; else sleep 5; fi
done
[[ -n "$NEW_MARKER" && "$NEW_MARKER" != "$OLD_MARKER" ]] \
  || die "Reboot nicht nachweisbar: Neustart-Marker blieb innerhalb von 600s unverändert."
echo "Neustart-Marker nach Reboot: ${NEW_MARKER}"

code=""
DEADLINE=$((SECONDS + 300))
while ((SECONDS < DEADLINE)); do
  detected="$(detect_ip || true)"
  if [[ -n "$detected" ]]; then
    if [[ "$detected" != "$last_notified_ip" ]]; then
      prev="$last_notified_ip"
      echo "HINWEIS: IP hat sich geändert: ${prev} -> ${detected}"
      last_notified_ip="$detected"
    fi
    IP="$detected"
  fi
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${IP}:${PORT}/api/health" || true)"
  [[ "$code" == "200" ]] && break
  sleep 2
done
[[ "$code" == "200" ]] || die "Health nach Reboot nicht 200 (letzter HTTP ${code:-?})."
check_all "nachher" "$IP"

echo "== Reboot-Test bestanden =="

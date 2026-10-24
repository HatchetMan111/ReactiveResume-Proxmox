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

[[ -n "$ID" ]] || { echo "Usage: $0 <ID> [IP] [PORT]" >&2; exit 1; }

if pct status "$ID" >/dev/null 2>&1; then
  TYPE="lxc"
elif qm status "$ID" >/dev/null 2>&1; then
  TYPE="vm"
else
  echo "FEHLER: ID ${ID} ist weder LXC noch VM." >&2
  exit 1
fi

run_in() {
  if [[ "$TYPE" == "lxc" ]]; then
    pct exec "$ID" -- bash -lc "$1"
  else
    printf '%s\n' "$1" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 "ubuntu@${IP}" 'sudo bash -s'
  fi
}

detect_ip() {
  if [[ "$TYPE" == "lxc" ]]; then
    pct exec "$ID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
  else
    timeout 20 qm guest cmd "$ID" network-get-interfaces 2>/dev/null | \
      grep -oE '"ip-address"[[:space:]]*:[[:space:]]*"[0-9.]+"' | \
      grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -vE '^(127\.|169\.254\.)' | head -n1
  fi
}

check_all() {
  local phase="$1" ip="$2" code
  echo "--- ${phase}: Status ---"
  if [[ "$TYPE" == "lxc" ]]; then
    pct status "$ID"
    pct config "$ID" | grep -E '^(onboot|features|hostname):'
  else
    qm status "$ID"
    qm config "$ID" | grep -E '^(onboot|name):'
  fi

  echo "--- ${phase}: systemd ---"
  run_in "systemctl is-active ${APP_ID}"
  run_in "systemctl status ${APP_ID} --no-pager -l | tail -n 20"

  echo "--- ${phase}: Compose ---"
  run_in "cd /opt/reactive-resume && docker compose ps"

  echo "--- ${phase}: Health lokal ---"
  run_in "curl -fsS http://127.0.0.1:${PORT}/api/health"

  echo "--- ${phase}: Health von außen (${ip}) ---"
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${ip}:${PORT}/api/health" || true)"
  echo "HTTP ${code}"
  [[ "$code" == "200" ]] || return 1

  echo "--- ${phase}: APP_URL ---"
  run_in "grep '^APP_URL=' /opt/reactive-resume/.env"
  if ! run_in "grep -q '^APP_URL=\"http://${ip}:${PORT}\"' /opt/reactive-resume/.env"; then
    echo "WARNUNG: APP_URL passt nicht zur aktuellen IP ${ip}. Login kann fehlschlagen." >&2
  fi
}

echo "== Vor dem Reboot =="
[[ -n "$IP" ]] || IP="$(detect_ip || true)"
[[ -n "$IP" ]] || { echo "FEHLER: IP nicht ermittelbar; bitte als Argument angeben." >&2; exit 1; }
check_all "vorher" "$IP"

echo "== Reboot =="
if [[ "$TYPE" == "lxc" ]]; then
  pct reboot "$ID"
  for _ in $(seq 1 60); do pct exec "$ID" -- true >/dev/null 2>&1 && break; sleep 2; done
else
  qm reboot "$ID"
  for _ in $(seq 1 120); do
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
      "ubuntu@${IP}" true >/dev/null 2>&1 && break
    sleep 5
  done
fi

echo "== Nach dem Reboot =="
NEW_IP="$(detect_ip || true)"
[[ -n "$NEW_IP" ]] || NEW_IP="$IP"
[[ "$NEW_IP" == "$IP" ]] || echo "HINWEIS: IP hat sich geändert: ${IP} -> ${NEW_IP}"
for _ in $(seq 1 90); do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${NEW_IP}:${PORT}/api/health" || true)"
  [[ "$code" == "200" ]] && break
  sleep 2
done
IP="$NEW_IP"
check_all "nachher" "$NEW_IP"

echo "== Reboot-Test bestanden =="

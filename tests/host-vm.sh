#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/install/reactive-resume.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"

cat > "$TMP/bin/ip" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"route show default"* ]]; then
  printf 'default via 192.0.2.254 dev vmbr0\n'
  exit 0
fi
printf '2: vmbr0    inet 192.0.2.1/24 brd 192.0.2.255 scope global vmbr0\\       valid_lft forever preferred_lft forever\n'
STUB

cat > "$TMP/bin/ping" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

chmod +x "$TMP/bin/ip" "$TMP/bin/ping"

PATH="$TMP/bin:${PATH}" timeout 10 bash -c '
  set -Eeuo pipefail
  export REACTIVE_RESUME_LIB_ONLY=1
  source "$1"
  BRIDGE=vmbr0
  exec > >(tee -i /dev/null) 2>&1
  sweep_bridge
' _ "$SCRIPT" || fail "sweep_bridge blockiert mit process substitution (timeout 10)"

PATH="$TMP/bin:${PATH}" REACTIVE_RESUME_LIB_ONLY=1 bash -c '
  source "$1"
  for fn in detect_nameservers wait_for_vm_ip guest_resolves_dns ensure_guest_dns; do
    declare -F "$fn" >/dev/null || { echo "missing $fn" >&2; exit 1; }
  done
' _ "$SCRIPT" || fail "Host-Funktionen fehlen"

printf 'nameserver 127.0.0.53\nnameserver 10.1.2.3\nnameserver 10.1.2.3\n' > "$TMP/resolv.conf"
GOT="$(PATH="$TMP/bin:${PATH}" REACTIVE_RESUME_LIB_ONLY=1 RESOLV_CONF="$TMP/resolv.conf" bash -c '
  source "$1"
  detect_nameservers
' _ "$SCRIPT")"
[[ "$GOT" == "10.1.2.3 " ]] || fail "detect_nameservers filtert Loopback/Duplikate nicht: ${GOT}"

GOT="$(PATH="$TMP/bin:${PATH}" REACTIVE_RESUME_LIB_ONLY=1 RESOLV_CONF="$TMP/missing" SYSTEMD_RESOLV_CONF="$TMP/missing-systemd" bash -c '
  source "$1"
  GATEWAY=192.0.2.254
  detect_nameservers
' _ "$SCRIPT")"
[[ "$GOT" == "192.0.2.254 " ]] || fail "Gateway-Fallback fehlt: ${GOT}"

mkdir -p "$TMP/noip"
cat > "$TMP/noip/ip" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMP/noip/ip"
GOT="$(PATH="$TMP/noip:${PATH}" REACTIVE_RESUME_LIB_ONLY=1 RESOLV_CONF="$TMP/missing" SYSTEMD_RESOLV_CONF="$TMP/missing-systemd" bash -c '
  source "$1"
  GATEWAY=""
  detect_nameservers
' _ "$SCRIPT")"
[[ "$GOT" == "1.1.1.1 " ]] || fail "1.1.1.1-Fallback fehlt: ${GOT}"

printf 'host-vm: PASS\n'

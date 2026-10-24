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

printf 'host-vm: PASS\n'

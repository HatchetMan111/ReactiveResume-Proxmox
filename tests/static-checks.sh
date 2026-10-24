#!/usr/bin/env bash
#
# static-checks.sh – Syntax-, Struktur- und Vertragsprüfung ohne Proxmox.
#
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
ok()  { printf '\033[32m[PASS]\033[0m %s\n' "$*"; }
bad() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=1; }
check(){ local d="$1" out; shift; if out="$("$@" 2>&1)"; then ok "$d"; else bad "$d"; printf '%s\n' "$out" >&2; fi; }

cd "$ROOT"

TMP_PATHS=()
cleanup() {
  local p
  if ((${#TMP_PATHS[@]})); then
    for p in "${TMP_PATHS[@]}"; do rm -rf -- "$p"; done
  fi
}
trap cleanup EXIT

echo "== Dateien =="
FILES=(install/reactive-resume.sh install/reactive-resume-inner.sh systemd/reactive-resume.service compose/compose.yml tests/static-checks.sh tests/inner-functions.sh tests/host-vm.sh tests/compose-contract.sh)
if [[ -f README.md ]]; then FILES+=(README.md); else echo "[SKIP] README.md folgt in Task 10"; fi
if [[ -f tests/reboot-test.sh ]]; then FILES+=(tests/reboot-test.sh); else echo "[SKIP] tests/reboot-test.sh folgt in Task 9"; fi
for f in "${FILES[@]}"; do
  check "${f} vorhanden" test -s "$f"
done

echo "== Syntax =="
SCRIPTS=(install/reactive-resume.sh install/reactive-resume-inner.sh)
for f in tests/*.sh; do
  [[ -e "$f" ]] || continue
  SCRIPTS+=("$f")
done
for f in "${SCRIPTS[@]}"; do
  check "bash -n ${f}" bash -n "$f"
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "== ShellCheck =="
  check "shellcheck (warning)" shellcheck -S warning "${SCRIPTS[@]}"
else
  echo "== ShellCheck übersprungen =="
fi

echo "== Rechte =="
for f in "${SCRIPTS[@]}"; do
  check "${f} ausführbar" test -x "$f"
done

echo "== Compose =="
if command -v docker >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  check "compose-contract" bash tests/compose-contract.sh
else
  echo "[SKIP] compose-contract (docker oder jq fehlt)"
fi

echo "== systemd-Unit =="
check "Restart=always" grep -q '^Restart=always$' systemd/reactive-resume.service
check "WantedBy=multi-user.target" grep -q '^WantedBy=multi-user.target$' systemd/reactive-resume.service
check "After=network-online.target docker.service" grep -q '^After=network-online.target docker.service$' systemd/reactive-resume.service
check "Requires=docker.service" grep -q '^Requires=docker.service$' systemd/reactive-resume.service
check "Platzhalter @APP_DIR@" grep -q '@APP_DIR@' systemd/reactive-resume.service
UNIT_TMP="$(mktemp)"; TMP_PATHS+=("$UNIT_TMP")
sed 's|@APP_DIR@|/opt/reactive-resume|g' systemd/reactive-resume.service > "$UNIT_TMP"
check "keine Platzhalter nach Substitution" bash -c "! grep -q '@[A-Z_]*@' '$UNIT_TMP'"

echo "== Host-Installer =="
check "pct create" grep -q 'pct create' install/reactive-resume.sh
check "onboot 1" grep -q -- '--onboot 1' install/reactive-resume.sh
check "nesting/keyctl" grep -q 'nesting=1,keyctl=1' install/reactive-resume.sh
check "qm importdisk" grep -q 'qm importdisk' install/reactive-resume.sh
check "Cloud-Init ciuser" grep -q -- '--ciuser' install/reactive-resume.sh
check "naechste freie ID" grep -q 'next_free_id' install/reactive-resume.sh
check "--vm Option" grep -q -- '--vm' install/reactive-resume.sh
check "Update-Modus" grep -q 'Aktualisiere bestehenden' install/reactive-resume.sh
check "Fehlerkette Innen-Log" grep -q 'Innen-Log' install/reactive-resume.sh
check "next_free_id wird aufgerufen" grep -Fq 'VMID="$(next_free_id)"' install/reactive-resume.sh
check "run_inner wird aufgerufen" grep -q '^  run_inner$' install/reactive-resume.sh
if help_host="$(env -u REACTIVE_RESUME_LIB_ONLY bash install/reactive-resume.sh --help 2>&1)" \
   && [[ "$help_host" == *"Usage:"* && "$help_host" == *"--vmid"* ]]; then ok "Hilfe Host"; else bad "Hilfe Host"; printf '%s\n' "${help_host:-}" >&2; fi

echo "== Innenscript =="
check "docker compose pull" grep -q 'docker compose pull' install/reactive-resume-inner.sh
check "docker compose up" grep -q 'docker compose up' install/reactive-resume-inner.sh
check "compose up flags" grep -Fq 'docker compose up -d --remove-orphans --wait --wait-timeout 300' install/reactive-resume-inner.sh
check "ENCRYPTION_SECRET" grep -q 'ENCRYPTION_SECRET' install/reactive-resume-inner.sh
check "AUTH_SECRET" grep -q 'AUTH_SECRET' install/reactive-resume-inner.sh
check "api/health" grep -q '/api/health' install/reactive-resume-inner.sh
check "systemctl enable" grep -q 'systemctl enable' install/reactive-resume-inner.sh
check "write_env wird aufgerufen" grep -Fq 'write_env "${APP_DIR}/.env"' install/reactive-resume-inner.sh
check "keine Klartext-Secrets im Log" bash -c "! grep -qE 'echo .*AUTH_SECRET=' install/reactive-resume-inner.sh"
if help_inner="$(env -u REACTIVE_RESUME_LIB_ONLY bash install/reactive-resume-inner.sh --help 2>&1)" \
   && [[ "$help_inner" == *"Usage:"* && "$help_inner" == *"--app-dir"* ]]; then ok "Hilfe Innen"; else bad "Hilfe Innen"; printf '%s\n' "${help_inner:-}" >&2; fi

echo "== Unit-Tests =="
ENV_TEST="$(mktemp)"; TMP_PATHS+=("$ENV_TEST")
cat > "$ENV_TEST" <<'EOT'
set -Eeuo pipefail
export REACTIVE_RESUME_LIB_ONLY=1
source install/reactive-resume-inner.sh
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
APP_DIR="$tmp"
APP_URL=http://10.0.0.5:3000; APP_PORT=3000; APP_IMAGE=img:1
write_env "$APP_DIR/.env"
a="$(env_get AUTH_SECRET "$APP_DIR/.env")"
e="$(env_get ENCRYPTION_SECRET "$APP_DIR/.env")"
p="$(env_get POSTGRES_PASSWORD "$APP_DIR/.env")"
db="$(env_get DATABASE_URL "$APP_DIR/.env")"
[[ -n "$a" && -n "$e" && -n "$p" ]]
[[ "$a" != "$e" ]]
[[ "$(stat -c '%a' "$APP_DIR/.env")" == "600" ]]
[[ "$db" == *"$p"* ]]
APP_URL=http://10.0.0.6:3000
write_env "$APP_DIR/.env"
[[ "$a" == "$(env_get AUTH_SECRET "$APP_DIR/.env")" ]]
[[ "$e" == "$(env_get ENCRYPTION_SECRET "$APP_DIR/.env")" ]]
[[ "$p" == "$(env_get POSTGRES_PASSWORD "$APP_DIR/.env")" ]]
[[ "$db" == "$(env_get DATABASE_URL "$APP_DIR/.env")" ]]
[[ "$(env_get APP_URL "$APP_DIR/.env")" == "http://10.0.0.6:3000" ]]
[[ "$(normalize_app_url http://10.0.0.5:3000/)" == "http://10.0.0.5:3000" ]]
redacted="$(redact_env)"
[[ "$redacted" == *'AUTH_SECRET="***"'* ]]
[[ "$redacted" != *"$a"* ]]
[[ "$redacted" != *"$e"* ]]
[[ "$redacted" != *"$p"* ]]
[[ "$redacted" != *"postgres:${p}@"* ]]
EOT
check "write_env erhaelt Secrets, APP_URL aktualisiert" bash "$ENV_TEST"

mock="$(mktemp -d)"; TMP_PATHS+=("$mock")
printf '#!/bin/sh\n[ "$1" = status ] && [ "${2:-0}" -lt 105 ] && exit 0\nexit 1\n' > "$mock/pct"
printf '#!/bin/sh\nexit 1\n' > "$mock/qm"
chmod +x "$mock/pct" "$mock/qm"
if GOT="$(PATH="$mock:$PATH" REACTIVE_RESUME_LIB_ONLY=1 bash -c 'source install/reactive-resume.sh; next_free_id' 2>&1)"; then
  check "next_free_id ueberspringt belegte IDs" test "$GOT" = "105"
else
  bad "next_free_id ueberspringt belegte IDs"
  printf '%s\n' "$GOT" >&2
fi

echo "== Hermetische Tests =="
check "inner-functions" bash tests/inner-functions.sh
check "host-vm" bash tests/host-vm.sh

echo "== Ergebnis =="
if [[ "$FAIL" == "0" ]]; then
  printf '\033[32mAlle Checks bestanden.\033[0m\n'
else
  printf '\033[31mMindestens ein Check fehlgeschlagen.\033[0m\n'
  exit 1
fi

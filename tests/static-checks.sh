#!/usr/bin/env bash
#
# static-checks.sh – Syntax-, Struktur- und Vertragsprüfung ohne Proxmox.
#
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
ok()  { printf '\033[32m[PASS]\033[0m %s\n' "$*"; }
bad() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=1; }
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

cd "$ROOT"

echo "== Dateien =="
FILES=(install/reactive-resume.sh install/reactive-resume-inner.sh systemd/reactive-resume.service compose/compose.yml tests/static-checks.sh)
if [[ -f README.md ]]; then FILES+=(README.md); else echo "[SKIP] README.md folgt in Task 10"; fi
if [[ -f tests/reboot-test.sh ]]; then FILES+=(tests/reboot-test.sh); else echo "[SKIP] tests/reboot-test.sh folgt in Task 9"; fi
for f in "${FILES[@]}"; do
  check "${f} vorhanden" test -s "$f"
done

echo "== Syntax =="
SCRIPTS=(install/reactive-resume.sh install/reactive-resume-inner.sh tests/static-checks.sh)
if [[ -f tests/reboot-test.sh ]]; then SCRIPTS+=(tests/reboot-test.sh); fi
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
if docker compose version >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  cp compose/compose.yml "$tmp/"
  printf 'POSTGRES_PASSWORD=test\nPORT=3000\nAPP_IMAGE=amruthpillai/reactive-resume:latest\n' > "$tmp/.env"
  check "docker compose config" bash -c "cd '$tmp' && docker compose config -q"
  rm -rf "$tmp"
else
  echo "== Docker Compose nicht verfügbar, übersprungen =="
fi

echo "== systemd-Unit =="
check "Restart=always" grep -q '^Restart=always$' systemd/reactive-resume.service
check "WantedBy=multi-user.target" grep -q '^WantedBy=multi-user.target$' systemd/reactive-resume.service
check "After=network-online.target docker.service" grep -q '^After=network-online.target docker.service$' systemd/reactive-resume.service
check "Requires=docker.service" grep -q '^Requires=docker.service$' systemd/reactive-resume.service
check "Platzhalter @APP_DIR@" grep -q '@APP_DIR@' systemd/reactive-resume.service
UNIT_TMP="$(mktemp)"
sed 's|@APP_DIR@|/opt/reactive-resume|g' systemd/reactive-resume.service > "$UNIT_TMP"
check "keine Platzhalter nach Substitution" bash -c "! grep -q '@[A-Z_]*@' '$UNIT_TMP'"
rm -f "$UNIT_TMP"

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
check "Hilfe laeuft" bash install/reactive-resume.sh --help

echo "== Innenscript =="
check "docker compose pull" grep -q 'docker compose pull' install/reactive-resume-inner.sh
check "docker compose up" grep -q 'docker compose up' install/reactive-resume-inner.sh
check "ENCRYPTION_SECRET" grep -q 'ENCRYPTION_SECRET' install/reactive-resume-inner.sh
check "AUTH_SECRET" grep -q 'AUTH_SECRET' install/reactive-resume-inner.sh
check "api/health" grep -q '/api/health' install/reactive-resume-inner.sh
check "systemctl enable" grep -q 'systemctl enable' install/reactive-resume-inner.sh
check "Hilfe laeuft" bash install/reactive-resume-inner.sh --help
check "keine Klartext-Secrets im Log" bash -c "! grep -qE 'echo .*AUTH_SECRET=' install/reactive-resume-inner.sh"

echo "== Unit-Tests =="
ENV_TEST="$(mktemp)"
cat > "$ENV_TEST" <<'EOT'
set -Eeuo pipefail
export REACTIVE_RESUME_LIB_ONLY=1
source install/reactive-resume-inner.sh
tmp="$(mktemp -d)"
APP_URL=http://10.0.0.5:3000; APP_PORT=3000; APP_IMAGE=img:1
write_env "$tmp/.env"
a="$(env_get AUTH_SECRET "$tmp/.env")"
e="$(env_get ENCRYPTION_SECRET "$tmp/.env")"
p="$(env_get POSTGRES_PASSWORD "$tmp/.env")"
APP_URL=http://10.0.0.6:3000
write_env "$tmp/.env"
[[ "$a" == "$(env_get AUTH_SECRET "$tmp/.env")" ]]
[[ "$e" == "$(env_get ENCRYPTION_SECRET "$tmp/.env")" ]]
[[ "$p" == "$(env_get POSTGRES_PASSWORD "$tmp/.env")" ]]
[[ "$(env_get APP_URL "$tmp/.env")" == "http://10.0.0.6:3000" ]]
[[ "$(normalize_app_url http://10.0.0.5:3000/)" == "http://10.0.0.5:3000" ]]
EOT
check "write_env erhaelt Secrets, APP_URL aktualisiert" bash "$ENV_TEST"
rm -f "$ENV_TEST"

mock="$(mktemp -d)"
printf '#!/bin/sh\n[ "$1" = status ] && [ "${2:-0}" -lt 105 ] && exit 0\nexit 1\n' > "$mock/pct"
printf '#!/bin/sh\nexit 1\n' > "$mock/qm"
chmod +x "$mock/pct" "$mock/qm"
GOT="$(PATH="$mock:$PATH" REACTIVE_RESUME_LIB_ONLY=1 bash -c 'source install/reactive-resume.sh; next_free_id')"
check "next_free_id ueberspringt belegte IDs" test "$GOT" = "105"
rm -rf "$mock"

echo "== Ergebnis =="
if [[ "$FAIL" == "0" ]]; then
  printf '\033[32mAlle Checks bestanden.\033[0m\n'
else
  printf '\033[31mMindestens ein Check fehlgeschlagen.\033[0m\n'
  exit 1
fi

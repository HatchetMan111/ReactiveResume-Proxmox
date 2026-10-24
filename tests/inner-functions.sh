#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/install/reactive-resume-inner.sh"
UNIT_SOURCE="${ROOT}/systemd/reactive-resume.service"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_fn() { declare -F "$1" >/dev/null || fail "Funktion fehlt: $1"; }

REACTIVE_RESUME_LIB_ONLY=1
export REACTIVE_RESUME_LIB_ONLY
# shellcheck source=../install/reactive-resume-inner.sh
source "$SCRIPT"
export SCRIPT_DIR

for fn in write_env install_docker install_compose_file install_unit verify main; do
  assert_fn "$fn"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG_FILE="$TMP/install.log"
export LOG_FILE

mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$TMP/bin/systemd-analyze" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/systemctl" "$TMP/bin/systemd-analyze" "$TMP/bin/docker"
export PATH="$TMP/bin:${PATH}"

APP_DIR="$TMP/app\\slash & pipe|x"

# Valid unit: placeholder substitution, no leftovers, atomic install.
UNIT_DIR="$TMP/unit-ok"
mkdir -p "$UNIT_DIR" "$TMP/ok/install" "$TMP/ok/systemd"
cp "$UNIT_SOURCE" "$TMP/ok/systemd/reactive-resume.service"
SCRIPT_DIR="$TMP/ok/install"
install_unit
installed="${UNIT_DIR}/${APP_ID}.service"
[[ -f "$installed" ]] || fail "gültige Unit wurde nicht installiert: $installed"
grep -Fq "WorkingDirectory=${APP_DIR}" "$installed" || fail "APP_DIR wurde nicht korrekt ersetzt"
if grep -Eq '@[[:alnum:]_]+@' "$installed"; then
  fail "installierte Unit enthält unersetzte Platzhalter"
fi

# Invalid unit: extra placeholder must fail closed, without installing anything.
UNIT_DIR="$TMP/unit-bad"
mkdir -p "$UNIT_DIR" "$TMP/bad/install" "$TMP/bad/systemd"
cp "$UNIT_SOURCE" "$TMP/bad/systemd/reactive-resume.service"
printf 'X-Unsubstituted=@FOO@\n' >> "$TMP/bad/systemd/reactive-resume.service"
SCRIPT_DIR="$TMP/bad/install"
if ( install_unit ) 2>/dev/null; then
  fail "install_unit hätte bei unersetztem Platzhalter fehlschlagen müssen"
fi
[[ ! -e "$UNIT_DIR/${APP_ID}.service" ]] || fail "fehlerhafte Unit wurde installiert"
if compgen -G "${UNIT_DIR}/${APP_ID}.*.service" >/dev/null; then
  fail "temporäre Unit-Datei wurde nicht aufgeräumt"
fi

# mv failure: staged temp must be removed even when the final move fails.
UNIT_DIR="$TMP/unit-mv"
mkdir -p "$UNIT_DIR" "$TMP/mv/install" "$TMP/mv/systemd" "$TMP/failbin"
cp "$UNIT_SOURCE" "$TMP/mv/systemd/reactive-resume.service"
cat > "$TMP/failbin/mv" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMP/failbin/mv"
SCRIPT_DIR="$TMP/mv/install"
if ( PATH="$TMP/failbin:${PATH}" install_unit ) 2>/dev/null; then
  fail "install_unit hätte bei mv-Fehler fehlschlagen müssen"
fi
if compgen -G "${UNIT_DIR}/${APP_ID}.*.service" >/dev/null; then
  fail "temporäre Unit-Datei blieb nach mv-Fehler zurück"
fi

# Compose: local asset is preferred and installed atomically.
COMPOSE_SOURCE="${ROOT}/compose/compose.yml"
mkdir -p "$TMP/assets" "$TMP/app-compose"
cp "$COMPOSE_SOURCE" "$TMP/assets/compose.yml"
printf 'old\n' > "$TMP/app-compose/compose.yml"
mkdir -p "$TMP/curl-unused"
cat > "$TMP/curl-unused/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl-called\n' > "$TMP/curl-called"
exit 1
STUB
chmod +x "$TMP/curl-unused/curl"
APP_DIR="$TMP/app-compose"
# shellcheck disable=SC2034 # consumed by sourced installer
ASSET_DIR="$TMP/assets"
SCRIPT_DIR="$TMP/no-local-assets"
if ! ( PATH="$TMP/curl-unused:${PATH}" install_compose_file ); then
  fail "install_compose_file hätte lokale Assets verwenden müssen"
fi
cmp -s "$COMPOSE_SOURCE" "$TMP/app-compose/compose.yml" || fail "lokale compose.yml wurde nicht installiert"
[[ ! -e "$TMP/curl-called" ]] || fail "curl wurde trotz lokaler Assets aufgerufen"

# Compose: failed download must not overwrite the existing compose.yml.
mkdir -p "$TMP/app-partial" "$TMP/curl-bad"
printf 'old\n' > "$TMP/app-partial/compose.yml"
cat > "$TMP/curl-bad/curl" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then printf 'partial\n' > "$2"; shift 2; else shift; fi
done
exit 1
STUB
chmod +x "$TMP/curl-bad/curl"
APP_DIR="$TMP/app-partial"
# shellcheck disable=SC2034 # consumed by sourced installer
ASSET_DIR=""
SCRIPT_DIR="$TMP/no-local-assets"
if ( PATH="$TMP/curl-bad:${PATH}" install_compose_file ) 2>/dev/null; then
  fail "install_compose_file hätte bei Download-Fehler fehlschlagen müssen"
fi
grep -qx 'old' "$TMP/app-partial/compose.yml" || fail "alter compose.yml wurde bei Download-Fehler überschrieben"
if compgen -G "$TMP/app-partial/compose.yml.*" >/dev/null; then
  fail "temporäre compose.yml blieb nach Download-Fehler zurück"
fi

# Compose: invalid local file must fail closed and preserve the existing file.
mkdir -p "$TMP/app-invalid" "$TMP/bad-docker"
printf 'old\n' > "$TMP/app-invalid/compose.yml"
cat > "$TMP/bad-docker/docker" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMP/bad-docker/docker"
APP_DIR="$TMP/app-invalid"
# shellcheck disable=SC2034 # consumed by sourced installer
ASSET_DIR="$TMP/assets"
if ( PATH="$TMP/bad-docker:${PATH}" install_compose_file ) 2>/dev/null; then
  fail "install_compose_file hätte bei ungültiger compose.yml fehlschlagen müssen"
fi
grep -qx 'old' "$TMP/app-invalid/compose.yml" || fail "alter compose.yml wurde bei Validierungsfehler überschrieben"

printf 'inner-functions: PASS\n'

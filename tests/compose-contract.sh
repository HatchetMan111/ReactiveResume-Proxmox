#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compose_file="$repo_root/compose/compose.yml"

if [[ ! -f "$compose_file" ]]; then
  echo "FAIL: missing $compose_file" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "FAIL: docker not found" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq not found" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$compose_file" "$tmp/compose.yml"
cat > "$tmp/.env" <<'EOF'
POSTGRES_PASSWORD=test-password
PORT=8080
APP_IMAGE=amruthpillai/reactive-resume:latest
APP_URL=http://localhost:3000
DATABASE_URL=postgresql://postgres:test-password@postgres:5432/postgres
AUTH_SECRET=test-auth-secret
ENCRYPTION_SECRET=test-encryption-secret
EOF

compose() {
  ( cd "$tmp" && env -u POSTGRES_PASSWORD -u PORT -u APP_IMAGE -u APP_URL -u DATABASE_URL -u AUTH_SECRET -u ENCRYPTION_SECRET docker compose "$@" )
}

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

if ! config_json=$(compose config --format json 2>"$tmp/config.err"); then
  echo "FAIL: docker compose config exited non-zero" >&2
  cat "$tmp/config.err" >&2
  exit 1
fi

if jq -e '(.services.postgres.ports // []) | length == 0' >/dev/null <<<"$config_json"; then
  pass "postgres publishes no ports"
else
  fail "postgres must not publish ports"
fi

published=$(jq -r '.services["reactive-resume"].ports[0].published | tostring' <<<"$config_json")
target=$(jq -r '.services["reactive-resume"].ports[0].target | tostring' <<<"$config_json")
if [[ "$published" == "8080" && "$target" == "3000" ]]; then
  pass "app publishes host PORT 8080 -> container 3000"
else
  fail "expected app port 8080:3000, got ${published}:${target}"
fi

container_port=$(jq -r '.services["reactive-resume"].environment.PORT // "<unset>"' <<<"$config_json")
if [[ "$container_port" == "3000" ]]; then
  pass "app container PORT is 3000 despite .env PORT=8080"
else
  fail "expected app container PORT=3000, got ${container_port}"
fi

if jq -e 'any(.services.postgres.volumes[]?; .target == "/var/lib/postgresql")' >/dev/null <<<"$config_json"; then
  pass "postgres volume targets /var/lib/postgresql"
else
  fail "postgres volume must target /var/lib/postgresql"
fi

if jq -e '.volumes | has("postgres_data") and has("reactive_resume_data")' >/dev/null <<<"$config_json"; then
  pass "named volumes postgres_data and reactive_resume_data exist"
else
  fail "both named volumes must exist"
fi

if jq -e '.services.postgres.healthcheck.test | length > 0' >/dev/null <<<"$config_json"; then
  pass "postgres healthcheck exists"
else
  fail "postgres healthcheck must exist"
fi

negative_dir=$(mktemp -d)
cp "$compose_file" "$negative_dir/compose.yml"
cat > "$negative_dir/.env" <<'EOF'
PORT=3000
APP_IMAGE=amruthpillai/reactive-resume:latest
EOF
if ( cd "$negative_dir" && env -u POSTGRES_PASSWORD docker compose config -q ) >/dev/null 2>"$negative_dir/err"; then
  fail "missing POSTGRES_PASSWORD must make config fail"
else
  pass "missing POSTGRES_PASSWORD fails closed"
fi
rm -rf "$negative_dir"

if [[ "$failures" -ne 0 ]]; then
  printf '%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi

echo "All compose contract assertions passed."

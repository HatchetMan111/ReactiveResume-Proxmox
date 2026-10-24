#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

REACTIVE_RESUME_LIB_ONLY=1
export REACTIVE_RESUME_LIB_ONLY
# shellcheck source=../install/reactive-resume.sh
source "$ROOT/install/reactive-resume.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PCT_LOG="$TMP/pct.log"
: > "$PCT_LOG"
pct() { printf '%s\n' "$*" >> "$PCT_LOG"; }

# shellcheck disable=SC2034 # consumed by run_inner
MODE="lxc"
# shellcheck disable=SC2034 # consumed by run_inner
VMID="999"
# shellcheck disable=SC2034 # consumed by run_inner
IP="192.0.2.10"
# shellcheck disable=SC2034 # consumed by run_inner
APP_PORT="3000"
# shellcheck disable=SC2034 # consumed by run_inner
APP_IMAGE="example/image:test"
# shellcheck disable=SC2034 # consumed by run_inner
DEBUG=0
run_inner

grep -Fq "push 999 ${ROOT}/install/reactive-resume-inner.sh /tmp/reactive-resume-inner.sh --perms 700" "$PCT_LOG" \
  || fail "Innenscript wurde nicht in den LXC übertragen"
grep -Fq "push 999 ${ROOT}/compose/compose.yml /tmp/reactive-resume-assets/compose.yml --perms 644" "$PCT_LOG" \
  || fail "compose.yml wurde nicht als lokales Asset übertragen"
grep -Fq "push 999 ${ROOT}/systemd/reactive-resume.service /tmp/reactive-resume-assets/reactive-resume.service --perms 644" "$PCT_LOG" \
  || fail "systemd-Unit wurde nicht als lokales Asset übertragen"
grep -Fq -- "--asset-dir /tmp/reactive-resume-assets" "$PCT_LOG" \
  || fail "Innenscript erhielt kein --asset-dir"

: > "$PCT_LOG"
# shellcheck disable=SC2034 # consumed by run_inner
MODE="vm"
# shellcheck disable=SC2034 # consumed by run_inner
IP="192.0.2.11"
# shellcheck disable=SC2034 # consumed by run_inner
CI_USER="ubuntu"
# shellcheck disable=SC2034 # consumed by run_inner
SSH_OPTS=()
scp() { printf '%s\n' "$*" >> "$PCT_LOG"; }
ssh() { printf '%s\n' "$*" >> "$PCT_LOG"; }
run_inner

grep -Fq "reactive-resume-inner.sh ubuntu@192.0.2.11:/tmp/reactive-resume-inner.sh" "$PCT_LOG" \
  || fail "Innenscript wurde nicht in die VM übertragen"
grep -Fq "mkdir -p '/tmp/reactive-resume-assets'" "$PCT_LOG" \
  || fail "Asset-Verzeichnis wurde in der VM nicht angelegt"
grep -Fq "compose.yml ubuntu@192.0.2.11:/tmp/reactive-resume-assets/compose.yml" "$PCT_LOG" \
  || fail "compose.yml wurde nicht in die VM übertragen"
grep -Fq "reactive-resume.service ubuntu@192.0.2.11:/tmp/reactive-resume-assets/reactive-resume.service" "$PCT_LOG" \
  || fail "systemd-Unit wurde nicht in die VM übertragen"
grep -Fq -- "--asset-dir /tmp/reactive-resume-assets" "$PCT_LOG" \
  || fail "VM-Innenscript erhielt kein --asset-dir"

printf 'host-assets: PASS\n'

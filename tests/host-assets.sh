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
mkdir_line="$(grep -nF "mkdir -p '/tmp/reactive-resume-assets'" "$PCT_LOG" | cut -d: -f1)"
compose_line="$(grep -nF "compose.yml ubuntu@192.0.2.11:/tmp/reactive-resume-assets/compose.yml" "$PCT_LOG" | cut -d: -f1)"
unit_line="$(grep -nF "reactive-resume.service ubuntu@192.0.2.11:/tmp/reactive-resume-assets/reactive-resume.service" "$PCT_LOG" | cut -d: -f1)"
[[ -n "$mkdir_line" ]] || fail "Asset-Verzeichnis wurde in der VM nicht angelegt"
[[ -n "$compose_line" ]] || fail "compose.yml wurde nicht in die VM übertragen"
[[ -n "$unit_line" ]] || fail "systemd-Unit wurde nicht in die VM übertragen"
(( mkdir_line < compose_line && mkdir_line < unit_line )) \
  || fail "Asset-Verzeichnis wurde erst nach den Asset-Transfers angelegt"
grep -Fq -- "--asset-dir /tmp/reactive-resume-assets" "$PCT_LOG" \
  || fail "VM-Innenscript erhielt kein --asset-dir"

: > "$PCT_LOG"
# shellcheck disable=SC2034 # consumed by ensure_guest_dns
MODE="lxc"
# shellcheck disable=SC2034 # consumed by ensure_guest_dns
VMID="999"
# shellcheck disable=SC2034 # consumed by ensure_guest_dns
NAMESERVERS="10.1.2.3 10.1.2.4"
pct() {
  printf '%s\n' "$*" >> "$PCT_LOG"
  if [[ "$1" == "set" ]]; then return 0; fi
  if [[ "$1" == "exec" ]]; then
    shift 2
    [[ "${1:-}" == "--" ]] && shift
    case "$*" in
      *getent*) [[ -f "$TMP/dns-ok" ]] ;;
      *"cat > /etc/resolv.conf"*) cat > "$TMP/resolv.conf"; touch "$TMP/dns-ok" ;;
      *) return 0 ;;
    esac
  fi
}
ensure_guest_dns
grep -qx 'nameserver 10.1.2.3' "$TMP/resolv.conf" || fail "primärer DNS fehlt in resolv.conf"
grep -qx 'nameserver 10.1.2.4' "$TMP/resolv.conf" || fail "sekundärer DNS fehlt in resolv.conf"
grep -Fq "set 999 --nameserver 10.1.2.3 10.1.2.4" "$PCT_LOG" \
  || fail "Nameserver wurde nicht in der LXC-Config gesetzt"

# Working DNS without an explicit override: no config churn.
: > "$PCT_LOG"
# shellcheck disable=SC2034 # consumed by ensure_guest_dns
NAMESERVERS="10.1.2.3"
# shellcheck disable=SC2034 # consumed by ensure_guest_dns
NAMESERVER_OPT=""
guest_resolves_dns_retry() { return 0; }
ensure_guest_dns
[[ ! -s "$PCT_LOG" ]] || fail "ensure_guest_dns hat bei funktionierendem DNS unnötig geschrieben"

# Explicit override is applied even when DNS already works.
guest_resolves_dns_retry() { return 0; }
# shellcheck disable=SC2034 # consumed by ensure_guest_dns
NAMESERVERS="10.9.9.9"
# shellcheck disable=SC2034 # consumed by ensure_guest_dns
NAMESERVER_OPT="10.9.9.9"
ensure_guest_dns
grep -Fq "set 999 --nameserver 10.9.9.9" "$PCT_LOG" \
  || fail "expliziter --nameserver wurde bei funktionierendem DNS ignoriert"

# DNS still broken after writing must fail closed.
# shellcheck disable=SC2034 # consumed by ensure_guest_dns
NAMESERVERS="10.1.2.3"
# shellcheck disable=SC2034 # consumed by ensure_guest_dns
NAMESERVER_OPT=""
guest_resolves_dns_retry() { return 1; }
if ( ensure_guest_dns ) 2>/dev/null; then
  fail "ensure_guest_dns hätte bei weiterhin fehlgeschlagenem DNS abbrechen müssen"
fi

printf 'host-assets: PASS\n'

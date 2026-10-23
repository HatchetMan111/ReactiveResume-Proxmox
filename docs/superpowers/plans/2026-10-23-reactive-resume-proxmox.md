# Reactive Resume Proxmox Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein Community-Scripts-Stil-Einzeiler, der auf Proxmox VE einen LXC (Default) oder eine VM erzeugt und Reactive Resume v6 mit Docker Compose, systemd und optionaler OpenRouter-Nutzung reboot-fest installiert.

**Architecture:** Ein Host-Script erzeugt den Gast (LXC via `pct`, VM via `qm` + Cloud-Init), ermittelt die IP und ruft ein gemeinsames In-Guest-Script auf. Das In-Guest-Script installiert Docker, schreibt `compose.yml`/`.env`, startet die Compose-Services über eine systemd-Unit und verifiziert `/api/health`. Beide Scripts sind eigenständig, idempotent und mit vollständiger ERR-Diagnosekette ausgestattet.

**Tech Stack:** Bash 5, Proxmox VE (`pct`, `qm`, `pveam`, `pvesm`), Debian 13 LXC, Ubuntu 24.04 Cloud-Init-VM, Docker CE + Compose v2, PostgreSQL 18, Reactive Resume (`amruthpillai/reactive-resume`), systemd.

**Spec:** `docs/superpowers/specs/2026-10-23-reactive-resume-proxmox-design.md`

## Global Constraints

- Alle Scripts beginnen mit `set -Eeuo pipefail`; Host- und Innenscript haben einen `ERR`-Trap mit vollständiger Diagnosekette.
- Kein Secret (OpenRouter-Key, `AUTH_SECRET`, `ENCRYPTION_SECRET`, DB-Passwort) wird geloggt oder als Script-Argument verlangt.
- Standardressourcen LXC: 2 vCPU / 4096 MiB / 16 GiB; VM: 2 vCPU / 4096 MiB / 20 GiB.
- Standardport 3000; `APP_URL` muss exakt die öffentliche URL ohne trailing slash sein.
- `AUTH_SECRET` und `ENCRYPTION_SECRET` sind verschieden und werden bei Updates niemals neu erzeugt.
- Die Ziel-ID ist die kleinste freie ID ≥ 100; CT- und VM-IDs werden gemeinsam geprüft.
- `onboot: 1` bzw. `--onboot 1` ist Pflicht; der Dienst läuft mit `Restart=always`.
- PostgreSQL wird nie nach außen veröffentlicht; nur `${PORT}:3000` wird gebunden.
- Der Container/VM wird bei Fehlern nicht automatisch gelöscht.
- Verifikation gilt nur bei `systemctl is-active` = active **und** HTTP 200 von `/api/health`; sonst Exit ≠ 0.
- Kein TLS/Reverse-Proxy im Scope; README dokumentiert die Einschränkung.
- In der Entwicklungssandbox gibt es kein `pct`/`qm`; dort laufen `bash -n`, `shellcheck`, `docker compose config` und die statischen Checks. Der echte Reboot-Test erfolgt auf dem Proxmox-Host.

## Review Focus

1. **ID-Kollision:** Eine belegte CT- oder VM-ID darf ohne `--force` nicht überschrieben werden; die nächste freie ID muss beide Typen berücksichtigen. Test: gemockte `pct`/`qm` in Task 5.
2. **DHCP-IP-Wechsel:** Nach Reboot mit neuer IP muss der Login weiter funktionieren oder die Korrektur dokumentiert sein. Test: Reboot-Test prüft `APP_URL` gegen die aktuelle IP (Task 9).
3. **Update ohne Datenverlust:** Ein zweiter Lauf darf Secrets, DB-Passwort und Volumes nicht verändern. Test: `write_env`-Erhaltungstest in Task 8.
4. **Docker im unprivilegierten LXC:** Fehlendes `nesting`/`keyctl` muss zu einer klaren Fehlerkette führen, nicht zu einem stillen Fehlschlag. Test: Feature-Checks in Task 6 und Diagnose-Assertions in Task 8.
5. **Falscher Erfolg:** Port belegt oder Postgres unhealthy darf nicht als Erfolg gemeldet werden. Test: Health-Gate in Task 4/7 und Assertions in Task 8.

---

### Task 1: Repo-Skelett und Compose-Datei

**Files:**
- Create: `compose/compose.yml`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: Compose-Service `postgres` und `reactive-resume`; Umgebungsvariablen `POSTGRES_PASSWORD`, `PORT`, `APP_IMAGE`.

- [ ] **Step 1: Fehlenden Test ausführen**

```bash
tmp=$(mktemp -d)
cp compose/compose.yml "$tmp/" 2>/dev/null || true
printf 'POSTGRES_PASSWORD=test\nPORT=3000\nAPP_IMAGE=amruthpillai/reactive-resume:latest\n' > "$tmp/.env"
( cd "$tmp" && docker compose config -q )
```

Erwartung: FAIL, weil `compose/compose.yml` noch fehlt.

- [ ] **Step 2: `compose/compose.yml` schreiben**

```yaml
services:
  postgres:
    image: postgres:18
    restart: unless-stopped
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
    volumes:
      - postgres_data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 10

  reactive-resume:
    image: ${APP_IMAGE:-amruthpillai/reactive-resume:latest}
    restart: unless-stopped
    ports:
      - "${PORT:-3000}:3000"
    env_file:
      - .env
    volumes:
      - reactive_resume_data:/app/data
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  postgres_data:
  reactive_resume_data:
```

- [ ] **Step 3: Test erneut ausführen**

```bash
tmp=$(mktemp -d)
cp compose/compose.yml "$tmp/"
printf 'POSTGRES_PASSWORD=test\nPORT=3000\nAPP_IMAGE=amruthpillai/reactive-resume:latest\n' > "$tmp/.env"
( cd "$tmp" && docker compose config -q )
```

Erwartung: PASS (Exit 0, keine Ausgabe).

- [ ] **Step 4: `.gitignore` schreiben**

```gitignore
*.log
.env
.superpowers/
```

- [ ] **Step 5: Commit**

```bash
git add compose/compose.yml .gitignore
git commit -m "feat: add reactive resume compose stack"
```

---

### Task 2: systemd-Unit

**Files:**
- Create: `systemd/reactive-resume.service`

**Interfaces:**
- Consumes: `@APP_DIR@` wird vom Innenscript ersetzt.
- Produces: Unit-Name `reactive-resume.service`, `ExecStart=/usr/bin/docker compose up --remove-orphans`.

- [ ] **Step 1: Fehlenden Test ausführen**

```bash
grep -q '^Restart=always$' systemd/reactive-resume.service
```

Erwartung: FAIL, Datei fehlt.

- [ ] **Step 2: Unit schreiben**

```ini
[Unit]
Description=Reactive Resume
Documentation=https://docs.rxresu.me
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=@APP_DIR@
Environment=COMPOSE_PROJECT_NAME=reactive-resume
ExecStart=/usr/bin/docker compose up --remove-orphans
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=10
TimeoutStartSec=600
TimeoutStopSec=120
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Test und Substitution prüfen**

```bash
set -e
grep -q '^Restart=always$' systemd/reactive-resume.service
grep -q '^After=network-online.target docker.service$' systemd/reactive-resume.service
grep -q '^Requires=docker.service$' systemd/reactive-resume.service
grep -q '^WantedBy=multi-user.target$' systemd/reactive-resume.service
grep -q '@APP_DIR@' systemd/reactive-resume.service
tmp=$(mktemp); sed 's|@APP_DIR@|/opt/reactive-resume|g' systemd/reactive-resume.service > "$tmp"
! grep -q '@[A-Z_]*@' "$tmp"
rm -f "$tmp"
```

Erwartung: PASS.

- [ ] **Step 4: Commit**

```bash
git add systemd/reactive-resume.service
git commit -m "feat: add reactive resume systemd unit"
```

---

### Task 3: Innenscript – CLI, Logging, Fehlerkette, Env-Logik

**Files:**
- Create: `install/reactive-resume-inner.sh`

**Interfaces:**
- Consumes: `APP_URL`, `APP_PORT`, `APP_IMAGE`, `APP_DIR`.
- Produces: Funktionen `env_get <key> <file>`, `env_set <key> <value> <file>`, `write_env <file>`, `normalize_app_url <url>`, `detect_ip`, `redact_env`, `on_error`.
- Library-Modus: `REACTIVE_RESUME_LIB_ONLY=1` führt `main` nicht aus.

- [ ] **Step 1: Fehlenden Library-Test ausführen**

```bash
REACTIVE_RESUME_LIB_ONLY=1 bash -c 'source install/reactive-resume-inner.sh; normalize_app_url "http://10.0.0.5:3000/"'
```

Erwartung: FAIL, Datei fehlt.

- [ ] **Step 2: Datei mit Kopf, Hilfe, Helfern und Library-Guard schreiben**

```bash
#!/usr/bin/env bash
#
# reactive-resume-inner.sh – provisioniert Reactive Resume im Gast (LXC/VM).
#
# Wird vom Host-Installer per pct exec bzw. ssh aufgerufen. Kann auf einem
# Debian/Ubuntu-Host auch direkt als root ausgeführt werden.
#
set -Eeuo pipefail

APP_ID="reactive-resume"
APP_DIR="/opt/reactive-resume"
APP_PORT="3000"
APP_URL=""
APP_IMAGE="amruthpillai/reactive-resume:latest"
LOG_FILE="/var/log/reactive-resume-install.log"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main}"
DEBUG=0
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
die()       { msg_error "$*"; exit 1; }

usage() {
  cat <<EOF
Reactive Resume – In-Guest-Installer

Usage: bash reactive-resume-inner.sh [OPTIONEN]

  --port N            Web-UI-Port (Default: ${APP_PORT})
  --app-url URL       Öffentliche URL (Default: http://<erkannte-IP>:<port>)
  --app-image REF     App-Image inkl. Tag (Default: ${APP_IMAGE})
  --app-dir PATH      Installationsverzeichnis (Default: ${APP_DIR})
  --debug             bash -x aktivieren
  -h, --help          diese Hilfe
EOF
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

normalize_port() {
  local p="${1:-}"
  is_uint "$p" && (( p >= 1 && p <= 65535 )) || die "Ungültiger Port: ${p}"
  printf '%s\n' "$p"
}

detect_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  printf '%s\n' "$ip"
}

normalize_app_url() {
  local url="${1:-}"
  url="${url%/}"
  [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || die "APP_URL muss mit http:// oder https:// beginnen: ${url}"
  printf '%s\n' "$url"
}

env_get() {
  local key="$1" file="$2" line
  [[ -f "$file" ]] || return 1
  line="$(grep -E "^${key}=" "$file" | tail -n1 || true)"
  [[ -n "$line" ]] || return 1
  line="${line#*=}"
  line="${line%\"}"
  line="${line#\"}"
  printf '%s\n' "$line"
}

env_set() {
  local key="$1" val="$2" file="$3" tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    grep -vE "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s="%s"\n' "$key" "$val" >> "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

gen_hex() { openssl rand -hex 32; }

write_env() {
  local file="$1" pg auth enc db
  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file"
  pg="$(env_get POSTGRES_PASSWORD "$file" || true)"
  auth="$(env_get AUTH_SECRET "$file" || true)"
  enc="$(env_get ENCRYPTION_SECRET "$file" || true)"
  [[ -n "$pg" ]] || pg="$(gen_hex)"
  [[ -n "$auth" ]] || auth="$(gen_hex)"
  [[ -n "$enc" ]] || enc="$(gen_hex)"
  [[ "$auth" != "$enc" ]] || die "AUTH_SECRET und ENCRYPTION_SECRET müssen verschieden sein."
  db="postgresql://postgres:${pg}@postgres:5432/postgres"
  env_set POSTGRES_PASSWORD "$pg" "$file"
  env_set DATABASE_URL "$db" "$file"
  env_set AUTH_SECRET "$auth" "$file"
  env_set ENCRYPTION_SECRET "$enc" "$file"
  env_set APP_URL "$APP_URL" "$file"
  env_set PORT "$APP_PORT" "$file"
  env_set APP_IMAGE "$APP_IMAGE" "$file"
}

redact_env() {
  [[ -f "${APP_DIR}/.env" ]] || return 0
  sed -E 's/^(POSTGRES_PASSWORD|AUTH_SECRET|ENCRYPTION_SECRET)=.*/\1="***"/' "${APP_DIR}/.env"
}

on_error() {
  local ec=$? line="$1" cmd="$2"
  trap - ERR
  msg_error "FEHLER: »${cmd}« in Zeile ${line} (Exit ${ec})."
  msg_error "Installer-Log: ${LOG_FILE}"
  echo "--- docker compose ps ---" >&2
  ( cd "$APP_DIR" 2>/dev/null && docker compose ps 2>&1 || true ) >&2
  echo "--- docker compose logs (tail 200) ---" >&2
  ( cd "$APP_DIR" 2>/dev/null && docker compose logs --tail=200 2>&1 || true ) >&2
  echo "--- systemctl status ---" >&2
  systemctl status "$APP_ID" --no-pager -l 2>&1 | tail -n 100 >&2 || true
  echo "--- journalctl (tail 100) ---" >&2
  journalctl -u "$APP_ID" -n 100 --no-pager 2>&1 || true
  echo "--- .env (maskiert) ---" >&2
  redact_env >&2 || true
  msg_error "Erneut mit --debug ausführen: bash /tmp/reactive-resume-inner.sh --debug"
  exit "$ec"
}

if [[ "${REACTIVE_RESUME_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

# main folgt in Task 4
main() {
  die "noch nicht implementiert"
}
main "$@"
```

- [ ] **Step 3: Library-Test ausführen**

```bash
REACTIVE_RESUME_LIB_ONLY=1 bash -c '
  source install/reactive-resume-inner.sh
  [ "$(normalize_app_url "http://10.0.0.5:3000/")" = "http://10.0.0.5:3000" ]
'
```

Erwartung: PASS.

- [ ] **Step 4: Env-Erhaltungstest ausführen**

```bash
REACTIVE_RESUME_LIB_ONLY=1 bash -c '
  source install/reactive-resume-inner.sh
  tmp=$(mktemp -d)
  APP_URL="http://10.0.0.5:3000"; APP_PORT=3000; APP_IMAGE="img:1"
  write_env "$tmp/.env"
  auth_before=$(env_get AUTH_SECRET "$tmp/.env")
  enc_before=$(env_get ENCRYPTION_SECRET "$tmp/.env")
  pg_before=$(env_get POSTGRES_PASSWORD "$tmp/.env")
  APP_URL="http://10.0.0.6:3000"
  write_env "$tmp/.env"
  [ "$auth_before" = "$(env_get AUTH_SECRET "$tmp/.env")" ]
  [ "$enc_before" = "$(env_get ENCRYPTION_SECRET "$tmp/.env")" ]
  [ "$pg_before" = "$(env_get POSTGRES_PASSWORD "$tmp/.env")" ]
  [ "$(env_get APP_URL "$tmp/.env")" = "http://10.0.0.6:3000" ]
  [ "$(env_get DATABASE_URL "$tmp/.env")" = "postgresql://postgres:${pg_before}@postgres:5432/postgres" ]
'
```

Erwartung: PASS.

- [ ] **Step 5: Syntax und ShellCheck**

```bash
bash -n install/reactive-resume-inner.sh
shellcheck -S warning install/reactive-resume-inner.sh
```

Erwartung: PASS (keine Ausgabe).

- [ ] **Step 6: Commit**

```bash
git add install/reactive-resume-inner.sh
git commit -m "feat: add in-guest installer core helpers"
```

---

### Task 4: Innenscript – Docker, Compose, systemd, Health

**Files:**
- Modify: `install/reactive-resume-inner.sh` (ersetzt `main`-Platzhalter)

**Interfaces:**
- Consumes: Helfer aus Task 3.
- Produces: `main --port N --app-url URL --app-image REF [--app-dir PATH] [--debug]`; installiert Docker, `compose.yml`, Unit, startet Dienst und verifiziert `/api/health`.

- [ ] **Step 1: Fehlenden Test ausführen**

```bash
bash install/reactive-resume-inner.sh --help | grep -q -- '--app-url'
```

Erwartung: PASS (Hilfe existiert bereits), aber:

```bash
grep -q 'docker compose up' install/reactive-resume-inner.sh
```

Erwartung: FAIL.

- [ ] **Step 2: `main` und Provisionierungsfunktionen ergänzen**

Ersetze den Block ab `# main folgt in Task 4` bis einschließlich `main "$@"` durch:

```bash
install_docker() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates openssl >/dev/null
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    msg_ok "Docker und Compose sind bereits vorhanden."
  else
    msg_info "Installiere Docker CE ..."
    curl -fsSL --retry 3 https://get.docker.com | sh
  fi
  systemctl enable --now docker
  docker compose version >/dev/null 2>&1 || die "docker compose Plugin fehlt nach der Installation."
}

install_compose_file() {
  local dst="${APP_DIR}/compose.yml"
  if [[ -f "${SCRIPT_DIR}/../compose/compose.yml" ]]; then
    install -m 0644 "${SCRIPT_DIR}/../compose/compose.yml" "$dst"
  else
    curl -fsSL --retry 3 -o "$dst" "${RAW_BASE}/compose/compose.yml"
  fi
  [[ -s "$dst" ]] || die "compose.yml konnte nicht installiert werden."
}

install_unit() {
  local src="${SCRIPT_DIR}/../systemd/reactive-resume.service"
  local unit="/etc/systemd/system/${APP_ID}.service" tmp
  if [[ -f "$src" ]]; then
    tmp="$src"
  else
    tmp="$(mktemp)"
    curl -fsSL --retry 3 -o "$tmp" "${RAW_BASE}/systemd/reactive-resume.service"
  fi
  sed "s|@APP_DIR@|${APP_DIR}|g" "$tmp" > "$unit"
  chmod 0644 "$unit"
  [[ -s "$unit" ]] || die "systemd-Unit konnte nicht installiert werden."
  [[ "$tmp" == "$src" ]] || rm -f "$tmp"
  systemctl daemon-reload
  systemctl enable "$APP_ID" >/dev/null 2>&1 || true
}

verify() {
  local code
  for _ in $(seq 1 90); do
    if systemctl is-active --quiet "$APP_ID"; then
      code="$(curl -s -o /tmp/reactive-resume-health.json -m 5 -w '%{http_code}' \
        "http://127.0.0.1:${APP_PORT}/api/health" 2>/dev/null || true)"
      if [[ "$code" == "200" ]] && grep -Eq '"status"[[:space:]]*:[[:space:]]*"healthy"' /tmp/reactive-resume-health.json; then
        msg_ok "Healthcheck OK (HTTP 200, status healthy)."
        return 0
      fi
    fi
    sleep 2
  done
  die "Healthcheck fehlgeschlagen (letzter HTTP-Code: ${code:-000}); Dienststatus: $(systemctl is-active "$APP_ID" 2>/dev/null || true)."
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) APP_PORT="$2"; shift 2 ;;
      --app-url) APP_URL="$2"; shift 2 ;;
      --app-image) APP_IMAGE="$2"; shift 2 ;;
      --app-dir) APP_DIR="$2"; shift 2 ;;
      --debug) DEBUG=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unbekannte Option: $1" ;;
    esac
  done

  APP_PORT="$(normalize_port "$APP_PORT")"
  [[ "$(id -u)" == "0" ]] || die "Bitte als root ausführen."

  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -i "$LOG_FILE") 2>&1
  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
  if [[ "$DEBUG" == "1" ]]; then set -x; fi

  if [[ -z "$APP_URL" ]]; then
    APP_URL="http://$(detect_ip || die "IP konnte nicht ermittelt werden."):${APP_PORT}"
  fi
  APP_URL="$(normalize_app_url "$APP_URL")"
  msg_info "APP_URL: ${APP_URL}"
  msg_info "APP_IMAGE: ${APP_IMAGE}"

  install_docker
  mkdir -p "$APP_DIR"
  chmod 0755 "$APP_DIR"
  write_env "${APP_DIR}/.env"
  install_compose_file

  msg_info "Ziehe Images ..."
  ( cd "$APP_DIR" && docker compose pull )

  install_unit

  msg_info "Starte Compose-Stack ..."
  ( cd "$APP_DIR" && docker compose up -d --remove-orphans --wait --wait-timeout 300 )
  systemctl restart "$APP_ID"

  verify

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${APP_PORT}/tcp" >/dev/null 2>&1 || true
    msg_ok "ufw: Port ${APP_PORT}/tcp freigegeben."
  fi

  msg_ok "Reactive Resume läuft unter ${APP_URL}"
}

main "$@"
```

- [ ] **Step 3: Syntax, ShellCheck und Hilfe prüfen**

```bash
bash -n install/reactive-resume-inner.sh
shellcheck -S warning install/reactive-resume-inner.sh
bash install/reactive-resume-inner.sh --help | grep -q -- '--app-dir'
grep -q 'docker compose up' install/reactive-resume-inner.sh
grep -q 'ENCRYPTION_SECRET' install/reactive-resume-inner.sh
grep -q '/api/health' install/reactive-resume-inner.sh
```

Erwartung: PASS.

- [ ] **Step 4: Commit**

```bash
git add install/reactive-resume-inner.sh
git commit -m "feat: provision docker compose stack and systemd service"
```

---

### Task 5: Host-Script – CLI, Validierung, Storage, ID-Vergabe

**Files:**
- Create: `install/reactive-resume.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `parse_args`, `next_free_id`, `pick_storage`, `ensure_template`, `on_error`; Library-Modus `REACTIVE_RESUME_LIB_ONLY=1`.

- [ ] **Step 1: Fehlende Hilfe und ID-Test ausführen**

```bash
bash install/reactive-resume.sh --help | grep -q -- '--vm'
```

Erwartung: FAIL, Datei fehlt.

```bash
mock=$(mktemp -d)
printf '#!/bin/sh\n[ "$1" = status ] && [ "${2:-0}" -lt 105 ] && exit 0\nexit 1\n' > "$mock/pct"
printf '#!/bin/sh\nexit 1\n' > "$mock/qm"
chmod +x "$mock/pct" "$mock/qm"
PATH="$mock:$PATH" REACTIVE_RESUME_LIB_ONLY=1 bash -c 'source install/reactive-resume.sh; next_free_id'
```

Erwartung nach Implementierung: `105`.

- [ ] **Step 2: Host-Script-Kopf, Defaults, Hilfe, Argumente, Validierung und Helfer schreiben**

```bash
#!/usr/bin/env bash
#
# reactive-resume.sh – Proxmox-VE-Installer für Reactive Resume.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main/install/reactive-resume.sh)"
#
# Standard: LXC (Debian 13), 2 vCPU / 4 GB / 16 GB, Port 3000, nächste freie ID.
# Optional: --vm erzeugt eine Ubuntu-24.04-Cloud-Init-VM.
#
set -Eeuo pipefail

APP="Reactive Resume"
APP_ID="reactive-resume"
MODE="lxc"
VMID=""
CT_HOSTNAME="reactive-resume"
CORES=2
RAM_MB=4096
DISK_GB=""
BRIDGE="vmbr0"
STORAGE=""
APP_PORT=3000
APP_IMAGE="amruthpillai/reactive-resume:latest"
STATIC_IP=""
GATEWAY=""
SSH_KEY_PATH="/root/.ssh/reactive-resume_vm_ed25519"
CI_USER="ubuntu"
FORCE=0
DEBUG=0
IP=""
WAIT_IP=""
ROOT_PW=""
INSTALLER_REPO="${INSTALLER_REPO:-https://github.com/HatchetMan111/ReactiveResume-Proxmox}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main}"
LOG_FILE="/var/log/reactive-resume-proxmox-install.log"
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi
SSH_KEYS_TMP=""
INNER_TMP=""
SSH_PUB=""
SSH_OPTS=()
CLOUD_IMAGE=""

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
die()       { msg_error "$*"; exit 1; }

usage() {
  cat <<EOF
${APP} – Proxmox VE Installer

Usage: bash reactive-resume.sh [OPTIONEN]

  --vmid ID            Ziel-ID (Default: kleinste freie >= 100)
  --vm                 VM statt LXC erzeugen
  --hostname NAME      Hostname (Default: ${CT_HOSTNAME})
  --cores N            vCPUs (Default: ${CORES})
  --ram MB             RAM in MiB (Default: ${RAM_MB})
  --disk GB            Disk in GiB (Default: 16 LXC / 20 VM)
  --storage NAME       Proxmox-Storage (Default: automatisch)
  --bridge NAME        Linux-Bridge (Default: ${BRIDGE})
  --port N             Web-UI-Port (Default: ${APP_PORT})
  --image REF          App-Image inkl. Tag (Default: ${APP_IMAGE})
  --ip CIDR            statische IP inkl. Präfix (z. B. 192.168.1.50/24)
  --gw IP              Gateway (nur mit --ip)
  --ssh-key PATH       privater SSH-Key (nur VM)
  --force              fremde/existierende ID überschreiben
  --debug              bash -x + erweiterte Diagnose
  -h, --help           diese Hilfe
EOF
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

ct_exists() { pct status "$1" >/dev/null 2>&1; }
vm_exists() { qm status "$1" >/dev/null 2>&1; }

next_free_id() {
  local id=100
  while ct_exists "$id" || vm_exists "$id"; do
    id=$((id + 1))
  done
  printf '%s\n' "$id"
}

pick_storage() {
  local content="$1" s c
  local -a cands=()
  mapfile -t cands < <(pvesm status --content "$content" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
  ((${#cands[@]})) || mapfile -t cands < <(pvesm status 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
  for s in local-lvm local; do
    for c in "${cands[@]}"; do
      if [[ "$c" == "$s" ]]; then
        printf '%s\n' "$s"
        return 0
      fi
    done
  done
  if ((${#cands[@]})); then
    printf '%s\n' "${cands[0]}"
    return 0
  fi
  return 1
}

ensure_template() {
  pveam update >/dev/null 2>&1 || msg_warn "pveam update fehlgeschlagen (offline?)."
  local tmpl tstore
  tmpl="$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E '^debian-13-standard_.*_amd64\.tar\.(zst|gz)$' | sort -V | tail -n1 || true)"
  if [[ -z "$tmpl" ]]; then
    tmpl="$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E '^debian-12-standard_.*_amd64\.tar\.(zst|gz)$' | sort -V | tail -n1 || true)"
  fi
  [[ -n "$tmpl" ]] || die "Kein Debian-Template gefunden (pveam available --section system)."
  tstore="$(pick_storage vztmpl)" || die "Kein Storage für vztmpl gefunden."
  if ! pvesm list "$tstore" --content vztmpl 2>/dev/null | grep -q "$tmpl"; then
    msg_info "Lade Template ${tmpl} nach ${tstore} ..."
    pveam download "$tstore" "$tmpl"
  fi
  pvesm path "${tstore}:vztmpl/${tmpl}"
}

random_password() {
  openssl rand -base64 32 | tr -d '/+=' | head -c 24
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vmid) VMID="$2"; shift 2 ;;
      --vm) MODE="vm"; shift ;;
      --hostname) CT_HOSTNAME="$2"; shift 2 ;;
      --cores) CORES="$2"; shift 2 ;;
      --ram|--memory) RAM_MB="$2"; shift 2 ;;
      --disk) DISK_GB="$2"; shift 2 ;;
      --storage) STORAGE="$2"; shift 2 ;;
      --bridge) BRIDGE="$2"; shift 2 ;;
      --port) APP_PORT="$2"; shift 2 ;;
      --image) APP_IMAGE="$2"; shift 2 ;;
      --ip) STATIC_IP="$2"; shift 2 ;;
      --gw) GATEWAY="$2"; shift 2 ;;
      --ssh-key) SSH_KEY_PATH="$2"; shift 2 ;;
      --force) FORCE=1; shift ;;
      --debug) DEBUG=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unbekannte Option: $1" ;;
    esac
  done
}

validate_config() {
  [[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
  [[ -d /etc/pve ]] || die "/etc/pve fehlt – kein Proxmox-VE-Host?"
  command -v pvesm >/dev/null 2>&1 || die "pvesm nicht gefunden."
  command -v pveam >/dev/null 2>&1 || die "pveam nicht gefunden."
  if [[ "$MODE" == "lxc" ]]; then
    command -v pct >/dev/null 2>&1 || die "pct nicht gefunden."
  else
    command -v qm >/dev/null 2>&1 || die "qm nicht gefunden."
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img nicht gefunden."
    command -v ssh >/dev/null 2>&1 || die "ssh nicht gefunden."
    command -v scp >/dev/null 2>&1 || die "scp nicht gefunden."
  fi
  is_uint "$CORES" && (( CORES >= 1 && CORES <= 128 )) || die "--cores muss 1..128 sein."
  is_uint "$RAM_MB" && (( RAM_MB >= 1024 )) || die "--ram muss >= 1024 MiB sein."
  is_uint "$APP_PORT" && (( APP_PORT >= 1 && APP_PORT <= 65535 )) || die "--port muss 1..65535 sein."
  [[ "$CT_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "--hostname ist kein gültiger DNS-Name."
  [[ "$APP_IMAGE" =~ ^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]] || die "--image enthält ungültige Zeichen."
  if [[ -n "$VMID" ]]; then
    is_uint "$VMID" && (( VMID >= 100 )) || die "--vmid muss eine Zahl >= 100 sein."
  fi
  if [[ -z "$DISK_GB" ]]; then
    if [[ "$MODE" == "vm" ]]; then DISK_GB=20; else DISK_GB=16; fi
  fi
  is_uint "$DISK_GB" && (( DISK_GB >= 4 )) || die "--disk muss >= 4 GiB sein."
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge ${BRIDGE} existiert nicht."
  if [[ -n "$STATIC_IP" || -n "$GATEWAY" ]]; then
    [[ -n "$STATIC_IP" && -n "$GATEWAY" ]] || die "--ip und --gw müssen gemeinsam angegeben werden."
    [[ "$STATIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || die "--ip erwartet CIDR, z. B. 192.168.1.50/24."
    [[ "$GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--gw erwartet eine IPv4-Adresse."
  fi
}

if [[ "${REACTIVE_RESUME_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Rest folgt in Task 6/7
main() { die "noch nicht implementiert"; }
main "$@"
```

- [ ] **Step 3: Hilfe- und ID-Tests ausführen**

```bash
bash install/reactive-resume.sh --help | grep -q -- '--vm'
mock=$(mktemp -d)
printf '#!/bin/sh\n[ "$1" = status ] && [ "${2:-0}" -lt 105 ] && exit 0\nexit 1\n' > "$mock/pct"
printf '#!/bin/sh\nexit 1\n' > "$mock/qm"
chmod +x "$mock/pct" "$mock/qm"
got=$(PATH="$mock:$PATH" REACTIVE_RESUME_LIB_ONLY=1 bash -c 'source install/reactive-resume.sh; next_free_id')
[ "$got" = "105" ]
```

Erwartung: PASS.

- [ ] **Step 4: Syntax und ShellCheck**

```bash
bash -n install/reactive-resume.sh
shellcheck -S warning install/reactive-resume.sh
```

Erwartung: PASS.

- [ ] **Step 5: Commit**

```bash
git add install/reactive-resume.sh
git commit -m "feat: add host installer cli and id allocation"
```

---

### Task 6: Host-Script – LXC-Pfad

**Files:**
- Modify: `install/reactive-resume.sh`

**Interfaces:**
- Consumes: Helfer aus Task 5.
- Produces: `create_lxc`, `update_lxc`, `wait_for_ct`, `detect_ct_ip`, `wait_for_ip`, `run_inner`, `verify_outer`, `on_error`, `summary`, `setup_logging`.

- [ ] **Step 1: Fehlenden Test ausführen**

```bash
grep -q 'pct create' install/reactive-resume.sh
```

Erwartung: FAIL.

- [ ] **Step 2: Logging, Fehlerkette, LXC-Funktionen und Lauf-Aufruf ergänzen**

Ersetze den Block ab `# Rest folgt in Task 6/7` bis einschließlich `main "$@"` durch:

```bash
setup_logging() {
  umask 077
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -i "$LOG_FILE") 2>&1
  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
  msg_info "Host-Log: ${LOG_FILE}"
  if [[ "$DEBUG" == "1" ]]; then set -x; fi
}

on_error() {
  local ec=$? line="$1" cmd="$2"
  trap - ERR
  msg_error "FEHLER: »${cmd}« in Zeile ${line} (Exit ${ec})."
  msg_error "Host-Log: ${LOG_FILE}"
  if [[ -n "${VMID:-}" ]]; then
    if ct_exists "$VMID"; then
      echo "--- pct status/config ---" >&2
      pct status "$VMID" >&2 || true
      pct config "$VMID" 2>&1 | sed -n '1,25p' >&2 || true
      echo "--- Innen-Log (tail 120) ---" >&2
      pct exec "$VMID" -- tail -n 120 /var/log/reactive-resume-install.log 2>&1 || true
      echo "--- Dienststatus ---" >&2
      pct exec "$VMID" -- systemctl status reactive-resume --no-pager -l 2>&1 | tail -n 80 >&2 || true
      echo "--- Compose-Logs (tail 200) ---" >&2
      pct exec "$VMID" -- bash -lc 'cd /opt/reactive-resume && docker compose logs --tail=200' 2>&1 || true
      echo "Diagnose: pct enter ${VMID}" >&2
    elif vm_exists "$VMID"; then
      echo "--- qm status/config ---" >&2
      qm status "$VMID" >&2 || true
      qm config "$VMID" 2>&1 | sed -n '1,25p' >&2 || true
      if [[ -n "${IP:-}" && ${#SSH_OPTS[@]} -gt 0 ]]; then
        echo "--- Innen-Log (tail 120) ---" >&2
        ssh "${SSH_OPTS[@]}" "${CI_USER}@${IP}" 'sudo tail -n 120 /var/log/reactive-resume-install.log' 2>&1 || true
        ssh "${SSH_OPTS[@]}" "${CI_USER}@${IP}" 'sudo systemctl status reactive-resume --no-pager -l | tail -n 80' 2>&1 || true
      fi
      echo "Diagnose: qm terminal ${VMID}" >&2
    fi
  fi
  msg_error "Erneut mit --debug für bash -x: bash reactive-resume.sh --debug"
  exit "$ec"
}

cleanup() {
  if [[ -n "$SSH_KEYS_TMP" && -f "$SSH_KEYS_TMP" ]]; then rm -f "$SSH_KEYS_TMP"; fi
  if [[ -n "$INNER_TMP" && -f "$INNER_TMP" ]]; then rm -f "$INNER_TMP"; fi
  return 0
}

wait_for_ct() {
  local i
  for i in $(seq 1 60); do
    pct exec "$VMID" -- true >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

detect_ct_ip() {
  local ip=""
  ip="$(pct exec "$VMID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  [[ -n "$ip" ]] || ip="$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  printf '%s\n' "$ip"
}

wait_for_ip() {
  local i ip
  for i in $(seq 1 60); do
    ip="$(detect_ct_ip)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      WAIT_IP="$ip"
      return 0
    fi
    sleep 2
  done
  return 1
}

is_ours_ct() {
  pct config "$1" 2>/dev/null | grep -qE "(^hostname: ${CT_HOSTNAME}$|${APP})"
}

ensure_unique_name() {
  local n
  if [[ "$MODE" == "lxc" ]]; then
    n="$(pct list 2>/dev/null | awk 'NR>1 {print $NF}' | grep -x "$CT_HOSTNAME" || true)"
  else
    n="$(qm list 2>/dev/null | awk 'NR>1 {print $2}' | grep -x "$CT_HOSTNAME" || true)"
  fi
  if [[ -n "$n" ]]; then
    msg_warn "Name ${CT_HOSTNAME} ist vergeben – nutze ${CT_HOSTNAME}-${VMID}."
    CT_HOSTNAME="${CT_HOSTNAME}-${VMID}"
  fi
}

create_lxc() {
  local tmpl net
  tmpl="$(ensure_template)"
  [[ -n "$STORAGE" ]] || STORAGE="$(pick_storage rootdir)" || die "Kein Storage für rootdir gefunden."
  pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage ${STORAGE} existiert nicht."
  net="ip=dhcp"
  [[ -n "$STATIC_IP" ]] && net="ip=${STATIC_IP},gw=${GATEWAY}"
  ROOT_PW="$(random_password)"
  msg_info "Erstelle LXC ${VMID} (${CT_HOSTNAME}) auf ${STORAGE} ..."
  pct create "$VMID" "$tmpl" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" --memory "$RAM_MB" --swap 512 \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},${net},firewall=0" \
    --nameserver 1.1.1.1 \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 --onboot 1 \
    --password "$ROOT_PW" \
    --description "${APP} – installiert von ${INSTALLER_REPO}"
  pct start "$VMID"
  wait_for_ct || die "Container ${VMID} bootet nicht (pct exec fehlgeschlagen)."
  {
    echo "${APP} – Zugangsdaten"
    echo "CTID: ${VMID}"
    echo "Root-Passwort: ${ROOT_PW}"
    echo "Konsole: pct enter ${VMID}"
  } > /root/reactive-resume.creds
  chmod 600 /root/reactive-resume.creds
  msg_ok "LXC erstellt. Root-Passwort: /root/reactive-resume.creds"
}

update_lxc() {
  pct set "$VMID" --onboot 1 --features nesting=1,keyctl=1
  if [[ "$(pct status "$VMID" | awk '{print $2}')" != "running" ]]; then
    msg_info "Starte bestehenden LXC ${VMID} ..."
    pct start "$VMID"
  fi
  wait_for_ct || die "Bestehender Container ${VMID} ist nicht erreichbar."
}

run_inner() {
  local inner
  local -a args
  if [[ -f "${SCRIPT_DIR}/reactive-resume-inner.sh" ]]; then
    inner="${SCRIPT_DIR}/reactive-resume-inner.sh"
  else
    INNER_TMP="$(mktemp)"
    msg_info "Lade Innenscript aus ${RAW_BASE} ..."
    curl -fsSL --retry 3 -o "$INNER_TMP" "${RAW_BASE}/install/reactive-resume-inner.sh"
    inner="$INNER_TMP"
  fi
  [[ -s "$inner" ]] || die "Innenscript nicht gefunden."
  args=(--port "$APP_PORT" --app-url "http://${IP}:${APP_PORT}" --app-image "$APP_IMAGE")
  [[ "$DEBUG" == "1" ]] && args+=(--debug)

  if [[ "$MODE" == "lxc" ]]; then
    pct push "$VMID" "$inner" /tmp/reactive-resume-inner.sh --perms 700
    if ! pct exec "$VMID" -- bash /tmp/reactive-resume-inner.sh "${args[@]}"; then
      die "Innenscript ist fehlgeschlagen (siehe Diagnose oben)."
    fi
  else
    scp "${SSH_OPTS[@]}" "$inner" "${CI_USER}@${IP}:/tmp/reactive-resume-inner.sh"
    if ! ssh "${SSH_OPTS[@]}" "${CI_USER}@${IP}" "sudo bash /tmp/reactive-resume-inner.sh $(printf '%q ' "${args[@]}")"; then
      die "Innenscript ist fehlgeschlagen (siehe Diagnose oben)."
    fi
  fi
}

verify_outer() {
  local i code
  for i in $(seq 1 24); do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${IP}:${APP_PORT}/api/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      msg_ok "Web-UI von außen erreichbar (HTTP 200)."
      return 0
    fi
    sleep 5
  done
  msg_error "Web-UI von außen nicht erreichbar (letzter HTTP-Code: ${code:-000})."
  return 1
}

summary() {
  echo ""
  echo "════════════ ${APP} BEREIT ════════════"
  echo "  Typ         : $([[ "$MODE" == "lxc" ]] && echo LXC || echo VM)"
  echo "  ID          : ${VMID}"
  echo "  Hostname    : ${CT_HOSTNAME}"
  echo "  Ressourcen  : ${CORES} vCPU / ${RAM_MB} MiB RAM / ${DISK_GB} GiB Disk"
  echo "  IP          : ${IP}"
  echo "  Web UI      : http://${IP}:${APP_PORT}/"
  echo "  Health      : http://${IP}:${APP_PORT}/api/health"
  if [[ "$MODE" == "lxc" ]]; then
    echo "  Konsole     : pct enter ${VMID}"
    echo "  Credentials : /root/reactive-resume.creds"
  else
    echo "  SSH         : ssh -i ${SSH_KEY_PATH} ${CI_USER}@${IP}"
    echo "  Konsole     : qm terminal ${VMID}"
  fi
  echo "  Dienst      : systemctl status ${APP_ID}"
  echo "  Update      : dieses Script mit --vmid ${VMID}$([[ "$MODE" == "vm" ]] && echo ' --vm') erneut ausführen"
  echo "  Reboot-Test : bash tests/reboot-test.sh ${VMID} ${IP} ${APP_PORT}"
  echo "  Entfernen   : $([[ "$MODE" == "lxc" ]] && echo "pct stop ${VMID}; pct destroy ${VMID}" || echo "qm stop ${VMID}; qm destroy ${VMID} --purge")"
  echo "  OpenRouter  : Settings → AI & developer → Add provider → OpenRouter"
  echo "═══════════════════════════════════════"
}

main() {
  local exists=0
  parse_args "$@"
  validate_config
  setup_logging
  trap cleanup EXIT

  if [[ -z "$VMID" ]]; then
    VMID="$(next_free_id)"
  fi
  msg_info "Ziel-ID: ${VMID} (Modus: ${MODE})"

  if ct_exists "$VMID"; then
    [[ "$MODE" == "lxc" ]] || die "ID ${VMID} ist ein LXC; nutze ohne --vm."
    if [[ "$FORCE" != "1" ]] && ! is_ours_ct "$VMID"; then
      die "ID ${VMID} gehört nicht zu ${APP}. Mit --force überschreiben."
    fi
    exists=1
    msg_info "Aktualisiere bestehenden LXC ${VMID} ..."
    update_lxc
  elif vm_exists "$VMID"; then
    [[ "$MODE" == "vm" ]] || die "ID ${VMID} ist eine VM; nutze --vm."
    if [[ "$FORCE" != "1" ]] && ! is_ours_vm "$VMID"; then
      die "ID ${VMID} gehört nicht zu ${APP}. Mit --force überschreiben."
    fi
    exists=1
    msg_info "Aktualisiere bestehende VM ${VMID} ..."
    update_vm
  else
    ensure_unique_name
    if [[ "$MODE" == "lxc" ]]; then
      create_lxc
    else
      create_vm
    fi
  fi

  if [[ "$MODE" == "lxc" ]]; then
    wait_for_ip || die "Keine IPv4-Adresse im Container ${VMID} gefunden."
    IP="$WAIT_IP"
  else
    wait_for_vm_ip || die "Keine IPv4-Adresse in VM ${VMID} gefunden."
    IP="$WAIT_IP"
  fi
  msg_ok "IP: ${IP}"

  run_inner
  verify_outer || die "Verifikation von außen fehlgeschlagen."
  summary
  msg_ok "Installation abgeschlossen (bestehend: ${exists})."
}

main "$@"
```

- [ ] **Step 3: Syntax und LXC-Assertions**

```bash
bash -n install/reactive-resume.sh
grep -q 'pct create' install/reactive-resume.sh
grep -q -- '--onboot 1' install/reactive-resume.sh
grep -q 'nesting=1,keyctl=1' install/reactive-resume.sh
grep -q 'wait_for_ip' install/reactive-resume.sh
grep -q 'summary' install/reactive-resume.sh
```

Erwartung: PASS. Hinweis: `create_vm`, `update_vm`, `wait_for_vm_ip` fehlen noch und werden in Task 7 ergänzt; `bash -n` ist trotzdem grün.

- [ ] **Step 4: Commit**

```bash
git add install/reactive-resume.sh
git commit -m "feat: add lxc provisioning and guest handoff"
```

---

### Task 7: Host-Script – VM-Pfad und Außen-Verifikation

**Files:**
- Modify: `install/reactive-resume.sh`

**Interfaces:**
- Consumes: Helfer aus Task 5/6.
- Produces: `prepare_ssh_key`, `ensure_cloud_image`, `create_vm`, `update_vm`, `wait_vm_ssh`, `detect_vm_ip`, `wait_for_vm_ip`; `IP` für `run_inner`/`verify_outer`.

- [ ] **Step 1: Fehlenden Test ausführen**

```bash
grep -q 'qm importdisk' install/reactive-resume.sh
```

Erwartung: FAIL.

- [ ] **Step 2: VM-Funktionen vor `main` einfügen**

```bash
prepare_ssh_key() {
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  if [[ ! -f "$SSH_KEY_PATH" ]]; then
    msg_info "Erzeuge SSH-Key ${SSH_KEY_PATH} ..."
    ssh-keygen -q -t ed25519 -N "" -C "${APP_ID}-proxmox" -f "$SSH_KEY_PATH"
  fi
  grep -q '^ssh-' "$SSH_KEY_PATH" 2>/dev/null && die "--ssh-key erwartet einen privaten Key."
  chmod 600 "$SSH_KEY_PATH"
  if [[ -f "${SSH_KEY_PATH}.pub" ]]; then
    SSH_PUB="$(cat "${SSH_KEY_PATH}.pub")"
  else
    SSH_PUB="$(ssh-keygen -y -P "" -f "$SSH_KEY_PATH" </dev/null)"
  fi
  [[ "$SSH_PUB" == ssh-* ]] || die "Konnte keinen Public Key aus ${SSH_KEY_PATH} lesen."
  SSH_OPTS=(
    -i "$SSH_KEY_PATH"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5
    -o BatchMode=yes
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=20
  )
}

ensure_cloud_image() {
  local arch="amd64" codename="noble" name url
  [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
  name="${codename}-server-cloudimg-${arch}.img"
  url="https://cloud-images.ubuntu.com/${codename}/current/${name}"
  CLOUD_IMAGE="/var/lib/vz/template/iso/${name}"
  mkdir -p "$(dirname "$CLOUD_IMAGE")"
  if [[ ! -s "$CLOUD_IMAGE" ]]; then
    msg_info "Lade Ubuntu 24.04 Cloud-Image ..."
    rm -f "${CLOUD_IMAGE}.part"
    curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 -o "${CLOUD_IMAGE}.part" "$url"
    mv "${CLOUD_IMAGE}.part" "$CLOUD_IMAGE"
  else
    msg_ok "Cloud-Image vorhanden: ${CLOUD_IMAGE}"
  fi
  qemu-img info "$CLOUD_IMAGE" >/dev/null 2>&1 || die "Cloud-Image ist ungültig."
}

create_vm() {
  local import_out disk net
  ensure_cloud_image
  prepare_ssh_key
  [[ -n "$STORAGE" ]] || STORAGE="$(pick_storage images)" || die "Kein Storage für VM-Images gefunden."
  pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage ${STORAGE} existiert nicht."
  net="ip=dhcp"
  [[ -n "$STATIC_IP" ]] && net="ip=${STATIC_IP},gw=${GATEWAY}"

  msg_info "Erstelle VM ${VMID} (${CT_HOSTNAME}) ..."
  qm create "$VMID" \
    --name "$CT_HOSTNAME" \
    --ostype l26 \
    --cpu host \
    --sockets 1 --cores "$CORES" \
    --memory "$RAM_MB" --balloon 0 \
    --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=${BRIDGE},firewall=0" \
    --agent enabled=1 \
    --serial0 socket \
    --vga std \
    --onboot 1 \
    --description "${APP} – installiert von ${INSTALLER_REPO}"

  import_out="$(qm importdisk "$VMID" "$CLOUD_IMAGE" "$STORAGE" 2>&1)"
  printf '%s\n' "$import_out"
  disk="$(qm config "$VMID" | awk -F': ' '/^unused0:/ {print $2}')"
  if [[ -z "$disk" ]]; then
    disk="$(printf '%s\n' "$import_out" | sed -n "s/.*as '\([^']*\)'.*/\1/p" | tail -n1 | sed -E 's/^unused[0-9]+://')"
  fi
  [[ -n "$disk" ]] || die "Importierte Disk konnte nicht ermittelt werden."

  qm set "$VMID" --scsi0 "${disk},discard=on,ssd=1"
  qm disk resize "$VMID" scsi0 "${DISK_GB}G"
  qm set "$VMID" --boot "order=scsi0"
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"

  SSH_KEYS_TMP="$(mktemp)"
  printf '%s\n' "$SSH_PUB" > "$SSH_KEYS_TMP"
  qm set "$VMID" --ciuser "$CI_USER"
  qm set "$VMID" --sshkeys "$SSH_KEYS_TMP"
  qm set "$VMID" --ipconfig0 "$net"
  qm set "$VMID" --nameserver "1.1.1.1 9.9.9.9"
  qm set "$VMID" --ciupgrade 0
  rm -f "$SSH_KEYS_TMP"; SSH_KEYS_TMP=""

  qm start "$VMID"
  msg_ok "VM gestartet."
}

update_vm() {
  qm set "$VMID" --onboot 1
  if [[ "$(qm status "$VMID" | awk '{print $2}')" != "running" ]]; then
    msg_info "Starte bestehende VM ${VMID} ..."
    qm start "$VMID"
  fi
  prepare_ssh_key
}

is_ours_vm() {
  qm config "$1" 2>/dev/null | grep -qE "(^name: ${CT_HOSTNAME}$|${APP})"
}

agent_ping() {
  timeout 10 qm agent "$VMID" ping >/dev/null 2>&1
}

detect_vm_ip() {
  local json ip mac
  if agent_ping; then
    json="$(timeout 20 qm guest cmd "$VMID" network-get-interfaces 2>/dev/null || true)"
  else
    json=""
  fi
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
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }
  fi
  mac="$(qm config "$VMID" 2>/dev/null | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -n1 || true)"
  if [[ -n "$mac" ]]; then
    ip="$(ip neigh show dev "$BRIDGE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | grep -v '^169\.254\.' | head -n1 || true)"
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }
  fi
  return 1
}

sweep_bridge() {
  local subnet i
  subnet="$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | cut -d. -f1-3 || true)"
  [[ "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  for i in $(seq 1 254); do ping -c1 -W1 "${subnet}.${i}" >/dev/null 2>&1 & done
  wait 2>/dev/null || true
}

wait_vm_ssh() {
  local i candidate
  for i in $(seq 1 120); do
    if (( i == 1 || i % 12 == 0 )); then sweep_bridge; fi
    candidate="$(detect_vm_ip 2>/dev/null || true)"
    [[ -n "$candidate" ]] && WAIT_IP="$candidate"
    if [[ -n "${WAIT_IP:-}" ]] && ssh "${SSH_OPTS[@]}" "${CI_USER}@${WAIT_IP}" true >/dev/null 2>&1; then
      return 0
    fi
    if (( i % 6 == 0 )); then
      msg_info "  ... warte auf SSH (${i}/120, IP: ${WAIT_IP:-?})"
    fi
    sleep 5
  done
  return 1
}

wait_for_vm_ip() {
  wait_vm_ssh
}
```

- [ ] **Step 3: Syntax, ShellCheck und VM-Assertions**

```bash
bash -n install/reactive-resume.sh
shellcheck -S warning install/reactive-resume.sh
grep -q 'qm importdisk' install/reactive-resume.sh
grep -q -- '--ciuser' install/reactive-resume.sh
grep -q 'wait_vm_ssh' install/reactive-resume.sh
grep -q 'verify_outer' install/reactive-resume.sh
bash install/reactive-resume.sh --help | grep -q -- '--ssh-key'
```

Erwartung: PASS.

- [ ] **Step 4: Commit**

```bash
git add install/reactive-resume.sh
git commit -m "feat: add vm path with cloud-init and verification"
```

---

### Task 8: Statische Checks

**Files:**
- Create: `tests/static-checks.sh`

**Interfaces:**
- Consumes: alle Scripts, Unit, Compose.
- Produces: Exit 0 nur bei grünen Checks; druckt `[PASS]`/`[FAIL]`.

- [ ] **Step 1: Fehlenden Test ausführen**

```bash
bash tests/static-checks.sh
```

Erwartung: FAIL, Datei fehlt.

- [ ] **Step 2: `tests/static-checks.sh` schreiben**

```bash
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
```

- [ ] **Step 3: Checks ausführen und Fehler beheben**

```bash
chmod +x tests/static-checks.sh
bash tests/static-checks.sh
```

Erwartung: alle `[PASS]`, Exit 0. Falls ShellCheck meckert: gemeldete Zeile korrigieren, nicht die Regel abschalten.

- [ ] **Step 4: Commit**

```bash
git add tests/static-checks.sh
git commit -m "test: add static installer checks"
```

---

### Task 9: Reboot-Test

**Files:**
- Create: `tests/reboot-test.sh`

**Interfaces:**
- Consumes: `tests/reboot-test.sh <ID> [IP] [PORT]`.
- Produces: Exit 0 nur, wenn Dienst und Health vor **und** nach dem Reboot grün sind.

- [ ] **Step 1: Fehlenden Test ausführen**

```bash
bash tests/reboot-test.sh 999 127.0.0.1 3000
```

Erwartung: FAIL, Datei fehlt.

- [ ] **Step 2: Script schreiben**

```bash
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
```

- [ ] **Step 3: Syntax und Hilfe**

```bash
chmod +x tests/reboot-test.sh
bash -n tests/reboot-test.sh
shellcheck -S warning tests/reboot-test.sh
bash tests/reboot-test.sh 2>&1 | grep -q 'Usage'
```

Erwartung: PASS.

- [ ] **Step 4: Commit**

```bash
git add tests/reboot-test.sh
git commit -m "test: add lxc/vm reboot verification"
```

---

### Task 10: README und Abschlussprüfung

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: fertige Scripts.
- Produces: Einzeiler, Optionen, OpenRouter-Anleitung, Update/Uninstall/Reboot-Test, Troubleshooting.

- [ ] **Step 1: README schreiben**

Inhalt (exakt diese Abschnitte und Befehle):

````markdown
# Reactive Resume auf Proxmox VE

Ein Einzeiler-Installer im Stil der Proxmox VE Community Scripts. Er erstellt
standardmäßig einen Debian-13-LXC (optional per `--vm` eine Ubuntu-24.04-VM),
installiert Reactive Resume v6 mit Docker Compose und PostgreSQL 18 und richtet
einen reboot-festen systemd-Dienst ein.

- Web-UI: `http://<IP>:3000/`
- Health: `http://<IP>:3000/api/health`
- AI: OpenRouter optional pro Benutzer in der UI
- Kein TLS, kein Reverse Proxy, keine Cloud-Pflicht

## Voraussetzungen

- Proxmox VE 8.x, Root-SSH auf dem Host
- Internetzugang des Hosts (Debian-Template, GitHub, Docker Hub)
- Linux-Bridge `vmbr0`
- Storage für `rootdir` (LXC) bzw. `images` (VM)
- LXC: 2 vCPU / 4 GB / 16 GB; VM: 2 vCPU / 4 GB / 20 GB

## Schnellstart

Auf dem Proxmox-Host als root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main/install/reactive-resume.sh)"
```

Das Script fragt nichts ab, nimmt die kleinste freie ID ab 100 und zeigt am Ende
ID, IP und URL an.

Lokal:

```bash
git clone https://github.com/HatchetMan111/ReactiveResume-Proxmox.git
cd ReactiveResume-Proxmox
sudo bash install/reactive-resume.sh
```

## Optionen

```text
--vmid ID            Ziel-ID (Default: kleinste freie >= 100)
--vm                 VM statt LXC
--hostname NAME      Hostname (Default: reactive-resume)
--cores N            vCPUs (Default: 2)
--ram MB             RAM in MiB (Default: 4096)
--disk GB            Disk in GiB (Default: 16 LXC / 20 VM)
--storage NAME       Proxmox-Storage (Default: automatisch)
--bridge NAME        Bridge (Default: vmbr0)
--port N             Web-UI-Port (Default: 3000)
--image REF          App-Image (Default: amruthpillai/reactive-resume:latest)
--ip CIDR            statische IP inkl. Präfix
--gw IP              Gateway (nur mit --ip)
--ssh-key PATH       privater SSH-Key (nur VM)
--force              fremde ID überschreiben
--debug              bash -x + erweiterte Diagnose
```

Beispiele:

```bash
# LXC mit statischer IP
bash install/reactive-resume.sh --ip 192.168.1.50/24 --gw 192.168.1.1

# VM mit mehr RAM
bash install/reactive-resume.sh --vm --ram 8192 --disk 40

# Update der bestehenden Installation
bash install/reactive-resume.sh --vmid 105
```

## Nach der Installation

1. `http://<IP>:3000/` öffnen und den ersten Account anlegen.
2. Optional OpenRouter: **Settings → AI & developer → Add provider →
   OpenRouter**, Key einfügen, Modell z. B. `openai/gpt-4.1` (muss Tool-Calling
   unterstützen), **Save and test**.
3. Instanz privat halten: nach dem eigenen Account
   `FLAG_DISABLE_SIGNUPS="true"` in `/opt/reactive-resume/.env` ergänzen und
   `docker compose up -d` im Verzeichnis ausführen.

Der OpenRouter-Key wird mit `ENCRYPTION_SECRET` verschlüsselt gespeichert und
nie vom Installer verlangt oder geloggt.

## Update

Erneut mit derselben ID ausführen:

```bash
bash install/reactive-resume.sh --vmid 105
```

Das Script zieht neue Images, schreibt die Unit neu und startet den Dienst. Die
Docker-Volumes (Präfix `reactive-resume_`) bleiben erhalten; Secrets in
`.env` werden nicht neu erzeugt.

## Reboot-Test

```bash
bash tests/reboot-test.sh 105 <IP> 3000
```

Prüft Dienst, Compose, Health und `APP_URL` vor und nach `pct reboot` bzw.
`qm reboot`. Ohne IP wird sie automatisch ermittelt.

## Wichtig: APP_URL und DHCP

`APP_URL` muss exakt der Browser-Adresse entsprechen. Bei DHCP kann sich die IP
ändern; dann schlägt der Login fehl.

- Installer erneut ausführen (aktualisiert `APP_URL`), oder
- statische IP verwenden: `--ip 192.168.1.50/24 --gw 192.168.1.1`, oder
- DHCP-Reservation im Router.

Manuell: `APP_URL="http://<neue-ip>:3000"` in `/opt/reactive-resume/.env`
setzen und `docker compose up -d reactive-resume` ausführen.

## Troubleshooting

```bash
# Host
tail -n 200 /var/log/reactive-resume-proxmox-install.log

# LXC
pct enter 105
systemctl status reactive-resume
journalctl -u reactive-resume -n 200 --no-pager
cd /opt/reactive-resume && docker compose ps
cd /opt/reactive-resume && docker compose logs --tail=200

# VM
qm terminal 105
ssh -i /root/.ssh/reactive-resume_vm_ed25519 ubuntu@<IP>
```

- **Dienst startet nicht:** `docker compose logs` prüfen; meist
  `DATABASE_URL`/Postgres oder fehlendes `nesting=1,keyctl=1` im LXC.
- **Health 503:** Postgres-Container und `/app/data`-Volume prüfen.
- **Login-Loop:** `APP_URL` gegen die Browser-URL prüfen (siehe oben).
- **Kein Docker im LXC:** `pct config 105 | grep features` muss
  `nesting=1,keyctl=1` enthalten; sonst Script erneut ausführen.

## Deinstallation

LXC:

```bash
pct stop 105
pct destroy 105
```

VM:

```bash
qm stop 105
qm destroy 105 --purge
```

Damit werden auch alle Daten in den Volumes gelöscht.

## Sicherheit

- Kein TLS; nur LAN/VPN oder Reverse Proxy davor.
- PostgreSQL ist nicht nach außen veröffentlicht.
- `.env` ist `0600`; Docker-Socket-Zugriff ist root-äquivalent.
- OpenRouter-Key nur in der UI, verschlüsselt mit `ENCRYPTION_SECRET`.

## Projektstruktur

```text
ReactiveResume-Proxmox/
├── install/reactive-resume.sh
├── install/reactive-resume-inner.sh
├── compose/compose.yml
├── systemd/reactive-resume.service
├── tests/static-checks.sh
├── tests/reboot-test.sh
└── README.md
```

## Teststatus

`tests/static-checks.sh` läuft ohne Proxmox (Syntax, ShellCheck, Compose,
Vertrags-Checks, Env-Erhaltung, ID-Vergabe). Der echte Installations- und
Reboot-Test muss auf einem Proxmox-Host ausgeführt werden; in der
Entwicklungssandbox fehlen `pct` und `qm`.
````

- [ ] **Step 2: Alle statischen Prüfungen ausführen**

```bash
bash -n install/reactive-resume.sh
bash -n install/reactive-resume-inner.sh
bash -n tests/static-checks.sh
bash -n tests/reboot-test.sh
shellcheck -S warning install/reactive-resume.sh install/reactive-resume-inner.sh tests/static-checks.sh tests/reboot-test.sh
bash tests/static-checks.sh
```

Erwartung: alle Checks `[PASS]`, Exit 0.

- [ ] **Step 3: Rechte setzen und Git-Status prüfen**

```bash
chmod +x install/reactive-resume.sh install/reactive-resume-inner.sh tests/static-checks.sh tests/reboot-test.sh
git status --short
```

Erwartung: nur `README.md` und ggf. Rechteänderungen.

- [ ] **Step 4: Commit**

```bash
git add README.md install/reactive-resume.sh install/reactive-resume-inner.sh tests/static-checks.sh tests/reboot-test.sh
git commit -m "docs: add readme and finalize installer"
```

- [ ] **Step 5: Abschlussbericht**

Fasse zusammen:

```text
Einzeiler:
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main/install/reactive-resume.sh)"

Erwartete Ausgabe:
  Ziel-ID: 105 (Modus: lxc)
  ... [OK] LXC erstellt ...
  ... [OK] Healthcheck OK (HTTP 200, status healthy).
  ... [OK] Web-UI von außen erreichbar (HTTP 200).
  ════════ Reactive Resume BEREIT ════════
    ID          : 105
    IP          : 192.168.1.50
    Web UI      : http://192.168.1.50:3000/
    OpenRouter  : Settings → AI & developer → Add provider → OpenRouter
```

Nenne ausdrücklich die nicht in der Sandbox möglichen Schritte
(`tests/reboot-test.sh` auf dem Proxmox-Host) und den Befehl dafür.
```

## Self-Review

**Spec coverage:** Ziel (Task 1/4/6/10), Nicht-Ziele (README/Scope), Entscheidungen (Global Constraints), Architektur (Task 5–7), Repo-Struktur (Task 1–10), Host-Ablauf (Task 5–7), LXC (Task 6), VM (Task 7), Update/Idempotenz (Task 3/6/7), In-Guest (Task 3/4), `.env` (Task 3), Compose (Task 1), Unit (Task 2), OpenRouter (Task 3/4/10), Fehlerkette (Task 3/6), Verifikation (Task 4/6/7), Tests (Task 8/9), Sicherheit (Global/README), APP_URL/DHCP (Task 9/README), CLI (Task 5), Akzeptanzkriterien (Task 8/10).

**Placeholder scan:** Keine `TBD`/`TODO`; die bewussten Zwischen-Platzhalter in Task 3/5 werden in Task 4/6 vollständig ersetzt. Der einzige bewusst offene Punkt ist der echte Proxmox-Lauf, der laut Spec nicht in der Sandbox möglich ist und in Task 10/README adressiert wird.

**Type consistency:** `APP_ID`, `APP_DIR`, `APP_PORT`, `APP_IMAGE`, `APP_URL`, `VMID`, `CT_HOSTNAME`, `IP`, `WAIT_IP`, `SSH_OPTS`, `WAIT_IP` werden durchgängig gleich benannt. `run_inner` nutzt `--app-url`, `--app-image`, `--port`; das Innenscript parst genau diese Namen. `verify_outer` und `reboot-test.sh` nutzen `/api/health` und Port `${APP_PORT}`/`${PORT}` konsistent.

**Review Focus tests:** ID-Kollision (Task 5 Mock-Test, Task 8), DHCP/APP_URL (Task 9), Update ohne Datenverlust (Task 3/8), Docker-in-LXC (Task 6/8), falscher Erfolg (Task 4/7/8).

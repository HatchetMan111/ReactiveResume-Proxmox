# Reactive Resume auf Proxmox VE – Design

**Datum:** 2026-10-23
**Status:** Entwurf zur Review
**Repo (geplant):** `HatchetMan111/ReactiveResume-Proxmox`, Branch `main`

## 1. Ziel

Ein Einzeiler-Installer im Stil der Proxmox VE Community Scripts, der auf einem
Proxmox-VE-Host standardmäßig einen **LXC-Container** und optional per Flag eine
**VM** erzeugt, darin Reactive Resume v6 mit den offiziellen Docker-Images
installiert und eine reboot-feste Web-UI unter `http://<IP>:3000` bereitstellt.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main/install/reactive-resume.sh)"
```

Erfolgskriterium: Nach einem Kaltstart des Hosts bzw. Reboot des Containers ist
die Web-UI ohne manuellen Eingriff wieder erreichbar, und der Status lässt sich
mit einem mitgelieferten Testscript belegen.

Die **Installation** benötigt Internetzugang (GitHub, Debian-Template, Docker
Hub). Der **Betrieb** läuft danach vollständig lokal; nur die optionale
OpenRouter-Nutzung ist eine ausgehende externe Verbindung.

## 2. Nicht-Ziele

- Kein TLS, kein Reverse Proxy, keine Domainverwaltung (LAN-Betrieb).
- Kein Backup-/Restore-Framework (nur README-Hinweise).
- Kein SMTP-, OAuth- oder SSO-Setup.
- Kein serverseitiger OpenRouter-Key (bewusst pro Benutzer in der UI).
- Kein Build aus dem Quellcode und kein eigener App-Code; verwendet werden die
  offiziellen Upstream-Images.
- Keine Multi-Node-/Cluster-Orchestrierung.
- Kein automatisches PostgreSQL-Major-Upgrade.

## 3. Entscheidungen

| Thema | Entscheidung | Begründung |
|---|---|---|
| Standard-Plattform | LXC (Debian 13, unprivileged) | leichtgewichtig, nah an Community Scripts |
| Alternative | `--vm` → Ubuntu 24.04 Cloud-Init-VM | Fallback bei Docker-/Storage-Sonderfällen |
| Installation | Docker Compose, `amruthpillai/reactive-resume` + `postgres:18` | offiziell dokumentierter, updatebarer Pfad |
| LXC-Ressourcen | 2 vCPU / 4 GB / 16 GB | Postgres + Node + Docker; 2 GB sind zu knapp |
| VM-Ressourcen | 2 vCPU / 4 GB / 20 GB | Cloud-Image + Docker-Overhead |
| Port | 3000 (konfigurierbar) | Upstream-Default |
| AI | `ENCRYPTION_SECRET` setzen, OpenRouter-Key in der UI | kein Secret in Shell-History/Logs |
| Dienst | systemd-Unit, die `docker compose up` im Vordergrund hält | `Restart=always` greift auch bei Container-Absturz |
| Framework | eigenständiges Script, kein `build.func`-Import | reproduzierbar, keine Remote-Abhängigkeit |
| ID-Vergabe | kleinste freie ID ≥ 100, CT und VM gemeinsam betrachtet | „nächste freie ID“ |
| Namensschema | `reactive-resume`, bei Kollision `reactive-resume-<ID>` | DNS-konform, eindeutig |

## 4. Architektur

```text
Proxmox-Host
└── install/reactive-resume.sh          # Root, erzeugt CT oder VM
    ├── LXC: pct create/start/exec
    └── VM:  qm create/importdisk/cloud-init/ssh
        └── install/reactive-resume-inner.sh   # läuft im Gast als root
            ├── Docker CE + Compose-Plugin
            ├── /opt/reactive-resume/compose.yml
            ├── /opt/reactive-resume/.env         (chmod 600)
            ├── Named Volume reactive_resume_data → /app/data
            ├── systemd/reactive-resume.service
            └── Healthcheck /api/health
```

Host- und Innenscript sind getrennt, damit derselbe Provisionierungs-Code für
LXC und VM gilt. Das Innenscript ist auch allein lauffähig (z. B. auf einem
normalen Debian/Ubuntu-Host) und wird per `pct push` bzw. `scp` übertragen.

## 5. Repo-Struktur

```text
ReactiveResume-Proxmox/
├── install/
│   ├── reactive-resume.sh          # Host-Installer (LXC default, --vm)
│   └── reactive-resume-inner.sh    # In-Guest-Provisionierung
├── compose/
│   └── compose.yml                 # app + postgres
├── systemd/
│   └── reactive-resume.service     # @APP_DIR@-Platzhalter
├── tests/
│   ├── static-checks.sh            # ohne Proxmox ausführbar
│   └── reboot-test.sh              # CT/VM-Reboot + Health-Verifikation
├── docs/superpowers/specs/…        # dieses Dokument
└── README.md
```

## 6. Host-Installer

### 6.1 Ablauf

1. **Vorprüfung:** `id -u == 0`, `pct`, `qm`, `pvesm`, `/etc/pve`, Bridge existiert.
2. **Logging:** `tee` nach `/var/log/reactive-resume-proxmox-install.log`, `set -Eeuo pipefail`, ERR-Trap.
3. **ID:** `--vmid` validieren (≥ 100) oder kleinste freie ID ≥ 100 suchen; belegt = `pct status` **oder** `qm status` erfolgreich.
4. **Modus:**
   - Default LXC: Template suchen/downloaden (`debian-13-standard_*_amd64.tar.zst`, Fallback Debian 12), `pct create`, `pct start`.
   - `--vm`: Ubuntu-Cloud-Image, `qm create`, `qm importdisk`, Cloud-Init (SSH-Key, DHCP oder statisch), `qm start`.
5. **IP ermitteln** (LXC: `pct exec … ip -4`; VM: Guest Agent, dann ARP/Neighbor-Scan), mit Timeout und Retry.
6. **Innenscript übertragen und ausführen** mit `--port`, `--app-url`, `--debug`.
7. **Außen-Verifikation:** HTTP-Status auf `http://<IP>:<PORT>/api/health`.
8. **Zusammenfassung:** ID, Name, Ressourcen, IP, URL, Service-/Log-/Update-/Uninstall-Befehle.

### 6.2 LXC-Erzeugung

```text
pct create <ID> <template> \
  --hostname reactive-resume \
  --cores 2 --memory 4096 --swap 512 \
  --rootfs <storage>:16 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=0 \
  --nameserver 1.1.1.1 \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 --onboot 1 \
  --password <zufällig> \
  --description "Reactive Resume – installiert von <Repo>"
```

- Root-Passwort zufällig (`openssl rand`), Ausgabe einmalig und Ablage in
  `/root/reactive-resume.creds` (chmod 600).
- Statische IP optional: `--ip 192.168.1.50/24 --gw 192.168.1.1` ersetzt `ip=dhcp`.
- `onboot: 1` ist Pflicht (Reboot-Sicherheit).

### 6.3 VM-Erzeugung (`--vm`)

Analog zum bestehenden WebODM-Installer: Cloud-Image nach
`/var/lib/vz/template/iso`, SSH-Key unter `/root/.ssh/reactive-resume_vm_ed25519`,
`qm set --ciuser ubuntu --sshkeys … --ipconfig0 ip=dhcp`, Guest Agent aktiv.
Update-Modus erkennt eine bestehende VM an `qm config | grep -qi reactive-resume`.

### 6.4 Update-/Idempotenzpfad

Existiert die Ziel-ID bereits:

- CT: prüfen, dass es ein Container ist; `pct set --onboot 1 --features nesting=1,keyctl=1`; starten falls gestoppt.
- VM: prüfen, dass es eine VM mit passender Beschreibung ist; starten falls gestoppt.
- Anschließend **immer** das Innenscript erneut ausführen.
- Ohne `--force` wird eine fremde ID nicht überschrieben, sondern mit Fehler beendet.

## 7. In-Guest-Provisionierung

### 7.1 Ablauf

1. Root-Check, Log `/var/log/reactive-resume-install.log`, ERR-Trap.
2. Pakete: `ca-certificates curl gnupg openssl`, Docker CE + Compose-Plugin
   (`get.docker.com`), `systemctl enable --now docker`.
3. Verzeichnis `/opt/reactive-resume` (`root:root 0755`) für `compose.yml` und `.env` (`0600`). Nutzdaten liegen ausschließlich in den Named Volumes `postgres_data` und `reactive_resume_data`, nicht im Projektverzeichnis.
4. IP/bzw. `--app-url` bestimmen; `APP_URL` ohne Slash am Ende.
5. `.env` schreiben **oder ergänzen**:
   - Neu: `POSTGRES_PASSWORD`, `AUTH_SECRET`, `ENCRYPTION_SECRET` per `openssl rand -hex 32`.
   - Bestehend: Secrets und DB-Passwort unverändert übernehmen; nur `APP_URL` und `PORT` aktualisieren.
6. `compose.yml` aus dem Repo installieren (bei lokalem Aufruf aus `compose/`, sonst per `RAW_BASE`).
7. `docker compose pull`, `docker compose up -d --wait` (Timeout 300 s).
8. systemd-Unit schreiben (`@APP_DIR@` ersetzt), `daemon-reload`, `enable --now`.
9. Verifikation: `systemctl is-active`, Container-Status, `curl 127.0.0.1:<PORT>/api/health` (max. 60 × 2 s).
10. Falls `ufw` aktiv: `ufw allow <PORT>/tcp`.

### 7.2 `.env` (Auszug)

```dotenv
APP_URL="http://192.168.1.50:3000"
PORT="3000"
POSTGRES_PASSWORD="<generiert>"
DATABASE_URL="postgresql://postgres:<generiert>@postgres:5432/postgres"
AUTH_SECRET="<generiert>"
ENCRYPTION_SECRET="<generiert>"
```

`AUTH_SECRET` und `ENCRYPTION_SECRET` müssen verschieden sein. Beide bleiben
über Updates hinweg unverändert; das ist Voraussetzung dafür, dass Sessions,
2FA und gespeicherte AI-Keys gültig bleiben.

### 7.3 `compose.yml`

- `postgres:18`, Named Volume `postgres_data:/var/lib/postgresql`, Healthcheck `pg_isready`.
- `amruthpillai/reactive-resume:<tag>` (Default `latest`), `ports: ["${PORT}:3000"]`,
  `env_file: .env`, Volume `reactive_resume_data:/app/data`,
  `depends_on: postgres: condition: service_healthy`, `restart: unless-stopped`.
- Keine Veröffentlichung von 5432.

## 8. systemd-Unit

```ini
[Unit]
Description=Reactive Resume
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=@APP_DIR@
ExecStart=/usr/bin/docker compose up --remove-orphans
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=10
TimeoutStartSec=600
Environment=COMPOSE_PROJECT_NAME=reactive-resume

[Install]
WantedBy=multi-user.target
```

`docker compose up` läuft im Vordergrund; beendet sich Compose (z. B. weil ein
Container dauerhaft ausfällt), startet systemd den Dienst neu. `enable` +
`onboot: 1` decken den Reboot-Fall ab.

## 9. OpenRouter

- Der Installer setzt ausschließlich `ENCRYPTION_SECRET`.
- Key-Eingabe danach: **Settings → AI & developer → Add provider → OpenRouter**,
  Modell z. B. `openai/gpt-4.1` (muss Tool-Calling unterstützen), „Save and test“.
- Base URL wird von der App vorbelegt (`https://openrouter.ai/api/v1`); kein
  `AI_BASE_URL` in der `.env`.
- Ohne Key bleiben alle AI-Funktionen deaktiviert; die App ist voll nutzbar.
- Der Key wird mit AES-256-GCM verschlüsselt in PostgreSQL gespeichert; ohne
  `ENCRYPTION_SECRET` bietet die UI die Provider-Eingabe nicht an.

## 10. Fehlerbehandlung und Debugging

### 10.1 Host

`set -Eeuo pipefail` plus `trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR`.
Bei Fehler werden ausgegeben:

1. fehlgeschlagenes Kommando, Zeile, Exit-Code,
2. Pfad des vollständigen Host-Logs,
3. Status und Config der betroffenen ID (`pct status`/`qm status`),
4. die letzten 200 Zeilen des Innen-Logs (per `pct exec`/`ssh`, falls erreichbar),
5. Diagnosebefehle (`pct enter <ID>`, `journalctl -u reactive-resume -n 200`,
   `docker compose logs --tail=200`),
6. Hinweis, das Script mit `--debug` (`set -x`) erneut auszuführen.

Der Container/VM wird bei einem Fehler **nicht** automatisch zerstört, damit die
Fehlerkette untersucht werden kann. `--force` ist nur für den Überschreibpfad.

### 10.2 In-Guest

Gleiches Trap-Muster. Zusätzlich bei Fehler:

- `docker compose ps`,
- `docker compose logs --tail=200` (app und postgres),
- `systemctl status reactive-resume --no-pager`,
- `journalctl -u reactive-resume -n 100 --no-pager`,
- letzte 100 Zeilen des Installer-Logs,
- `.env` mit maskierten Secrets (`POSTGRES_PASSWORD`, `AUTH_SECRET`, `ENCRYPTION_SECRET` → `***`).

Jede Fehlermeldung enthält die vollständige Kette, nicht nur die letzte Zeile.

## 11. Verifikation

Erfolg wird nur gemeldet, wenn **alle** Punkte zutreffen:

| Prüfung | Bedingung |
|---|---|
| Container/VM | `pct status`/`qm status` = `running` |
| `onboot` | `pct config`/`qm config` enthält `onboot: 1` |
| Dienst | `systemctl is-active reactive-resume` = `active` |
| Compose | app- und postgres-Container `running`/`healthy` |
| Health innen | HTTP 200 und `"status":"healthy"` von `127.0.0.1:<PORT>/api/health` |
| Health außen | HTTP 200 von `http://<IP>:<PORT>/api/health` |
| Web-UI | HTTP 200/302 von `http://<IP>:<PORT>/` |

Schlägt die Außenprüfung fehl, ist das ein Fehler (Exit ≠ 0), keine Warnung.
Abschlussausgabe enthält ID, IP, URL und alle Verwaltungsbefehle.

## 12. Tests

- `tests/static-checks.sh` (ohne Proxmox lauffähig):
  `bash -n` für alle Scripts, `shellcheck -S warning` falls vorhanden,
  Ausführbarkeit, Existenz von Unit/Compose/README, Pflichtstrings
  (`pct create`, `onboot`, `nesting=1`, `ENCRYPTION_SECRET`, `api/health`),
  Unit-Platzhalter und Substitution, `docker compose config` falls Docker da ist.
- `tests/reboot-test.sh <ID> [IP] [PORT]`:
  erkennt CT/VM, prüft Dienst + Health, führt `pct reboot`/`qm reboot` aus,
  wartet auf Erreichbarkeit und prüft Dienst + Health erneut; gibt bei jedem
  Schritt die Logausgabe aus.
- **Grenze der Entwicklungsumgebung:** In dieser Sandbox existieren weder
  `pct`/`qm` noch ein Proxmox-Host. Der echte Installations- und Reboot-Test
  muss auf dem Zielhost ausgeführt werden; das Script liefert dafür den Befehl
  und die erwartete Ausgabe. Statische Prüfung und `bash -n` laufen hier.

## 13. Sicherheit

- `.env` und Creds-Datei `0600`, root-owned; Secrets nur einmalig in der Ausgabe.
- Kein Key im Installer, in der Shell-History oder im Log.
- Nur Port `<PORT>` wird veröffentlicht; PostgreSQL bleibt im Compose-Netz.
- Kein TLS: README empfiehlt LAN/VPN oder Reverse Proxy; keine Exposition ins Internet.
- Docker-Socket = root-äquivalent; im README benannt.
- Nach dem ersten eigenen Account: `FLAG_DISABLE_SIGNUPS="true"` in `.env`,
  `docker compose up -d`; im README dokumentiert (nicht automatisch gesetzt,
  sonst wäre die Erstanmeldung unmöglich).

## 14. Bekannte Einschränkung: `APP_URL` und DHCP

`APP_URL` muss exakt der Browser-Adresse entsprechen, sonst schlägt der Login
fehl. Bei DHCP kann sich die IP nach einem Reboot ändern.

- Standard: Installer schreibt die erkannte IP; ein erneuter Lauf aktualisiert `APP_URL`.
- Empfehlung für Dauerbetrieb: `--ip <CIDR> --gw <GW>` (statische IP) oder
  DHCP-Reservation im Router.
- README dokumentiert das hervorgehoben und nennt die Korrektur:
  `.env` anpassen + `docker compose up -d reactive-resume` bzw. Installer erneut ausführen.

## 15. CLI-Optionen

```text
--vmid ID            Ziel-ID (Default: kleinste freie ≥ 100)
--vm                 VM statt LXC erzeugen
--hostname NAME      Hostname (Default: reactive-resume)
--cores N            vCPUs (Default: 2)
--ram MB             RAM in MiB (Default: 4096)
--disk GB            Disk in GiB (Default: 16 LXC / 20 VM)
--storage NAME       Proxmox-Storage (Default: automatisch)
--bridge NAME        Linux-Bridge (Default: vmbr0)
--port N             Web-UI-Port (Default: 3000)
--image REF          App-Image inkl. Tag (Default: amruthpillai/reactive-resume:latest)
--ip CIDR            statische IP inkl. Präfix (z. B. 192.168.1.50/24)
--gw IP              Gateway (nur mit --ip)
--ssh-key PATH       privater SSH-Key (nur VM)
--force              fremde/existierende ID überschreiben
--debug              bash -x + erweiterte Diagnose
-h, --help           Hilfe
```

## 16. Akzeptanzkriterien

1. Einzeiler erzeugt ohne Rückfragen einen lauffähigen LXC mit `onboot: 1`,
   Hostname `reactive-resume` und der nächsten freien ID.
2. `--vm` erzeugt stattdessen eine lauffähige Ubuntu-VM mit identischem Ergebnis.
3. Web-UI antwortet auf `http://<IP>:3000/`; `/api/health` liefert HTTP 200.
4. `systemctl is-active reactive-resume` ist `active`; `Restart=always` ist gesetzt.
5. Reboot von CT/VM: Dienst und Web-UI sind danach ohne Eingriff wieder erreichbar.
6. Erneuter Lauf mit derselben ID aktualisiert Images/Unit, ohne Daten oder Secrets zu verlieren.
7. OpenRouter lässt sich in der UI mit einem Key verbinden („Save and test“ erfolgreich).
8. Fehlerfälle geben die vollständige Diagnosekette und den `--debug`-Hinweis aus.
9. `bash -n` und `shellcheck` laufen ohne Fehler; `static-checks.sh` ist grün.
10. README enthält Einzeiler, Update-, Reboot-Test- und Deinstallationsanleitung.

## 17. Offene Punkte

Keine. Getroffene Annahmen (Repo-Name, Debian 13, Ressourcen, kein TLS) sind in
Abschnitt 3 festgehalten und können vor der Implementierung korrigiert werden.

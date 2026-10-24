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

- Proxmox VE 8.x, Root-SSH auf dem Host; Debian 13 mit automatischem Fallback auf Debian 12
- Internetzugang des Hosts (Proxmox-Template-Mirror, GitHub, `cloud-images.ubuntu.com`) und des Gasts (apt-Mirrors, `get.docker.com`/`download.docker.com`, Docker Hub, `raw.githubusercontent.com` für `compose.yml` und systemd-Unit)
- Linux-Bridge `vmbr0`
- Storage für `rootdir` und `vztmpl` (LXC) bzw. `images` und lokales ISO-Staging (VM)
- LXC: 2 vCPU / 4 GiB / 16 GiB; VM: 2 vCPU / 4 GiB / 20 GiB

## Schnellstart

Auf dem Proxmox-Host als root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main/install/reactive-resume.sh)"
```

Das Script fragt nichts ab, nimmt die kleinste freie ID ab 100 und zeigt am Ende
ID, IP und URL an. Der Einzeiler lädt das Script von `main`. Schlägt `curl`
fehl, meldet curl den Fehler, aber `bash -c ""` läuft leer durch (Exit 0). Für
einen geprüften Download:

```bash
curl -fsSL -o /tmp/reactive-resume.sh https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main/install/reactive-resume.sh \
  && sudo bash /tmp/reactive-resume.sh
```

Lokal:

```bash
git clone https://github.com/HatchetMan111/ReactiveResume-Proxmox.git
cd ReactiveResume-Proxmox
sudo bash install/reactive-resume.sh
```

Bei einem lokalen Klon werden `compose/compose.yml` und
`systemd/reactive-resume.service` aus dem Repo in den Gast übertragen. Der
Einzeiler lädt dieselben Dateien von `main`; ein lokaler Klon ist daher die
verlässliche Variante für nicht veröffentlichte Änderungen.

## Optionen

```text
--vmid ID            Ziel-ID (Default: kleinste freie >= 100)
--vm                 VM statt LXC
--hostname NAME      Hostname (Default: reactive-resume)
--cores N            vCPUs (Default: 2)
--ram, --memory MB   RAM in MiB (Default: 4096)
--disk GB            Disk in GiB (Default: 16 LXC / 20 VM)
--storage NAME       Proxmox-Storage (Default: automatisch)
--bridge NAME        Bridge (Default: vmbr0)
--port N             Web-UI-Port (Default: 3000)
--image REF          App-Image (Default: amruthpillai/reactive-resume:latest)
--ip CIDR            statische IP inkl. Präfix
--gw IP              Gateway (nur mit --ip)
--ssh-key PATH       privater SSH-Key (nur VM)
--force              fremde/existierende ID in-place übernehmen (kein Neuaufbau);
                     VM: verwendeter SSH-Key muss im Gast bereits autorisiert sein
--debug              bash -x + erweiterte Diagnose
-h, --help           diese Hilfe
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

Aus dem geklonten Repository erneut mit derselben ID ausführen:

```bash
# LXC
bash install/reactive-resume.sh --vmid 105

# VM
bash install/reactive-resume.sh --vmid 105 --vm
```

Einzeiler (Argumente nach dem `_`):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ReactiveResume-Proxmox/main/install/reactive-resume.sh)" _ --vmid 105
# VM: ... _ --vmid 105 --vm
```

Das Script zieht neue Images, schreibt die Unit neu und startet den Dienst. Die
Docker-Volumes (Präfix `reactive-resume_`) bleiben erhalten; Secrets in
`.env` werden nicht neu erzeugt.

Bei bestehenden Gästen werden `--cores`, `--ram` und `--disk` nicht geändert;
die Ausgabe kennzeichnet die Ressourcen als „bestehend“. `--ip`/`--gw` werden
nur bei VMs angewendet. Bei einem bestehenden LXC müssen Netzwerkänderungen
bewusst manuell über `pct set --net0` erfolgen.

## Reboot-Test

```bash
bash tests/reboot-test.sh 105 <IP> 3000
```

Prüft Dienst, Compose, Health, Web-UI (`/`) und `APP_URL` vor und nach
`pct reboot` bzw. `qm reboot`. Ohne IP wird sie automatisch ermittelt.

## Wichtig: APP_URL und DHCP

`APP_URL` muss exakt der Browser-Adresse entsprechen. Bei DHCP kann sich die IP
ändern; dann schlägt der Login fehl.

- Installer erneut ausführen (aktualisiert `APP_URL`), oder
- statische IP verwenden: `--ip 192.168.1.50/24 --gw 192.168.1.1`, oder
- DHCP-Reservation im Router.

Manuell: `APP_URL="http://<neue-ip>:3000"` in `/opt/reactive-resume/.env`
setzen und im Projektverzeichnis neu starten:

```bash
cd /opt/reactive-resume && docker compose up -d reactive-resume
# oder:
systemctl restart reactive-resume
```

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
- Bei neu erstellten LXCs liegen die Root-Zugangsdaten in `/root/reactive-resume-<ID>.creds` (Modus `0600`).
- OpenRouter-Key nur in der UI, verschlüsselt mit `ENCRYPTION_SECRET`.

## Projektstruktur

```text
ReactiveResume-Proxmox/
├── install/reactive-resume.sh
├── install/reactive-resume-inner.sh
├── compose/compose.yml
├── compose/.env.example
├── systemd/reactive-resume.service
├── tests/static-checks.sh
├── tests/inner-functions.sh
├── tests/host-vm.sh
├── tests/host-assets.sh
├── tests/compose-contract.sh
├── tests/reboot-test.sh
├── docs/superpowers/
├── .gitignore
└── README.md
```

## Teststatus

`tests/static-checks.sh` läuft ohne Proxmox (Syntax, Vertrags-Checks,
Env-Erhaltung, ID-Vergabe, `inner-functions`, `host-vm`, `host-assets`). ShellCheck und
`compose-contract` laufen, soweit `shellcheck` bzw. `docker`/`jq` vorhanden
sind. Der echte Installations- und Reboot-Test muss auf einem Proxmox-Host
ausgeführt werden; in der Entwicklungssandbox fehlen `pct` und `qm`.

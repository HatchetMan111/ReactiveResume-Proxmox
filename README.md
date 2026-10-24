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

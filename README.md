# 🎨 ComfyUI Proxmox

Ein-Klick-Installation von [ComfyUI](https://github.com/comfy-org/ComfyUI) (Stable Diffusion / Flux Web-UI) auf einem **Proxmox-VE-Host** – als **VM** mit automatischer IP-Erkennung, systemd-Service und Reboot-Sicherheit. Stil und Verhalten orientieren sich an den [Proxmox Community Scripts](https://community-scripts.github.io/ProxmoxVE/).

## ⚡ Einzeiler (auf dem Proxmox-Host als root)

```bash
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/install.sh -o /tmp/comfyui-install.sh && bash /tmp/comfyui-install.sh
```

> Diese Variante bricht bei einem Download-Fehler sichtbar ab. Das klassische
> `bash -c "$(wget -qLO - ...)"` verschluckt Netzwerkfehler und startet dann
> stillschweigend ein leeres Script.

Das Script:

1. erkennt, dass es auf dem **Host** läuft, und startet `create-vm.sh` (nach Rückfrage)
2. legt eine VM an (Ubuntu 24.04 Cloud-Image, Standard: **8 vCPU / 16 GB RAM / 64 GB Disk**, nächste freie VMID, Name `comfyui`)
3. **prüft Host-RAM, vCPU-Limit und Storage-Platz vorab** und begrenzt die VM automatisch, damit `qm start` nicht mit `Cannot allocate memory` scheitert
4. ermittelt die VM-IP **automatisch** (Gast-Agent → ARP → DHCP-Sniff → Ping-Sweep)
5. installiert **ComfyUI in der VM** per SSH: Python 3.12 (uv), GPU-Treiber, systemd-Service
6. wartet, bis die Web-UI online ist, und zeigt die fertige URL

**Ergebnis:** `http://<VM-IP>:8188`

## 🖥️ GPU-Unterstützung

| GPU am Host | Verhalten |
|---|---|
| **NVIDIA** (empfohlen) | Im Assistenten per PCI-Passthrough durchreichen → Treiber + CUDA-PyTorch werden **automatisch** in der VM installiert |
| AMD / Intel | Passthrough im Assistenten → PyTorch-ROCm/XPU-Wheels + Vulkan-Laufzeit werden installiert (experimentell) |
| keine | CPU-Modus: läuft, aber deutlich langsamer (SD 1.5 okay, SDXL quälend) |

Der GPU-Typ kann in der VM auch erzwungen werden: `GPU_TYPE=nvidia|amd|intel|none`.

> **Voraussetzung für Passthrough:** IOMMU/vfio muss auf dem Host bereits eingerichtet sein (BIOS: VT-d/AMD-Vi aktiv, in GRUB `intel_iommu=on` bzw. `amd_iommu=on`, Devices vfio-pci zugeordnet). Der Assistent warnt davor – ohne das fertige Host-Setup bitte „Nein" wählen und die VM ohne GPU bauen.

## 📦 Modelle

Die Installation bringt **kein Modell** mit (die UI startet sofort, der [ComfyUI-Manager](https://github.com/ltdrdata/ComfyUI-Manager) ist vorinstalliert – Modelle direkt in der UI laden).

Ein Modell direkt mitinstallieren (in der VM):

```bash
DOWNLOAD_MODEL=sd15 bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/install.sh)"
DOWNLOAD_MODEL=sdxl bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/install.sh)"
```

Oder Modell-Dateien einfach nach `/opt/ComfyUI/models/checkpoints/` legen. VRAM-Richtwerte: SD 1.5 ≥ 6 GB, SDXL ≥ 10 GB, Flux ≥ 16 GB.

## 🛠️ Verwaltung (in der VM, per `ssh root@<VM-IP>`)

| Befehl | Wirkung |
|---|---|
| `install.sh --update` | ComfyUI-Code + Abhängigkeiten aktualisieren |
| `install.sh --status` | Service-, GPU- und Web-UI-Status |
| `install.sh --uninstall` | Deinstallieren (Modelle bleiben) |
| `install.sh --uninstall --purge-data` | Komplett inkl. aller Modelle |
| `install.sh --debug` | Installation mit `bash -x` (vollständige Fehlerkette) |
| `journalctl -u comfyui -e` | Service-Logs |
| `systemctl status comfyui` | Service-Status |

Bei nicht-interaktiver Installation den Einzeiler mit `bash -s --` aufrufen, damit Optionen ankommen:

```bash
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/install.sh | bash -s -- --update
```

## ⚙️ VM-Ressourcen anpassen

Auf dem Host, vor oder statt des Assistenten per Umgebungsvariablen:

```bash
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/create-vm.sh -o /tmp/comfyui-create-vm.sh
CORES=12 MEMORY=32768 DISK_SIZE=128 VMID=120 NONINTERACTIVE=1 bash /tmp/comfyui-create-vm.sh
```

- `OS_IMAGE=ubuntu2404|debian12|debian13|ubuntu2204`
- `BIOS=ovmf|seabios` (Standard: automatisch je Image – Ubuntu OVMF, Debian SeaBIOS)
- `IPCONFIG=ip=10.120.1.50/24,gw=10.120.1.1` für eine statische IP (sonst DHCP)
- `PCI_HOSTPCI=01:00` für GPU-Passthrough ohne Assistent

### RAM wird automatisch auf den Host angepasst

QEMU reserviert den kompletten Gast-RAM beim Start. Ist davon auf dem Host zu
wenig frei, bricht `qm start` ab:

```
kvm: cannot set up guest memory 'pc.ram': Cannot allocate memory
```

`create-vm.sh` liest deshalb vor dem Erstellen `MemAvailable` (und bei
`vm.overcommit_memory=2` zusätzlich das freie Commit-Limit), zieht eine
Host-Reserve ab und begrenzt `MEMORY` automatisch. Läuft der Start trotzdem in
einen RAM-Fehler (z. B. weil parallel eine andere VM startet), wird der Gast-RAM
schrittweise halbiert und erneut versucht.

| Variable | Standard | Bedeutung |
|---|---|---|
| `MEMORY` | `16384` | gewünschter VM-RAM in MB (wird bei Bedarf nach unten begrenzt) |
| `MEM_RESERVE_MB` | `2048` | RAM, der für den Proxmox-Host frei bleiben muss |
| `MIN_MEMORY_MB` | `2048` | kleinste Größe, auf die automatisch reduziert werden darf |
| `FORCE_MEMORY=1` | aus | Begrenzung überspringen (Risiko: `qm start` scheitert) |

Ist selbst `MIN_MEMORY_MB` nicht verfügbar, bricht das Script **vor** dem
Anlegen der VM mit einer RAM-Diagnose ab, statt eine unstartbare VM zu
hinterlassen. Mehr Platz schaffen: `qm list`, dann nicht benötigte VMs mit
`qm shutdown <VMID>` stoppen.

### Ablauf testen, wenn der Host klein ist

Für einen reinen Funktionstest (VM anlegen → booten → IP finden → SSH) braucht
es keinen ComfyUI-tauglichen RAM. Mit `SKIP_APP_INSTALL=1` wird die
Installation übersprungen und der Lauf endet nach der SSH-Prüfung:

```bash
FORCE_MEMORY=1 MEMORY=2048 SKIP_APP_INSTALL=1 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/create-vm.sh)"
```

2 GB reichen dafür (ComfyUI selbst braucht später ≥ 8 GB). Danach RAM erhöhen
und die Installation in der VM nachholen:

```bash
qm set <VMID> --memory 8192 --balloon 0
ssh -i /root/.ssh/comfyui_vm_key root@<VM-IP> \
  'bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/install.sh)"'
```

| Variable | Standard | Bedeutung |
|---|---|---|
| `SKIP_APP_INSTALL=1` | aus | nur VM/Boot/Netzwerk/SSH testen, ComfyUI nicht installieren |
| `KEEP_ON_FAILURE=1` | aus | VM bei einem Abbruch nicht automatisch löschen (zum Debuggen) |


## 🔄 Reboot-Sicherheit

- VM: `onboot: 1` (startet mit dem Host)
- Service: `systemctl enable comfyui` + `Restart=always` + `After=network-online.target`
- Bei GPU: nach dem ersten Reboot `nvidia-smi` in der VM prüfen – schlägt es fehl, ist der Treiber/Das Passthrough nicht sauber durchgereicht

## 🧰 Troubleshooting

| Problem | Lösung |
|---|---|
| Install-Script bricht ab | Erneut mit `--debug` ausführen (`bash -x`-Log wird komplett ausgegeben) + Log `/var/log/comfyui-install.log` bzw. `/var/log/comfyui-create-vm-<VMID>.log` |
| `MAX n vcpus allowed per VM on this node` | Host hat weniger Threads als gewählte Cores (bei `cpu=host` Limit). Das Script begrenzt **automatisch** auf die Node-Threads (Build ≥ 2026-11-10-v2); bei älteren Läufen: `qm set <VMID> --cores $(nproc) && qm start <VMID>` |
| `cannot set up guest memory 'pc.ram': Cannot allocate memory` | Auf dem Host ist zu wenig RAM frei. Seit Build **2026-11-11-v1** begrenzt `create-vm.sh` `MEMORY` vorab automatisch und halbiert beim Start notfalls. Manuell: `free -m`, nicht benötigte VMs stoppen, dann `qm set <VMID> --memory 8192 && qm start <VMID>`. Hängengebliebene VM entfernen: `qm destroy <VMID>` |
| `storage ... does not have enough space` | `create-vm.sh` prüft den freien Platz vorab und bricht mit Klartext ab. Anderen Storage via `STORAGE=<id>` wählen oder Platz schaffen. |
| `chpasswd: ... Authentication token manipulation error` | `chpasswd --root` startet im Gast-chroot die PAM-Kette und scheitert dort (fehlendes `/dev`, NSS, Shadow-Rechte). Seit Build **2026-11-11-v2** schreibt `create-vm.sh` den SHA-512-Hash direkt in `/etc/shadow` (PAM-frei). Bei älteren Läufen: VM löschen und neu erstellen. |
| Web-UI nicht erreichbar | `systemctl status comfyui` + `journalctl -u comfyui -e` in der VM; Firewall-Port 8188 (in der VM keine UFW aktiv, am Proxmox-Firewall-Profil prüfen) |
| IP-Erkennung fehlgeschlagen | `qm terminal <VMID>` → `ip a`; danach install.sh direkt in der VM ausführen |
| `nvidia-smi` fehlt in der VM | Passthrough-Konfig am Host prüfen (IOMMU!); VM-Reboot; `lspci | grep -i nvidia` in der VM |
| CPU-Modus trotz GPU | `GPU_TYPE=nvidia install.sh` erneut ausführen |

## 📁 Struktur

| Datei | Zweck |
|---|---|
| `install.sh` | Router: auf dem Host → Handoff zu `create-vm.sh`; in der VM → ComfyUI-Installation |
| `create-vm.sh` | VM-Erstellung (Cloud-Image, IP-Erkennung, SSH-Handoff) |
| `uninstall.sh` | Deinstallation (Modell-Daten wahlweise behalten) |

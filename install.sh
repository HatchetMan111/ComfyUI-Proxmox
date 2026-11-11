#!/usr/bin/env bash
# =============================================================================
# ComfyUI Proxmox Installer
# =============================================================================
# Läuft IN der VM (Debian 12/13 oder Ubuntu 22.04/24.04) und installiert
# ComfyUI (https://github.com/comfy-org/ComfyUI) als systemd-Service:
#
#   - Python 3.12 venv via uv (unabhängig vom System-Python)
#   - GPU-Typ-Autoerkennung (NVIDIA / AMD / Intel / CPU) und passende
#     PyTorch-Wheels (CUDA / ROCm / XPU / CPU)
#   - ComfyUI-Manager als Custom-Node (Benutzerverwaltung, Node-Installer)
#   - systemd-Unit 'comfyui' -> Web-UI auf http://<VM-IP>:8188 (0.0.0.0)
#   - Reboot-sicher (Restart=always, After=network-online.target)
#
# Aufruf (in der VM als root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/install.sh)"
#
# Auf dem PROXMOX-HOST selbst ausgeführt, lehnt das Script ab und bietet an,
# stattdessen create-vm.sh zu starten (erzeugt die VM und ruft dieses Script
# automatisch in ihr auf).
#
# Umgebungsvariablen (vor dem Aufruf setzen):
#   GPU_TYPE=nvidia|amd|intel|none   GPU-Typ erzwingen (Default: auto)
#   DOWNLOAD_MODEL=sd15|sdxl      Lädt nach der Installation ein Modell
#                                 herunter (Default: keiner - die UI ist
#                                 sofort nutzbar, Modelle können jederzeit
#                                 über den ComfyUI-Manager nachgeladen
#                                 werden)
# =============================================================================
set -euo pipefail

# =============================================================================
# Farben + Ausgabe-Helfer
# =============================================================================
C_INFO='\033[1;34m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'
C_ERR='\033[1;31m'; C_STEP='\033[1;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
info()   { echo -e "${C_INFO}➜${C_RESET} $*"; }
ok()     { echo -e "${C_OK}✔${C_RESET} $*"; }
warn()   { echo -e "${C_WARN}⚠${C_RESET} $*"; }
err()    { echo -e "${C_ERR}✖${C_RESET} $*" >&2; }
die()    { err "$1"; exit 1; }
header() { echo -e "\n${C_STEP}${C_BOLD}━━━ $1 ━━━${C_RESET}"; }

SCRIPT_BUILD="2026-11-11-v2"
APP_NAME="ComfyUI"
APP_REPO="https://github.com/comfy-org/ComfyUI"
APP_DIR="/opt/ComfyUI"
SERVICE_NAME="comfyui"
SERVICE_PORT="8188"
SERVICE_USER="comfyui"
MANAGER_REPO="https://github.com/ltdrdata/ComfyUI-Manager"
ONE_LINER="bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/install.sh)\""
CREATE_VM_URL="https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/create-vm.sh"

# Deboge einzeilig umschalten: install.sh --debug schaltet bash -x ab hier ein
DEBUG_MODE=0

# Fallback für 'bash -c "$(wget -qLO - URL)" --flag': dort belegt $0 das erste
# Argument nach dem Script-String ($0 beginnt dann mit '-') - die Optionen
# stehen dann in "$0" statt "$@" (Gruben-Wissen OpenMausBot e58e719).
if [[ "${1:-}" == "" && "${0:-}" == -* ]]; then
  set -- "$0"
fi

# =============================================================================
# Fehler-Transparenz: bei JEDEM Abbruch die komplette Kette zeigen
# =============================================================================
err_chain() {
  local ec=$?
  echo -e "\n${C_ERR}✖ FEHLER: Exit-Code ${ec}. Letzte Befehle (vollständige Kette):${C_RESET}" >&2
  echo -e "${C_ERR}  Zeile   : ${BASH_LINENO[0]:-?}${C_RESET}" >&2
  echo -e "${C_ERR}  Befehl  : ${BASH_COMMAND:-?}${C_RESET}" >&2
  echo -e "${C_ERR}  Funktion: ${FUNCNAME[1]:-main}${C_RESET}" >&2
  echo -e "${C_ERR}  Log     : ${LOG_FILE:-kein Log aktiv}${C_RESET}" >&2
  echo -e "${C_ERR}  Mit bash -x wiederholen: ${ONE_LINER} --debug${C_RESET}" >&2
}
trap err_chain ERR

LOG_FILE="${LOG_FILE:-/var/log/${SERVICE_NAME}-install.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
# Ohne root (z.B. 'install.sh --help') ist /var/log nicht beschreibbar - dann
# lieber ohne Log weiterlaufen als mit 'tee: Permission denied' zu starten.
if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
  LOG_FILE=""
fi
if [ -n "$LOG_FILE" ]; then
  # shellcheck disable=SC2094
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

usage() {
  cat <<EOF
${C_BOLD}ComfyUI Proxmox Installer (in-VM) – Build ${SCRIPT_BUILD}${C_RESET}

Aufruf:  install.sh [--update|--status|--uninstall|--purge-data|--debug|--help]

  (ohne Argument)  Vollständige Installation (idempotent - wiederaufrufbar)
  --update         ComfyUI-Code + Abhängigkeiten aktualisieren, Service neu starten
  --status         Service-/Web-UI-Status anzeigen
  --uninstall      Service + ComfyUI entfernen (Modelle behalten)
  --purge-data     Zusätzlich ALLE Modelle/Daten löschen
  --debug          bash -x-Debugging aktivieren (vollständige Fehlerkette)
  --help           Diese Hilfe

Umgebungsvariablen:
  GPU_TYPE=nvidia|amd|intel|none   GPU-Typ erzwingen (Default: automatisch per lspci)
  DOWNLOAD_MODEL=sd15|sdxl   Modell herunterladen (Default: keiner)
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --update)      MODE="update" ;;
      --status)      MODE="status" ;;
      --uninstall)   MODE="uninstall" ;;
      --purge-data)  MODE="uninstall" PURGE_DATA=1 ;;
      --debug)       DEBUG_MODE=1 ;;
      --help|-h)     usage; exit 0 ;;
      *) err "Unbekannte Option: $1"; usage; exit 1 ;;
    esac
    shift
  done
}

# =============================================================================
# Host-Routing: auf dem Proxmox-Host hat dieses Script nichts verloren
# =============================================================================
is_proxmox_host() {
  [ -f /etc/pve/.version ] || command -v pveversion >/dev/null 2>&1
}

# Auch unter 'curl | bash' oder nach der Log-Umleitung (tee) gibt es oft noch
# ein echtes Terminal - dann darf der Assistent angeboten werden. [ -t 0 ]
# allein wäre hier zu streng.
have_tty() {
  { : >/dev/tty; } 2>/dev/null
}

handle_proxmox_host() {
  header "Proxmox-Host erkannt"
  warn "Dieses Script installiert ${APP_NAME} IN einer VM und muss dort laufen."
  warn "Auf dem Host läuft es ins Leere (kein systemd-Service-Scope, falsches Ziel)."

  if [ "${NONINTERACTIVE:-0}" != "1" ] && have_tty; then
    echo
    info "Der zugehörige VM-Ersteller create-vm.sh kann das übernehmen:"
    info "  - legt eine Debian/Ubuntu-VM an (Standard: 8 vCPU, 16 GB RAM, 64 GB Disk)"
    info "  - ermittelt automatisch die IP-Adresse der VM"
    info "  - ruft dieses install.sh anschließend automatisch IN der VM auf"
    echo
    if read -r -t 60 -p "Jetzt create-vm.sh herunterladen und ausführen? [j/N] " answer </dev/tty; then
      case "$answer" in
        j|J|y|Y|ja|Ja|yes|Yes)
          info "Lade create-vm.sh herunter und starte es..."
          curl -fsSL --retry 3 --retry-delay 2 "${CREATE_VM_URL}" -o /tmp/comfyui-create-vm.sh
          # install.sh spiegelt stdout bereits in 'tee' - dadurch wäre [ -t 1 ]
          # im Kind false und create-vm.sh würde den whiptail-Assistenten
          # überspringen (und still den 16-GB-Default nehmen). Deshalb die
          # echten Terminal-Descriptors wiederherstellen, wenn vorhanden.
          if [ -e /dev/tty ]; then
            exec bash /tmp/comfyui-create-vm.sh </dev/tty >/dev/tty 2>&1
          else
            exec bash /tmp/comfyui-create-vm.sh
          fi
          ;;
      esac
    fi
  fi

  echo
  info "Manuell ausführen (auf dem Host als root):"
  echo "    bash -c \"\$(curl -fsSL ${CREATE_VM_URL})\""
  echo
  die "Abgebrochen. Das Script gehört in eine VM - siehe Anleitung oben."
}

# =============================================================================
# Vorabprüfungen
# =============================================================================
check_prerequisites() {
  [ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen (z.B. per SSH in der VM)."
  command -v systemctl >/dev/null 2>&1 || die "systemd nicht gefunden - dieses Script braucht ein normales Linux (Debian/Ubuntu)."

  # Platz VOR dem apt-Lauf prüfen: PyTorch + Abhängigkeiten brauchen ~15 GB.
  # Ohne diese Prüfung läuft apt 10 Minuten und stirbt dann mitten im
  # Entpacken mit "No space left on device" (Live-Fall 2026-11-11: VM mit
  # 3,3-GB-Dateisystem, weil die Partition nie vergrößert wurde).
  local free_mb free_gb
  free_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
  free_gb=$(( ${free_mb:-0} / 1024 ))
  if [ "${free_mb:-0}" -lt 10240 ]; then
    err "Nur ${free_gb} GB (${free_mb} MB) frei auf / - PyTorch + ComfyUI brauchen ~15 GB."
    err "Auf dem Proxmox-Host vergrößern und danach in der VM das Dateisystem ziehen:"
    err "  qm resize <VMID> scsi0 +20G"
    err "  # in der VM: growpart /dev/sda 1 && resize2fs /dev/sda1"
    die "Zu wenig Platz - Installation abgebrochen (nichts wurde verändert)."
  elif [ "${free_mb:-0}" -lt 20480 ]; then
    warn "Nur ${free_gb} GB frei - genug für ComfyUI + PyTorch, aber ohne große Modelle."
  fi

  command -v curl >/dev/null 2>&1 || {
    info "curl fehlt - installiere es..."
    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates || die "curl konnte nicht installiert werden."
  }
  ok "Läuft als root mit systemd."
}

# =============================================================================
# Basispakete
# =============================================================================
install_base_packages() {
  header "Basispakete installieren"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "apt-get update hatte Probleme (Netzwerk/Repo) - fahre fort."
  local pkgs=(git curl wget ca-certificates build-essential python3 python3-venv \
              pciutils ffmpeg fontconfig libgl1 libglib2.0-0 libsm6 libxext6 \
              libxrender1 unzip tzdata)
  # time_t-Transition (Debian 13, Ubuntu 24.04): Paket heißt libglib2.0-0t64.
  # Dynamisch per apt-cache entscheiden statt OS-String-Spezulation.
  if apt-cache show libglib2.0-0t64 >/dev/null 2>&1; then
    pkgs=("${pkgs[@]/libglib2.0-0/libglib2.0-0t64}")
  fi
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"; then
    warn "Ein Paketblock schlug fehl - zweiter Versuch ohne libgl1-Paketliste..."
    local base=(git curl wget ca-certificates build-essential python3 python3-venv pciutils unzip tzdata)
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${base[@]}" || die "Basispakete konnten nicht installiert werden (apt-Fehler oben - komplette Kette beachten)."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg fontconfig libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 || warn "Grafik-/Video-Bibliotheken fehlen teilweise - ComfyUI läuft trotzdem, manche Nodes evtl. nicht."
  fi
  ok "Basispakete stehen."
}

install_guest_agent() {
  header "QEMU-Gast-Agent (für saubere IP-Erkennung in Proxmox)"
  if command -v qemu-ga >/dev/null 2>&1; then
    ok "Gast-Agent bereits installiert."
    return 0
  fi
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-guest-agent; then
    systemctl enable --now qemu-guest-agent 2>/dev/null || warn "Gast-Agent-Service konnte nicht gestartet werden (Best Effort)."
    ok "Gast-Agent installiert."
  else
    warn "Gast-Agent konnte nicht installiert werden (Best Effort, kein Abbruch)."
  fi
  return 0
}

# =============================================================================
# GPU-Erkennung + Treiber + PyTorch-Index
# =============================================================================
detect_gpu_type() {
  # Rückgabe in GPU_DETECTED (global): nvidia | amd | intel | none
  GPU_DETECTED="none"
  if lspci 2>/dev/null | grep -qiE 'nvidia'; then
    GPU_DETECTED="nvidia"
  elif lspci 2>/dev/null | grep -qiE 'amd|ati|radeon'; then
    GPU_DETECTED="amd"
  elif lspci 2>/dev/null | grep -qiE 'intel.*(vga|display|graphics|iris|xe)'; then
    GPU_DETECTED="intel"
  fi
  return 0
}

install_nvidia_driver() {
  local os_id os_ver
  os_id="$(. /etc/os-release && echo "$ID")"
  os_ver="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  info "NVIDIA-GPU erkannt - installiere proprietären Treiber (${os_id} ${os_ver})..."

  if command -v nvidia-smi >/dev/null 2>&1; then
    ok "nvidia-smi existiert bereits - Treiber überspringen."
    return 0
  fi

  if [ "$os_id" = "ubuntu" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ubuntu-drivers-common || die "ubuntu-drivers-common fehlgeschlagen."
    if ! ubuntu-drivers autoinstall; then
      warn "ubuntu-drivers autoinstall schlug fehl - Fallback: nvidia-driver-570-server..."
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-driver-570-server nvidia-utils-570-server \
        || die "NVIDIA-Treiberinstallation fehlgeschlagen (apt-Fehler oben beachten)."
    fi
  else
    # Debian: non-free-firmware/non-free nötig
    if ! grep -qs 'non-free' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
      info "non-free-Komponenten fehlen - ergänze..."
      sed -i -E 's/^([[:space:]]*deb .*(main|main contrib)[[:space:]]*)$/\1 contrib non-free non-free-firmware/' \
        /etc/apt/sources.list 2>/dev/null || true
      for f in /etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] && sed -i -E 's/^(Components:.*)$/\1 contrib non-free non-free-firmware/' "$f" || true
      done
      apt-get update -qq || true
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-driver nvidia-smi \
      || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-driver \
      || die "NVIDIA-Treiber (Debian) fehlgeschlagen - prüfe die apt-Fehler oben."
  fi

  # Modul laden (in der VM mit Passthrough erst nach Reboot garantiert aktiv)
  modprobe nvidia 2>/dev/null || warn "NVIDIA-Modul konnte nicht sofort geladen werden - nach einem VM-Reboot prüfen (nvidia-smi)."
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    ok "NVIDIA-Treiber aktiv: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  else
    warn "nvidia-smi antwortet noch nicht - normal, wenn der Treiber frisch installiert wurde."
    warn "Nach dem nächsten VM-Reboot muss 'nvidia-smi' funktionieren (Passthrough vorausgesetzt)."
  fi
  return 0
}

install_amd_intel_runtime() {
  local gpu="$1"
  # AMD: Kernel-Treiber (amdgpu) ist im Standardkernel; die ROCm-Runtime kommt
  # mit den PyTorch-Wheels mit. Nötig sind nur Video/Render-Gruppen + Vulkan.
  # Intel XPU: level-zero + OpenCL-Laufzeit (Ubuntu 24.04 packt das direkt).
  info "${gpu} erkannt - installiere Laufzeit-Bibliotheken (Vulkan/Level-Zero, Best Effort)..."
  case "$gpu" in
    amd)   DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libvulkan1 mesa-vulkan-drivers \
             || warn "Vulkan-Bibliotheken fehlgeschlagen (PyTorch-ROCm funktioniert dennoch)." ;;
    intel) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libvulkan1 mesa-vulkan-drivers intel-opencl-icd libze-intel-gpu1 libze1 \
             || warn "Intel-XPU-Laufzeit teilweise fehlgeschlagen (Best Effort)." ;;
  esac
  return 0
}

# PyTorch-Index-URL je GPU-Typ. Primär dynamisch aus der offiziellen
# ComfyUI-README extrahiert (das Projekt aktualisiert die CUDA-Version dort
# regelmäßig) - mit harten Fallbacks, falls der Fetch fehlschlägt.
resolve_pytorch_index() {
  local gpu="$1" readme="" idx=""
  case "$gpu" in
    nvidia) DEFAULT_INDEX="https://download.pytorch.org/whl/cu130" ;;
    amd)    DEFAULT_INDEX="https://download.pytorch.org/whl/rocm6.4" ;;
    intel)  DEFAULT_INDEX="https://download.pytorch.org/whl/xpu" ;;
    none)   DEFAULT_INDEX="https://download.pytorch.org/whl/cpu" ;;
    *)      die "Unbekannter GPU-Typ für PyTorch-Index: ${gpu}" ;;
  esac

  readme="$(curl -fsSL --max-time 20 --retry 2 \
    "${APP_REPO}/raw/main/README.md" 2>/dev/null || true)"
  if [ -n "$readme" ]; then
    idx="$(echo "$readme" | grep -oE 'https://download\.pytorch\.org/whl/(cu[0-9]+|rocm[0-9.]+|xpu)' | head -1 || true)"
    if [ -n "$idx" ]; then
      PYTORCH_INDEX="$idx"
      ok "PyTorch-Index aus der ComfyUI-README ermittelt: ${PYTORCH_INDEX}"
      return 0
    fi
  fi
  PYTORCH_INDEX="$DEFAULT_INDEX"
  warn "README-Extraktion fehlgeschlagen - nutze Standard-Index: ${PYTORCH_INDEX}"
  return 0
}

setup_gpu() {
  header "GPU-Erkennung (Typ: ${GPU_TYPE:-auto})"

  if [ -z "${GPU_TYPE:-}" ]; then
    detect_gpu_type
    GPU_TYPE="$GPU_DETECTED"
    ok "Automatisch erkannt: ${GPU_TYPE}"
  fi

  case "$GPU_TYPE" in
    nvidia) install_nvidia_driver ;;
    amd)    install_amd_intel_runtime amd ;;
    intel)  install_amd_intel_runtime intel ;;
    none)   warn "Keine GPU durchgereicht - ComfyUI läuft im CPU-Modus (deutlich langsamer, für Tests okay)." ;;
    *)      die "Unbekannter GPU_TYPE: ${GPU_TYPE} (erlaubt: nvidia, amd, intel, none)" ;;
  esac

  resolve_pytorch_index "$GPU_TYPE"
  ok "GPU-Setup abgeschlossen (Typ: ${GPU_TYPE})."
}

# =============================================================================
# uv + Python 3.12 venv
# =============================================================================
setup_uv() {
  header "uv (Python-Paketmanager) installieren"
  export UV_PYTHON_INSTALL_DIR="/opt/uv-python"
  export XDG_CACHE_HOME="/opt/uv-cache"
  if [ -x /usr/local/bin/uv ]; then
    ok "uv bereits vorhanden: $(/usr/local/bin/uv --version 2>/dev/null || echo unbekannt)"
    return 0
  fi
  if curl -LsSf --retry 3 --retry-delay 2 https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 \
     && [ -x "$HOME/.local/bin/uv" ]; then
    mv "$HOME/.local/bin/uv" /usr/local/bin/uv
    [ -f "$HOME/.local/bin/uvx" ] && mv "$HOME/.local/bin/uvx" /usr/local/bin/uvx || true
  elif curl -fsSL --retry 3 --retry-delay 2 https://github.com/astral-sh/uv/releases/latest/download/uv-installer.sh | sh >/dev/null 2>&1 \
     && [ -x "$HOME/.local/bin/uv" ]; then
    mv "$HOME/.local/bin/uv" /usr/local/bin/uv
  else
    die "uv-Installation fehlgeschlagen (beide Wege). Netzwerk prüfen: curl -I https://astral.sh"
  fi
  ok "uv installiert: $(/usr/local/bin/uv --version 2>/dev/null || echo unbekannt)"
  return 0
}

# =============================================================================
# ComfyUI-Code
# =============================================================================
deploy_comfyui() {
  header "ComfyUI-Code deployen nach ${APP_DIR}"

  if [ -d "${APP_DIR}/.git" ]; then
    info "Bestehende Installation gefunden - aktualisiere per git pull..."
    git -C "${APP_DIR}" fetch --all --prune || die "git fetch fehlgeschlagen."
    git -C "${APP_DIR}" reset --hard origin/main || die "git reset fehlgeschlagen."
    ok "ComfyUI-Code aktualisiert."
    return 0
  fi

  mkdir -p "${APP_DIR}"
  # In ein temporäres Verzeichnis klonen und dann hineinmergen: Ein direktes
  # 'git clone' in ein vorhandenes /opt/ComfyUI (z.B. nach einer alten,
  # halben Installation) schlägt fehl - und das alte 'rm -rf ${APP_DIR}' im
  # Fallback hätte dabei vorhandene Modelle mitgelöscht.
  local clone_tmp="${APP_DIR}.clone.$$"
  rm -rf "$clone_tmp"
  if ! git clone --depth 1 "${APP_REPO}" "$clone_tmp"; then
    # Fallback: Legacy-Repo-Pfad (comfyanonymous), falls die Org-URL je sperrt
    warn "Clone von comfy-org fehlgeschlagen - Fallback: comfyanonymous/ComfyUI..."
    rm -rf "$clone_tmp"
    git clone --depth 1 "https://github.com/comfyanonymous/ComfyUI.git" "$clone_tmp" || die "ComfyUI-Clone fehlgeschlagen (Netzwerk/DNS prüfen)."
  fi
  # Merge statt Ersetzen: vorhandene Modelle/Checkpoints bleiben erhalten.
  cp -a "$clone_tmp/." "${APP_DIR}/"
  rm -rf "$clone_tmp"
  ok "ComfyUI-Code deployed (Version: $(git -C "${APP_DIR}" log -1 --format='%h %s' 2>/dev/null || echo unbekannt))."
  return 0
}

install_pytorch_and_requirements() {
  header "PyTorch + Abhängigkeiten installieren (GPU-Typ: ${GPU_TYPE})"
  local PY="${APP_DIR}/venv/bin/python"
  # uv-Downloads (Standalone-Python, Wheel-Cache) müssen vom Service-Benutzer
  # lesbar sein - der Service läuft als ${SERVICE_USER}, nicht als root.
  chown -R "${SERVICE_USER}:${SERVICE_USER}" /opt/uv-python /opt/uv-cache 2>/dev/null || true

  if [ ! -x "${PY}" ]; then
    info "Erstelle venv mit Python 3.12 (uv lädt es bei Bedarf eigenständig)..."
    /usr/local/bin/uv venv --python 3.12 "${APP_DIR}/venv" || die "venv-Erstellung fehlgeschlagen."
  else
    info "Bestehendes venv wird in place aktualisiert."
  fi
  # Auch /opt/uv-python nach dem venv-Create chownen: 'uv venv --python 3.12'
  # lädt die Standalone-Python ERST hier herunter (als root).
  chown -R "${SERVICE_USER}:${SERVICE_USER}" /opt/uv-python /opt/uv-cache "${APP_DIR}/venv" 2>/dev/null || true

  local pip_pkgs=(torch torchvision torchaudio)
  info "Installiere PyTorch von ${PYTORCH_INDEX} (je nach Bandbreite mehrere Minuten)..."
  if ! /usr/local/bin/uv pip install --python "${PY}" --index-url "${PYTORCH_INDEX}" "${pip_pkgs[@]}"; then
    if [ "$PYTORCH_INDEX" != "$DEFAULT_INDEX" ]; then
      warn "Installieren vom ermittelten Index fehlgeschlagen - Fallback auf ${DEFAULT_INDEX}..."
      /usr/local/bin/uv pip install --python "${PY}" --index-url "$DEFAULT_INDEX" "${pip_pkgs[@]}" || die "PyTorch-Installation fehlgeschlagen (Index + Fallback). Pip-Fehler oben beachten."
    else
      die "PyTorch-Installation fehlgeschlagen. Pip-Fehler oben beachten (vollständige Kette)."
    fi
  fi

  info "Installiere ComfyUI-requirements.txt..."
  /usr/local/bin/uv pip install --python "${PY}" -r "${APP_DIR}/requirements.txt" || die "requirements.txt fehlgeschlagen."
  ok "PyTorch + Abhängigkeiten stehen (Version: $("${PY}" -c 'import torch; print(torch.__version__)' 2>/dev/null || echo unbekannt))."
}

install_manager() {
  header "ComfyUI-Manager (Custom-Node-Verwaltung)"
  local mgr_dir="${APP_DIR}/custom_nodes/ComfyUI-Manager"
  if [ -d "$mgr_dir/.git" ]; then
    info "Manager vorhanden - aktualisiere..."
    git -C "$mgr_dir" pull --ff-only >/dev/null 2>&1 || warn "Manager-Update fehlgeschlagen (Best Effort)."
    ok "ComfyUI-Manager aktualisiert."
    return 0
  fi
  mkdir -p "${APP_DIR}/custom_nodes"
  if git clone --depth 1 "${MANAGER_REPO}" "$mgr_dir"; then
    ok "ComfyUI-Manager installiert (Custom Nodes + Modelle lassen sich später direkt in der UI verwalten)."
  else
    warn "Manager-Clone fehlgeschlagen - ComfyUI läuft ohne ihn (kein Abbruch)."
  fi
  return 0
}

# =============================================================================
# Service-Benutzer + systemd
# =============================================================================
create_service_user() {
  if id "${SERVICE_USER}" >/dev/null 2>&1; then
    ok "Benutzer ${SERVICE_USER} existiert bereits."
  else
    # --user-group: garantiert die Gruppe 'comfyui', die die systemd-Unit als
    # Group= verwendet. --no-create-home: /opt/ComfyUI existiert bereits.
    useradd --system --user-group --no-create-home --home-dir "${APP_DIR}" --shell /bin/bash "${SERVICE_USER}" \
      || die "Benutzer ${SERVICE_USER} konnte nicht angelegt werden."
    ok "Systembenutzer ${SERVICE_USER} angelegt."
  fi
  # GPU-Zugriff (AMD/Intel/iGPU): video + render Gruppen
  for grp in video render; do
    getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" "${SERVICE_USER}" || true
  done
  chown -R "${SERVICE_USER}:${SERVICE_USER}" "${APP_DIR}"
  return 0
}

setup_services() {
  header "systemd-Service (${SERVICE_NAME}.service, Port ${SERVICE_PORT})"

  # Manager/Modell-Downloads landen später als ${SERVICE_USER} in ${APP_DIR}
  chown -R "${SERVICE_USER}:${SERVICE_USER}" "${APP_DIR}"

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=ComfyUI (Stable Diffusion Web-UI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/main.py --listen 0.0.0.0 --port ${SERVICE_PORT}
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=UV_PYTHON_INSTALL_DIR=/opt/uv-python
Environment=XDG_CACHE_HOME=/opt/uv-cache
# Damit custom_nodes-Installtionen (pip via Manager) nicht ins /root laufen
Environment=HOME=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload || die "systemctl daemon-reload fehlgeschlagen."
  systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1 \
    || warn "Autostart (systemctl enable) konnte nicht aktiviert werden - Service startet trotzdem jetzt."
  info "Starte/Starte neu ${SERVICE_NAME}.service..."
  if ! systemctl restart "${SERVICE_NAME}.service"; then
    err "Service-Start fehlgeschlagen. Letzte Journal-Zeilen:"
    journalctl -u "${SERVICE_NAME}" -n 40 --no-pager >&2 || true
    die "Service '${SERVICE_NAME}' konnte nicht gestartet werden (siehe Journal oben)."
  fi
  ok "Service ${SERVICE_NAME} aktiviert (Restart=always, After=network-online.target, onboot kommt über die VM)."
}

wait_for_comfyui() {
  header "Healthcheck: Web-UI auf localhost:${SERVICE_PORT}"
  info "ComfyUI lädt beim ersten Start Modelle/nodes ein - das kann 1-3 Minuten dauern..."
  local i=0 max=60
  while [ "$i" -lt "$max" ]; do
    if curl -fsS --max-time 5 "http://localhost:${SERVICE_PORT}/system_stats" >/dev/null 2>&1; then
      ok "Web-UI antwortet (HTTP OK auf localhost:${SERVICE_PORT})."
      return 0
    fi
    if [ "$(systemctl is-active "${SERVICE_NAME}" || true)" != "active" ]; then
      err "Service ist NICHT aktiv - Auszug aus dem Journal:"
      journalctl -u "${SERVICE_NAME}" -n 30 --no-pager >&2 || true
      die "Service '${SERVICE_NAME}' läuft nicht mehr (siehe Journal oben)."
    fi
    i=$((i + 1))
    sleep 5
  done
  err "Web-UI antwortete nach $((max * 5 / 60)) Minuten nicht."
  warn "Service-Status: $(systemctl is-active "${SERVICE_NAME}" || echo unbekannt)"
  warn "Letztes Journal:"
  journalctl -u "${SERVICE_NAME}" -n 40 --no-pager >&2 || true
  die "Healthcheck fehlgeschlagen - Logs oben, Service prüfen: journalctl -u ${SERVICE_NAME} -e"
}

# =============================================================================
# Optionaler Modell-Download
# =============================================================================
download_model() {
  header "Optional: Modell herunterladen (${DOWNLOAD_MODEL})"
  local url="" dir="${APP_DIR}/models/checkpoints" file=""
  case "${DOWNLOAD_MODEL}" in
    sd15) url="https://huggingface.co/Comfy-Org/stable-diffusion-v1-5-archive/resolve/main/v1-5-pruned-emaonly-fp16.safetensors"; file="v1-5-pruned-emaonly-fp16.safetensors" ;;
    sdxl) url="https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors"; file="sd_xl_base_1.0.safetensors" ;;
    *) warn "Unbekannter DOWNLOAD_MODEL-Wert: ${DOWNLOAD_MODEL} - überspringe Download."; return 0 ;;
  esac

  [ -f "${dir}/${file}" ] && { ok "Modell bereits vorhanden: ${file}"; return 0; }
  mkdir -p "$dir"
  info "Lade ${file} herunter (kann je nach Modell mehrere GB dauern)..."
  if curl -fL --retry 3 --retry-delay 5 --progress-bar -o "${dir}/${file}.part" "$url"; then
    mv "${dir}/${file}.part" "${dir}/${file}"
    chown "${SERVICE_USER}:${SERVICE_USER}" "${dir}/${file}"
    ok "Modell installiert: ${dir}/${file}"
  else
    rm -f "${dir}/${file}.part" 2>/dev/null || true
    warn "Modell-Download fehlgeschlagen - die UI läuft trotzdem; Modell später via ComfyUI-Manager laden."
  fi
  return 0
}

# =============================================================================
# Zusammenfassung
# =============================================================================
detect_primary_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9]+(\.[0-9]+){3}' | awk '{print $2; exit}' || true)"
  if [ -z "$ip" ]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  [ -n "${ip:-}" ] && echo "$ip"
  return 0
}

print_summary() {
  local vm_ip
  vm_ip="$(detect_primary_ip)"
  echo
  ok "════════════════════════════════════════════════════════════"
  ok "  ${APP_NAME} ist installiert und läuft!"
  ok ""
  if [ -n "$vm_ip" ]; then
    ok "    ${C_BOLD}http://${vm_ip}:${SERVICE_PORT}${C_RESET}"
    ok ""
    ok "  Diese URL in einem beliebigen Browser im Netzwerk öffnen."
  else
    ok "    Web-UI: http://<VM-IP>:${SERVICE_PORT}"
    ok "    (VM-IP herausfinden:  ip a   oder   qm guest cmd <VMID> network-get-interfaces)"
  fi
  ok ""
  ok "  GPU-Typ       : ${GPU_TYPE}$( [ "$GPU_TYPE" = "none" ] && echo ' (CPU-Modus)' )"
  ok "  Installationspfad: ${APP_DIR}"
  ok "  Service       : systemctl status ${SERVICE_NAME}"
  ok "  Logs          : journalctl -u ${SERVICE_NAME} -e"
  ok "  Modelle       : ${APP_DIR}/models/checkpoints/ (oder via ComfyUI-Manager in der UI)"
  ok ""
  ok "  Später aktualisieren (in der VM):"
  ok "    ${ONE_LINER} --update"
  ok "  Status / Deinstallieren:"
  ok "    ${ONE_LINER} --status"
  ok "    ${ONE_LINER} --uninstall"
  ok "════════════════════════════════════════════════════════════"
}

# =============================================================================
# Modi
# =============================================================================
do_status() {
  header "Status"
  echo "  Service      : $(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo unbekannt)"
  echo "  Auto-Start   : $(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || echo unbekannt)"
  if curl -fsS --max-time 5 "http://localhost:${SERVICE_PORT}/system_stats" >/dev/null 2>&1; then
    ok "  Web-UI       : antwortet auf Port ${SERVICE_PORT}"
  else
    warn "  Web-UI       : antwortet NICHT auf Port ${SERVICE_PORT}"
  fi
  if [ -f "${APP_DIR}/venv/bin/python" ]; then
    echo "  ComfyUI      : $(git -C "${APP_DIR}" log -1 --format='%h (%ad)' --date=short 2>/dev/null || echo unbekannt)"
  fi
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  GPU          : /' || true
  local vm_ip
  vm_ip="$(detect_primary_ip)"
  [ -n "$vm_ip" ] && echo "  URL          : http://${vm_ip}:${SERVICE_PORT}"
  return 0
}

do_uninstall() {
  header "Deinstallation"
  [ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen (z.B. per SSH in der VM)."
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  ok "Service gestoppt + entfernt."
  if [ "${PURGE_DATA:-0}" = "1" ]; then
    info "Lösche ${APP_DIR} inklusive aller Modelle (--purge-data)..."
    rm -rf "${APP_DIR}" /opt/uv-python /opt/uv-cache
    ok "Alle Daten gelöscht."
  else
    # WICHTIG: ${APP_DIR} NICHT komplett löschen - dort liegen die Modelle.
    # (Alter Bug: 'rm -rf "${APP_DIR}" "${APP_DIR}/models"' hat trotz
    # gegenteiliger Meldung auch die Modelle vernichtet.)
    info "Lösche Code/venv, behalte Modelle (${APP_DIR}/models bleibt)..."
    if [ -d "${APP_DIR}" ]; then
      find "${APP_DIR}" -mindepth 1 -maxdepth 1 ! -name models -exec rm -rf {} + 2>/dev/null || true
    fi
    ok "Modelle bleiben erhalten in ${APP_DIR}/models."
  fi
  if id "${SERVICE_USER}" >/dev/null 2>&1; then
    userdel "${SERVICE_USER}" 2>/dev/null || warn "Benutzer ${SERVICE_USER} konnte nicht entfernt werden."
    ok "Benutzer ${SERVICE_USER} entfernt."
  fi
  ok "${APP_NAME} deinstalliert. Models-Pfad: $( [ "${PURGE_DATA:-0}" = "1" ] && echo 'gelöscht' || echo "${APP_DIR}/models (falls vorhanden)")"
  return 0
}

do_update() {
  header "Update"
  [ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen (z.B. per SSH in der VM)."
  if [ ! -d "${APP_DIR}/.git" ]; then
    die "Keine bestehende Installation gefunden (${APP_DIR}) - erst normal installieren."
  fi
  deploy_comfyui
  create_service_user
  install_pytorch_and_requirements
  install_manager
  setup_services
  wait_for_comfyui
  print_summary
}

do_install() {
  header "ComfyUI installieren (Build ${SCRIPT_BUILD})"
  check_prerequisites
  install_base_packages
  install_guest_agent
  setup_gpu
  setup_uv
  deploy_comfyui
  create_service_user
  install_pytorch_and_requirements
  install_manager
  setup_services
  wait_for_comfyui
  if [ -n "${DOWNLOAD_MODEL:-}" ]; then
    download_model
  fi
  print_summary
}

main() {
  MODE="install"
  PURGE_DATA=0
  parse_args "$@"

  if [ "$DEBUG_MODE" = "1" ]; then
    set -x
    ok "Debug-Modus (bash -x) aktiv."
  fi

  if is_proxmox_host; then
    if [ "$MODE" = "install" ]; then
      handle_proxmox_host
    else
      err "Dieses Script muss IN der ComfyUI-VM laufen - '--${MODE}' ist auf dem Proxmox-Host nicht sinnvoll."
      die "Bitte per SSH in die VM: ssh root@<VM-IP>   (danach: install.sh --${MODE})"
    fi
  fi

  case "$MODE" in
    install)   do_install ;;
    update)    do_update ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
  esac
}

main "$@"

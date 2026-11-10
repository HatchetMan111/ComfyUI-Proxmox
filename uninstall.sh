#!/usr/bin/env bash
# =============================================================================
# ComfyUI Proxmox - Deinstallation (läuft IN der VM)
# =============================================================================
# Entfernt ComfyUI-Service, -Code und optional die Modelle.
#
# Aufruf (in der VM als root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/uninstall.sh)"
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/ComfyUI-Proxmox/main/uninstall.sh)" --purge-data
# =============================================================================
set -euo pipefail

C_INFO='\033[1;34m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
info() { echo -e "${C_INFO}➜${C_RESET} $*"; }
ok()   { echo -e "${C_OK}✔${C_RESET} $*"; }
warn() { echo -e "${C_WARN}⚠${C_RESET} $*"; }
err()  { echo -e "${C_ERR}✖${C_RESET} $*" >&2; }

APP_DIR="/opt/ComfyUI"
SERVICE_NAME="comfyui"
SERVICE_USER="comfyui"
PURGE_DATA=0

# $0-Fallback (bash -c "$(wget -qLO - URL)" --flag) - Optionen können in $0 stecken
if [[ "${1:-}" == "" && "${0:-}" == -* ]]; then
  set -- "$0"
fi

for arg in "$@"; do
  case "$arg" in
    --purge-data) PURGE_DATA=1 ;;
    --help|-h)
      echo "Aufruf: uninstall.sh [--purge-data]"
      echo "  (ohne)   Service + Code entfernen, Modelle unter ${APP_DIR}/models bleiben in der VM"
      echo "  --purge-data  zusätzlich ALLE Modelle/Daten löschen"
      exit 0
      ;;
    *) err "Unbekannte Option: $arg"; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { err "Bitte als root ausführen."; exit 1; }

info "Stoppe Service ${SERVICE_NAME}..."
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
ok "Service entfernt."

if [ "${PURGE_DATA}" = "1" ]; then
  warn "Lösche ${APP_DIR} KOMPLETT inklusive aller Modelle (--purge-data)..."
  rm -rf "${APP_DIR}"
  rm -rf /opt/uv-python /opt/uv-cache
else
  info "Lösche Code und venv, Modelle bleiben erhalten..."
  find "${APP_DIR}" -mindepth 1 -maxdepth 1 ! -name models -exec rm -rf {} + 2>/dev/null || true
fi

if id "${SERVICE_USER}" >/dev/null 2>&1; then
  userdel "${SERVICE_USER}" 2>/dev/null || warn "Benutzer ${SERVICE_USER} konnte nicht entfernt werden."
  ok "Benutzer ${SERVICE_USER} entfernt."
fi

if [ "${PURGE_DATA}" = "1" ]; then
  ok "ComfyUI komplett deinstalliert (keine Daten verblieben)."
else
  ok "ComfyUI deinstalliert. Modelle liegen weiterhin unter ${APP_DIR}/models (sofern vorhanden)."
fi

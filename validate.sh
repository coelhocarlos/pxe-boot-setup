#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config-pxe.sh
source "$DIR/config-pxe.sh"

ok()   { echo "OK   $1"; }
miss() { echo "MISS $1"; }

log "Validando estrutura"
[ -d "$ISO_DIR" ]  && ok   "pasta de distros: $ISO_DIR"  || miss "pasta de distros $ISO_DIR"
[ -d "$TFTP_DIR" ] && ok   "tftp: $TFTP_DIR"              || miss "tftp $TFTP_DIR"

log "Validando distros"
for f in "$UBUNTU_DESKTOP_ISO" "$UBUNTU_SERVER_ISO" "$WIN11_ISO" "$WIN10_ISO"; do
  [ -s "$ISO_DIR/$f" ] && ok "$f" || miss "$f"
done

log "Validando bootloaders / menu"
[ -f "$TFTP_DIR/pxelinux.0" ]           && ok "pxelinux.0"        || miss "pxelinux.0"
[ -f "$TFTP_DIR/pxelinux.cfg/default" ] && ok "menu pxelinux"     || miss "menu pxelinux"
[ -f "$TFTP_DIR/boot/menu.ipxe" ]       && ok "menu iPXE (EFI)"   || miss "menu iPXE (EFI)"
[ -s "$ISO_DIR/wimboot" ]               && ok "wimboot"           || miss "wimboot"
[ -f "$ISO_DIR/win11/boot.wim" ]        && ok "win11 extras"      || miss "win11 extras"
[ -f "$ISO_DIR/win10/boot.wim" ]        && ok "win10 extras"      || miss "win10 extras"

log "Espaco em disco"
df -h "$TFTP_DIR" "$ISO_DIR" 2>/dev/null | tail -2 || true

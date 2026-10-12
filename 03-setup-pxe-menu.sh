#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config-pxe.sh
source "$DIR/config-pxe.sh"

$SUDO mkdir -p "$TFTP_DIR/pxelinux.cfg" "$TFTP_DIR/ubuntu/desktop" "$TFTP_DIR/ubuntu/server" \
             "$TFTP_DIR/windows" "$TFTP_DIR/boot" "$TFTP_DIR/efi"

UBU_D="$ISO_DIR/$UBUNTU_DESKTOP_ISO"
UBU_S="$ISO_DIR/$UBUNTU_SERVER_ISO"
W10="$ISO_DIR/$WIN10_ISO"
W11="$ISO_DIR/$WIN11_ISO"
UBU26_D="$ISO_DIR/$UBUNTU26_DESKTOP_ISO"
UBU26_S="$ISO_DIR/$UBUNTU26_SERVER_ISO"
KALI="$ISO_DIR/$KALI_LIVE_ISO"

# ---------------------------------------------------------------------------
# Extrai kernel/initrd dos ISOs Ubuntu (casper) para o TFTP.
# O restante (squashfs) e' servido por HTTP via casper url= (sem NFS).
# ---------------------------------------------------------------------------
prep_ubuntu() {
  local iso="$1" tgt="$2" mnt="/mnt/pxe-iso-tmp"
  [ -f "$iso" ] || { warn "ISO ausente: $iso"; return 0; }
  $SUDO mkdir -p "$mnt" "$tgt"
  if $SUDO mount -o loop,ro "$iso" "$mnt" 2>/dev/null; then
    log "Extraindo casper de $(basename "$iso") por mount"
    $SUDO cp -a "$mnt/casper/vmlinuz"    "$tgt/" 2>/dev/null || true
    $SUDO cp -a "$mnt/casper/initrd"     "$tgt/" 2>/dev/null || true
    $SUDO cp -a "$mnt/casper/initrd.gz"  "$tgt/" 2>/dev/null || true
    $SUDO umount "$mnt" 2>/dev/null || true
  else
    info "Mount indisponivel (LXC?) - extraindo com 7z"
    $SUDO 7z x -so "$iso" casper/vmlinuz > "$tgt/vmlinuz" 2>/dev/null || true
    if ! $SUDO 7z x -so "$iso" casper/initrd > "$tgt/initrd" 2>/dev/null; then
      $SUDO 7z x -so "$iso" casper/initrd.gz > "$tgt/initrd.gz" 2>/dev/null && {
        $SUDO gzip -dcf "$tgt/initrd.gz" > "$tgt/initrd" 2>/dev/null
        $SUDO rm -f "$tgt/initrd.gz"
      } || true
    fi
  fi
  $SUDO chmod 644 "$tgt/vmlinuz" "$tgt/initrd" 2>/dev/null || true
  if [ -s "$tgt/vmlinuz" ] && [ -s "$tgt/initrd" ]; then
    log "OK: vmlinuz+initrd em $tgt"
  else
    warn "Faltando vmlinuz/initrd em $tgt"
  fi
}

prep_ubuntu "$UBU_D" "$TFTP_DIR/ubuntu/desktop"
prep_ubuntu "$UBU_S" "$TFTP_DIR/ubuntu/server"
prep_ubuntu "$UBU26_D" "$TFTP_DIR/ubuntu26/desktop"
prep_ubuntu "$UBU26_S" "$TFTP_DIR/ubuntu26/server"

# ---------------------------------------------------------------------------
# Windows via wimboot (iPXE sobre HTTP)
# ---------------------------------------------------------------------------
log "Baixando wimboot"
if [ ! -s "$ISO_DIR/wimboot" ]; then
  $SUDO rm -f "$ISO_DIR/wimboot" "$ISO_DIR/wimboot.tmp"
  if $SUDO wget -q -O "$ISO_DIR/wimboot.tmp" "$WIMBOOT_URL"; then
    $SUDO mv "$ISO_DIR/wimboot.tmp" "$ISO_DIR/wimboot"
  else
    $SUDO rm -f "$ISO_DIR/wimboot.tmp"
    warn "Nao foi possivel baixar wimboot de $WIMBOOT_URL"
  fi
fi

prep_windows() {
  local iso="$1" name="$2" mnt="/mnt/pxe-win-tmp"
  [ -f "$iso" ] || { warn "ISO ausente: $iso"; return 0; }
  local out="$ISO_DIR/$name"
  $SUDO mkdir -p "$mnt" "$out"
  if $SUDO mount -o loop,ro "$iso" "$mnt" 2>/dev/null; then
    log "Extraindo boot do Windows de $(basename "$iso") por mount"
    $SUDO cp -a "$mnt/bootmgr"            "$out/" 2>/dev/null || true
    $SUDO cp -a "$mnt/boot/bcd" "$out/BCD" 2>/dev/null || $SUDO cp -a "$mnt/boot/BCD" "$out/BCD" 2>/dev/null || true
    $SUDO cp -a "$mnt/boot/boot.sdi"      "$out/" 2>/dev/null || true
    $SUDO cp -a "$mnt/boot/fonts"         "$out/fonts" 2>/dev/null || true
    $SUDO cp -a "$mnt/sources/boot.wim"   "$out/" 2>/dev/null || true
    $SUDO cp -a "$mnt/efi/microsoft/boot/bootmgfw.efi" "$out/bootmgfw.efi" 2>/dev/null || true
    $SUDO umount "$mnt" 2>/dev/null || true
  else
    info "Mount indisponivel (LXC?) - extraindo com 7z"
    $SUDO 7z x -so "$iso" bootmgr          > "$out/bootmgr"    2>/dev/null || true
    $SUDO 7z x -so "$iso" boot/bcd         > "$out/BCD"        2>/dev/null || true
    [ -s "$out/BCD" ] || $SUDO 7z x -so "$iso" boot/BCD > "$out/BCD" 2>/dev/null || true
    $SUDO 7z x -so "$iso" boot/boot.sdi    > "$out/boot.sdi"   2>/dev/null || true
    $SUDO 7z x -so "$iso" sources/boot.wim > "$out/boot.wim"   2>/dev/null || true
    $SUDO 7z x -so "$iso" efi/microsoft/boot/bootmgfw.efi > "$out/bootmgfw.efi" 2>/dev/null || true
  fi
  $SUDO chmod -R 755 "$out" 2>/dev/null || true
  [ -s "$out/boot.wim" ] && log "OK: boot.wim em $out" || warn "Faltando boot.wim em $out"

  # script iPXE especifico da versao.
  # Formato minimo: o wimboot extrai bootmgr/BCD do proprio boot.wim.
  # (formato com varios initrd gera "bad cpio magic" no BIOS com iPXE 1.21.1)
  $SUDO tee "$ISO_DIR/$name.ipxe" >/dev/null <<EOF
#!ipxe
set base http://$PXE_IP/distros/$name
kernel http://$PXE_IP/distros/wimboot
initrd \${base}/boot.wim boot.wim
boot
EOF
}

prep_windows "$W11" "win11"
prep_windows "$W10" "win10"

# ---------------------------------------------------------------------------
# Kali Linux (Live/Desktop) - extrai vmlinuz/initrd (TFTP) e squashfs (HTTP)
# ---------------------------------------------------------------------------
log "Extraindo Kali (live)"
if [ -s "$KALI" ]; then
  $SUDO mkdir -p "$TFTP_DIR/kali" "$ISO_DIR/kali"
  $SUDO 7z x -so "$KALI" live/vmlinuz             > "$TFTP_DIR/kali/vmlinuz"      2>/dev/null || true
  $SUDO 7z x -so "$KALI" live/initrd.img          > "$TFTP_DIR/kali/initrd.img"   2>/dev/null || true
  $SUDO 7z x -so "$KALI" live/filesystem.squashfs > "$ISO_DIR/kali/filesystem.squashfs" 2>/dev/null || true
  $SUDO chmod 644 "$TFTP_DIR/kali/vmlinuz" "$TFTP_DIR/kali/initrd.img" "$ISO_DIR/kali/filesystem.squashfs" 2>/dev/null || true
  if [ -s "$TFTP_DIR/kali/vmlinuz" ] && [ -s "$TFTP_DIR/kali/initrd.img" ] && [ -s "$ISO_DIR/kali/filesystem.squashfs" ]; then
    log "OK: kali/vmlinuz+initrd.img (TFTP) e kali/filesystem.squashfs (HTTP)"
  else
    warn "Kali: faltando vmlinuz/initrd.img/squashfs (verifique o nome dos arquivos no ISO)"
  fi
else
  warn "ISO Kali ausente: $KALI"
fi

# ipxe com wimboot tambem na arvore TFTP (alguns clientes BIOS)
$SUDO cp "$ISO_DIR/wimboot" "$TFTP_DIR/boot/" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Menu PXELINUX
# ---------------------------------------------------------------------------
log "Gerando menu pxelinux"
$SUDO tee "$TFTP_DIR/pxelinux.cfg/default" >/dev/null <<MENU
DEFAULT menu.c32
PROMPT 0
TIMEOUT 300
ONTIMEOUT local

MENU TITLE PXE BOOT - $PXE_IP

LABEL local
  MENU LABEL ^1) Boot Local HD
  LOCALBOOT 0

MENU SEPARATOR

LABEL ubuntu-desktop
  MENU LABEL ^2) Ubuntu 24.04 Desktop (live via HTTP)
  KERNEL ubuntu/desktop/vmlinuz
  APPEND initrd=ubuntu/desktop/initrd ip=dhcp boot=casper url=http://$PXE_IP/distros/$UBUNTU_DESKTOP_ISO quiet splash ---

LABEL ubuntu-server
  MENU LABEL ^3) Ubuntu 24.04 Server (live via HTTP)
  KERNEL ubuntu/server/vmlinuz
  APPEND initrd=ubuntu/server/initrd ip=dhcp boot=casper url=http://$PXE_IP/distros/$UBUNTU_SERVER_ISO quiet ---

LABEL ubuntu26-desktop
  MENU LABEL ^4) Ubuntu 26.04 Desktop (live via HTTP)
  KERNEL ubuntu26/desktop/vmlinuz
  APPEND initrd=ubuntu26/desktop/initrd ip=dhcp boot=casper url=http://$PXE_IP/distros/$UBUNTU26_DESKTOP_ISO quiet splash ---

LABEL ubuntu26-server
  MENU LABEL ^5) Ubuntu 26.04 Server (live via HTTP)
  KERNEL ubuntu26/server/vmlinuz
  APPEND initrd=ubuntu26/server/initrd ip=dhcp boot=casper url=http://$PXE_IP/distros/$UBUNTU26_SERVER_ISO quiet ---

LABEL kali
  MENU LABEL ^6) Kali Linux Live (desktop via HTTP)
  KERNEL kali/vmlinuz
  APPEND initrd=kali/initrd.img boot=live username=root hostname=kali fetch=http://$PXE_IP/distros/kali/filesystem.squashfs ---

MENU SEPARATOR

LABEL win11
  MENU LABEL ^7) Windows 11 Enterprise (wimboot)
  KERNEL ipxe.lkrn
  APPEND dhcp && chain http://$PXE_IP/distros/win11.ipxe

LABEL win10
  MENU LABEL ^8) Windows 10 Enterprise (wimboot)
  KERNEL ipxe.lkrn
  APPEND dhcp && chain http://$PXE_IP/distros/win10.ipxe

MENU SEPARATOR

LABEL shell
  MENU LABEL ^9) iPXE Shell
  KERNEL ipxe.lkrn
MENU

# ---------------------------------------------------------------------------
# Menu iPXE (EFI) - encadeado pelo dnsmasq (efi/ipxe.efi)
# ---------------------------------------------------------------------------
log "Gerando script iPXE (EFI)"
$SUDO tee "$TFTP_DIR/boot/menu.ipxe" >/dev/null <<IPXE
#!ipxe
menu PXE BOOT - $PXE_IP
item --gap -- Ubuntu
item ubuntu-desktop    Ubuntu 24.04 Desktop (live HTTP)
item ubuntu-server     Ubuntu 24.04 Server (live HTTP)
item ubuntu26-desktop  Ubuntu 26.04 Desktop (live HTTP)
item ubuntu26-server   Ubuntu 26.04 Server (live HTTP)
item --gap -- Kali
item kali              Kali Linux Live (desktop via HTTP)
item --gap -- Windows
item win11             Windows 11 Enterprise
item win10             Windows 10 Enterprise
item --gap --
item local             Boot Local HD
item shell             iPXE Shell
choose --default local --timeout 30000 target && goto \${target}

:ubuntu-desktop
kernel tftp://$PXE_IP/ubuntu/desktop/vmlinuz initrd=initrd ip=dhcp boot=casper url=http://$PXE_IP/distros/$UBUNTU_DESKTOP_ISO quiet splash ---
initrd tftp://$PXE_IP/ubuntu/desktop/initrd
boot

:ubuntu-server
kernel tftp://$PXE_IP/ubuntu/server/vmlinuz initrd=initrd ip=dhcp boot=casper url=http://$PXE_IP/distros/$UBUNTU_SERVER_ISO quiet ---
initrd tftp://$PXE_IP/ubuntu/server/initrd
boot

:ubuntu26-desktop
kernel tftp://$PXE_IP/ubuntu26/desktop/vmlinuz initrd=initrd ip=dhcp boot=casper url=http://$PXE_IP/distros/$UBUNTU26_DESKTOP_ISO quiet splash ---
initrd tftp://$PXE_IP/ubuntu26/desktop/initrd
boot

:ubuntu26-server
kernel tftp://$PXE_IP/ubuntu26/server/vmlinuz initrd=initrd ip=dhcp boot=casper url=http://$PXE_IP/distros/$UBUNTU26_SERVER_ISO quiet ---
initrd tftp://$PXE_IP/ubuntu26/server/initrd
boot

:kali
kernel tftp://$PXE_IP/kali/vmlinuz initrd=initrd.img boot=live username=root hostname=kali fetch=http://$PXE_IP/distros/kali/filesystem.squashfs ---
initrd tftp://$PXE_IP/kali/initrd.img
boot

:win11
chain http://$PXE_IP/distros/win11.ipxe || goto shell

:win10
chain http://$PXE_IP/distros/win10.ipxe || goto shell

:local
exit

:shell
  shell
IPXE

$SUDO chmod -R 755 "$TFTP_DIR" "$ISO_DIR" 2>/dev/null || true
$SUDO chown -R www-data:www-data "$ISO_DIR" 2>/dev/null || true
$SUDO systemctl restart dnsmasq 2>/dev/null || true

log "Menus PXE criados em $TFTP_DIR/pxelinux.cfg/default e $TFTP_DIR/boot/menu.ipxe"

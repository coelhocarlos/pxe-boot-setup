#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config-pxe.sh
source "$DIR/config-pxe.sh"
export DEBIAN_FRONTEND=noninteractive

# --- interface de rede ------------------------------------------------------
if [ "$PXE_IFACE" = "auto" ]; then
  PXE_IFACE="$(ip -o -4 addr show 2>/dev/null | awk -v ip="$PXE_IP" '$4 ~ "^"ip"/" {print $2}' | head -1 || true)"
  [ -z "$PXE_IFACE" ] && PXE_IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true)"
  [ -z "$PXE_IFACE" ] && PXE_IFACE="eth0"
fi
info "Interface PXE: $PXE_IFACE"

$SUDO mkdir -p "$LOG_DIR" "$ISO_DIR" "$TFTP_DIR" "$TFTPD_BOOT" "$TFTP_DIR/efi" /etc/dnsmasq.d
$SUDO chmod 755 "$ISO_DIR" "$TFTP_DIR"

log "Atualizando sistema"
$SUDO apt-get update -y
$SUDO apt-get upgrade -y

log "Instalando pacotes PXE"
$SUDO apt-get install -y dnsmasq tftpd-hpa apache2 syslinux syslinux-common \
  pxelinux ipxe cifs-utils \
  aria2 wget curl rsync jq p7zip-full net-tools

log "Configurando dnsmasq (interface=$PXE_IFACE)"
# O TFTP fica por conta do tftpd-hpa (porta 69); o dnsmasq so faz DHCP/PXE.
# DHCP_PROXY=true => proxy-DHCP: NAO aloca IP/rota/DNS (o roteador faz isso),
# apenas entrega as informacoes de boot PXE. Evita conflito com o DHCP da LAN.
# Em proxy-DHCP o boot e entregue via pxe-service (dhcp-boot e IGNORADO).
if [ "$DHCP_PROXY" = "true" ]; then
  DHCP_LINE="dhcp-range=$PXE_SUBNET,proxy,$PXE_NETMASK"
  NET_OPTIONS=""
  PXE_OPTS="dhcp-match=set:ipxe,175
pxe-prompt=\"PXE Boot\",1
# 1a requisicao (PXE ROM): carrega iPXE via UNDI (BIOS) / iPXE.efi (UEFI)
pxe-service=tag:!ipxe,x86PC,\"BIOS PXE (iPXE/UNDI)\",undionly.kpxe,$PXE_IP
pxe-service=tag:!ipxe,BC_EFI,\"UEFI PXE (iPXE)\",efi/ipxe.efi,$PXE_IP
pxe-service=tag:!ipxe,x86-64_EFI,\"UEFI PXE (iPXE)\",efi/ipxe.efi,$PXE_IP
# 2a requisicao (ja e' iPXE, option 175): entrega o menu (quebra o loop)
pxe-service=tag:ipxe,x86PC,\"iPXE menu\",boot/menu.ipxe,$PXE_IP
pxe-service=tag:ipxe,BC_EFI,\"iPXE menu\",boot/menu.ipxe,$PXE_IP
pxe-service=tag:ipxe,x86-64_EFI,\"iPXE menu\",boot/menu.ipxe,$PXE_IP"
  info "Modo proxy-DHCP (sem alocacao de IP; boot via pxe-service)"
else
  DHCP_LINE="dhcp-range=$DHCP_RANGE"
  NET_OPTIONS="dhcp-option=3,$PXE_GW
dhcp-option=6,$PXE_DNS"
  PXE_OPTS="dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:efi-x86_64,option:client-arch,9
dhcp-boot=tag:efi-x86_64,efi/ipxe.efi,,$PXE_IP
dhcp-boot=tag:!efi-x86_64,pxelinux.0,,$PXE_IP"
  info "Modo DHCP completo (aloca IPs; boot via dhcp-boot)"
fi
$SUDO tee /etc/dnsmasq.d/pxe.conf >/dev/null <<EOF
# PXE BOOT - gerado por 01-install-pxe.sh
port=0
interface=$PXE_IFACE
bind-interfaces
$DHCP_LINE
$NET_OPTIONS
# Boot PXE (BIOS: iPXE via UNDI | UEFI: iPXE) -> autoexec.ipxe -> menu
$PXE_OPTS
EOF

log "Configurando tftpd-hpa"
$SUDO sed -i "s|^TFTP_DIRECTORY=.*|TFTP_DIRECTORY=\"$TFTP_DIR\"|" /etc/default/tftpd-hpa 2>/dev/null || true

log "Iniciando servicos"
$SUDO systemctl enable --now tftpd-hpa
$SUDO systemctl enable --now apache2
$SUDO systemctl restart dnsmasq

log "Copiando bootloaders para o TFTP"
$SUDO cp /usr/lib/syslinux/modules/bios/* "$TFTP_DIR/" 2>/dev/null || true
$SUDO cp /usr/lib/PXELINUX/pxelinux.0 "$TFTP_DIR/" 2>/dev/null || true
$SUDO cp /usr/lib/syslinux/pxelinux.0 "$TFTP_DIR/" 2>/dev/null || true
$SUDO cp /usr/share/ipxe/undionly.kpxe "$TFTP_DIR/" 2>/dev/null || true
$SUDO cp /usr/lib/ipxe/undionly.kpxe "$TFTP_DIR/" 2>/dev/null || true
$SUDO cp /usr/share/ipxe/ipxe.lkrn "$TFTP_DIR/" 2>/dev/null || true
$SUDO cp /usr/lib/ipxe/ipxe.lkrn "$TFTP_DIR/" 2>/dev/null || true
$SUDO cp /usr/share/ipxe/ipxe.efi "$TFTP_DIR/efi/" 2>/dev/null || true
$SUDO cp /usr/lib/ipxe/ipxe.efi "$TFTP_DIR/efi/" 2>/dev/null || true
$SUDO cp /usr/lib/shim/*.efi "$TFTP_DIR/efi/" 2>/dev/null || true
$SUDO cp /usr/lib/grub/x86_64-efi/monolithic/grubnetx64.efi "$TFTP_DIR/efi/" 2>/dev/null || true

$SUDO mkdir -p "$TFTP_DIR/pxelinux.cfg"
$SUDO chown -R tftp:tftp "$TFTP_DIR" 2>/dev/null || true
$SUDO chmod -R 755 "$TFTP_DIR"

log "PXE instalado com sucesso - distros em $ISO_DIR (HTTP: http://$PXE_IP/distros/)"

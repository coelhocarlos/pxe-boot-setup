#!/usr/bin/env bash
# Configuracao PXE-BOOT
# Rede / acesso
export PXE_IP="${PXE_IP:-192.168.0.200}"
export PXE_NETMASK="${PXE_NETMASK:-255.255.255.0}"
export PXE_GW="${PXE_GW:-192.168.0.1}"
export PXE_DNS="${PXE_DNS:-8.8.8.8,1.1.1.1}"
export PXE_IFACE="${PXE_IFACE:-auto}"                          # auto = detecta a interface do PXE_IP
export PXE_SUBNET="${PXE_SUBNET:-192.168.0.0}"                 # rede usada no proxy-DHCP
export DHCP_PROXY="${DHCP_PROXY:-true}"                        # true = proxy-DHCP (nao aloca IP; so info PXE)
export DHCP_RANGE="${DHCP_RANGE:-192.168.0.50,192.168.0.150,12h}"  # usado quando DHCP_PROXY=false

# SSH (deploy remoto)
export SSH_HOST="${SSH_HOST:-192.168.0.200}"
export SSH_USER="${SSH_USER:-pxeuser}"
export SSH_PASS="${SSH_PASS:-1q2w3e!@}"
export REMOTE_DIR="${REMOTE_DIR:-/home/${SSH_USER}/pxe-boot}"

# Diretorios remotos
export TFTP_DIR="${TFTP_DIR:-/srv/tftp}"
export ISO_DIR="${ISO_DIR:-/var/www/html/distros}"            # pasta de distros (servida via HTTP)
export WWW_ROOT="${WWW_ROOT:-/var/www/html}"
export LOG_DIR="${LOG_DIR:-/var/log/pxe-setup}"
export TFTPD_BOOT="${TFTPD_BOOT:-/srv/tftp/boot}"

# ---------------------------------------------------------------------------
# Distros (Linux)
# ---------------------------------------------------------------------------
export UBUNTU_DESKTOP_URL="https://releases.ubuntu.com/24.04.5.1/ubuntu-24.04.5.1-desktop-amd64.iso"
export UBUNTU_SERVER_URL="https://releases.ubuntu.com/24.04.5/ubuntu-24.04.5-live-server-amd64.iso"
export UBUNTU_DESKTOP_ISO="ubuntu-24.04.5.1-desktop-amd64.iso"
export UBUNTU_SERVER_ISO="ubuntu-24.04.5-live-server-amd64.iso"
# Diretorio dos SHA256SUMS para verificacao automatica (vazio = nao verifica)
export UBUNTU_DESKTOP_SUMS="https://releases.ubuntu.com/24.04.5.1/SHA256SUMS"
export UBUNTU_SERVER_SUMS="https://releases.ubuntu.com/24.04.5/SHA256SUMS"

# ---------------------------------------------------------------------------
# Windows (Enterprise Evaluation - links diretos do CDN da Microsoft)
# ---------------------------------------------------------------------------
export WIN11_URL="https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
export WIN10_URL="https://software-static.download.prss.microsoft.com/dbazure/988969d5-f34g-4e03-ac9d-1f9786c66750/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
export WIN11_ISO="Windows11-x64-Eval.iso"
export WIN10_ISO="Windows10-x64-Eval.iso"

# Downloader
export USE_ARIA2="${USE_ARIA2:-true}"
export ARIA2_CONNECTIONS="${ARIA2_CONNECTIONS:-4}"

# wimboot (usado para bootar Windows via iPXE)
export WIMBOOT_URL="${WIMBOOT_URL:-https://github.com/ipxe/wimboot/releases/download/v2.9.0/wimboot}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log(){ printf '\n== %s ==\n' "$*"; }
info(){ printf '  -> %s\n' "$*"; }
warn(){ printf '  !! %s\n' "$*" >&2; }
die(){ printf 'ERRO: %s\n' "$*" >&2; exit 1; }

# sudo somente quando nao for root
if [ "$(id -u 2>/dev/null)" = "0" ]; then
  export SUDO=""
else
  export SUDO="sudo"
fi

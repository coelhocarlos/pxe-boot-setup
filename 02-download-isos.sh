#!/usr/bin/env bash
# =============================================================================
# 02-download-isos.sh - Baixa as distros para a pasta de distros ($ISO_DIR)
#   - Ubuntu Desktop / Server (24.04 e 26.04)
#   - Kali Linux (Live/Desktop)
#   - Windows 11 Enterprise Eval
#   - Windows 10 Enterprise Eval
# Uso:
#   bash 02-download-isos.sh            # baixa tudo
#   bash 02-download-isos.sh ubuntu     # so Ubuntu (desktop + server 24 e 26)
#   bash 02-download-isos.sh kali       # so Kali
#   bash 02-download-isos.sh windows    # so Windows (10 + 11)
# =============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config-pxe.sh
source "$DIR/config-pxe.sh"

FILTER="${1:-all}"

$SUDO mkdir -p "$ISO_DIR"
log "Pasta de distros: $ISO_DIR"

# --- dependencias -----------------------------------------------------------
DL=""
if [ "$USE_ARIA2" = true ] && command -v aria2c >/dev/null 2>&1; then
  DL="aria2c"
elif command -v wget >/dev/null 2>&1; then
  DL="wget"
elif command -v curl >/dev/null 2>&1; then
  DL="curl"
else
  die "Instale aria2, wget ou curl para baixar as ISOs"
fi
info "Downloader: $DL"

# --- espaco em disco --------------------------------------------------------
if command -v df >/dev/null 2>&1; then
  AVAIL_GB=$(df -BG --output=avail "$ISO_DIR" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
  info "Espaco livre em $ISO_DIR: ${AVAIL_GB}GB (necessario ~30GB)"
  if [ "${AVAIL_GB:-0}" -lt 25 ] 2>/dev/null; then
    warn "Espaco em disco pode ser insuficiente para todas as distros"
  fi
fi

# --- funcoes ----------------------------------------------------------------
human() { numfmt --to=iec "$1" 2>/dev/null || echo "$1 bytes"; }

# baixa_iso <url> <nome-final> [url_SHA256SUMS]
baixa_iso() {
  local url="$1" out="$2" sums="${3:-}"
  local path="$ISO_DIR/$out"

  if [ -s "$path" ]; then
    info "$out ja existe ($(human "$(stat -c%s "$path")")). Pulando download."
  else
    log "Baixando $out"
    case "$DL" in
      aria2c) $SUDO aria2c -c -x"${ARIA2_CONNECTIONS}" -s"${ARIA2_CONNECTIONS}" \
                      --console-log-level=warn --file-allocation=none \
                      -d "$ISO_DIR" -o "$out" "$url" ;;
      wget)   $SUDO wget -c --progress=bar:force -O "$path" "$url" ;;
      curl)   $SUDO curl -L -C - --progress-bar -o "$path" "$url" ;;
    esac
  fi

  # verificacao de integridade (quando houver SHA256SUMS)
  if [ -n "$sums" ]; then
    verifica_sha256 "$path" "$out" "$sums"
  fi
}

# verifica_sha256 <arquivo> <nome> <url_SHA256SUMS>
verifica_sha256() {
  local path="$1" name="$2" sums_url="$3"
  local sums="/tmp/SHA256SUMS.$$"
  command -v sha256sum >/dev/null 2>&1 || return 0
  wget -q -O "$sums" "$sums_url" 2>/dev/null || curl -fsSL -o "$sums" "$sums_url" 2>/dev/null || {
    warn "Nao foi possivel baixar SHA256SUMS de $sums_url (pulando verificacao)"
    return 0
  }
  local expected
  expected=$(grep -E "[ *](\*?)$name\$" "$sums" | awk '{print $1}' | head -1 || true)
  rm -f "$sums"
  if [ -z "$expected" ]; then
    warn "SHA256 nao encontrado para $name (pulando)"
    return 0
  fi
  local actual
  actual=$(sha256sum "$path" | awk '{print $1}')
  if [ "$expected" = "$actual" ]; then
    info "SHA256 OK: $name"
  else
    warn "SHA256 DIVERGENTE em $name"
    warn "  esperado: $expected"
    warn "  obtido:   $actual"
    return 1
  fi
}

# baixa_torrent <url_do_.torrent> <nome-da-.iso> [url_SHA256SUMS]
# Distribuicoes que so publicam a ISO via BitTorrent (ex.: Kali live).
baixa_torrent() {
  local turl="$1" out="$2" sums="${3:-}"
  local path="$ISO_DIR/$out"
  local torr="/tmp/$(basename "$turl")"

  if [ -s "$path" ]; then
    info "$out ja existe ($(human "$(stat -c%s "$path")")). Pulando download."
  else
    log "Baixando torrent para $out"
    if ! $SUDO curl -skL --max-time 120 -o "$torr" "$turl"; then
      warn "Falha ao baixar o arquivo .torrent: $turl"
      return 1
    fi
    if [ ! -s "$torr" ]; then
      warn "Arquivo .torrent vazio (?)"
      return 1
    fi
    log "Baixando via BitTorrent: $out"
    $SUDO aria2c -c -x8 -s8 --seed-time=0 --file-allocation=none \
                 --console-log-level=warn \
                 -d "$ISO_DIR" -o "$out" "$torr" \
      || warn "aria2c (torrent) falhou para $out"
    $SUDO rm -f "$torr"
  fi

  if [ -n "$sums" ]; then
    verifica_sha256 "$path" "$out" "$sums"
  fi
}

# --- execucao ---------------------------------------------------------------
want_ubuntu() { [ "$FILTER" = "all" ] || [ "$FILTER" = "ubuntu" ] || [ "$FILTER" = "linux" ]; }
want_kali() { [ "$FILTER" = "all" ] || [ "$FILTER" = "kali" ] || [ "$FILTER" = "linux" ]; }
want_windows() { [ "$FILTER" = "all" ] || [ "$FILTER" = "windows" ]; }

if want_ubuntu; then
  baixa_iso "$UBUNTU_DESKTOP_URL" "$UBUNTU_DESKTOP_ISO" "$UBUNTU_DESKTOP_SUMS"
  baixa_iso "$UBUNTU_SERVER_URL"  "$UBUNTU_SERVER_ISO"  "$UBUNTU_SERVER_SUMS"
  baixa_iso "$UBUNTU26_DESKTOP_URL" "$UBUNTU26_DESKTOP_ISO" "$UBUNTU26_DESKTOP_SUMS"
  baixa_iso "$UBUNTU26_SERVER_URL"  "$UBUNTU26_SERVER_ISO"  "$UBUNTU26_SERVER_SUMS"
fi

if want_kali; then
  case "$KALI_LIVE_URL" in
    *.torrent) baixa_torrent "$KALI_LIVE_URL" "$KALI_LIVE_ISO" "$KALI_LIVE_SUMS" ;;
    *)         baixa_iso "$KALI_LIVE_URL" "$KALI_LIVE_ISO" "$KALI_LIVE_SUMS" ;;
  esac
fi

if want_windows; then
  baixa_iso "$WIN11_URL" "$WIN11_ISO"
  baixa_iso "$WIN10_URL" "$WIN10_ISO"
fi

chmod -R 755 "$ISO_DIR" 2>/dev/null || true
$SUDO chown -R www-data:www-data "$ISO_DIR" 2>/dev/null || true

log "Downloads concluidos. Distros em $ISO_DIR"
ls -lh "$ISO_DIR" || true

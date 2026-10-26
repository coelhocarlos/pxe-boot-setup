#!/usr/bin/env bash
# ============================================================================
#  04-setup-pxe-cifs.sh - instalar Ubuntu Desktop em maquinas com 4 GB de RAM
#
#  PROBLEMA
#    As entradas "ISO HTTP" (geradas pelo 03-setup-pxe-menu.sh) usam
#    `netboot=url url=http://.../x.iso`. O casper (do_urlmount) BAIXA o ISO
#    INTEIRO para a RAM do initramfs antes de montar em loop. O ISO do 26 tem
#    6.5 GB: nao cabe em 4 GB e a instalacao para por volta de 52%.
#
#  SOLUCAO
#    Extrair o ISO para uma pasta dentro da raiz web e exportar essa pasta por
#    SMB/CIFS (somente leitura, convidado). O initrd monta a pasta com
#    `netboot=cifs nfsroot=//IP/pxe/<pasta>` e le o squashfs sob demanda -
#    nada e copiado para a RAM (usa ~1 GB, funciona em 2 GB tambem).
#
#    O casper monta com `-ouser=root,password=` (senha vazia), entao o share
#    TEM que aceitar convidado:
#        map to guest = Bad User
#        [pxe] guest ok = yes / read only = yes / force user = nobody
#
#  USO
#    sudo bash 04-setup-pxe-cifs.sh
#
#  Depois escolha no menu PXE a entrada "[SMB] ... (4GB RAM)".
#  Detalhes, diagnostico e o que da errado: docs/instalar-4gb-ram.md
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE/config-pxe.sh" ] && . "$HERE/config-pxe.sh"

PXE_IP="${PXE_IP:-192.168.0.200}"
ISO_DIR="${ISO_DIR:-/var/www/html/distros}"
CIFS_SHARE_NAME="${CIFS_SHARE_NAME:-pxe}"
CIFS_ROOT="${CIFS_ROOT:-$ISO_DIR}"
SMB_CONF="${SMB_CONF:-/etc/samba/smb.conf}"
# menu iPXE gerado pelo 03 (se existir, as entradas SMB sao inseridas nele)
MENU_FILE="${MENU_FILE:-/srv/tftp/boot/menu.ipxe}"

# "<pasta>:<arquivo.iso>" - a pasta e criada dentro de $ISO_DIR (raiz web)
CIFS_DISTROS="${CIFS_DISTROS:-ub26live-desktop:${UBUNTU26_DESKTOP_ISO:-ubuntu-26.04.1-desktop-amd64.iso} ub24live-desktop:${UBUNTU_DESKTOP_ISO:-ubuntu-24.04.5.1-desktop-amd64.iso}}"
read -ra DISTROS <<< "$CIFS_DISTROS"

log(){ printf '\n== %s ==\n' "$*"; }
info(){ printf '  -> %s\n' "$*"; }
warn(){ printf '  !! %s\n' "$*" >&2; }
die(){ printf 'ERRO: %s\n' "$*" >&2; exit 1; }

folder_of(){ printf '%s' "${1%%:*}"; }
iso_of(){ printf '%s' "${1##*:}"; }

# "Ubuntu 26.04.1 LTS" a partir de <pasta>/.disk/info
release_of(){
  local f="$ISO_DIR/$(folder_of "$1")/.disk/info"
  if [ -f "$f" ]; then
    sed 's/ ".*//' "$f" | head -n1
  else
    folder_of "$1"
  fi
}

[ "$(id -u)" = "0" ] || die "execute com sudo: sudo bash $0"
[ -f "$SMB_CONF" ] || die "nao encontrei $SMB_CONF (instale o samba antes)"

# ---------------------------------------------------------------------------
# 1) Extrair os ISOs para pastas (uma vez so; ocupa ~ o tamanho do ISO)
# ---------------------------------------------------------------------------
extract_iso(){
  local iso="$1" dest="$2" tmp mnt rc=1

  if [ -d "$dest/casper" ]; then
    info "pasta ja existe, nao extraio: $dest"
    return 0
  fi
  [ -f "$iso" ] || { warn "ISO nao encontrado: $iso"; return 1; }

  tmp="${dest}.parcial"
  rm -rf "$tmp"; mkdir -p "$tmp"
  log "Extraindo $(basename "$iso") -> $dest (demora alguns minutos)"

  if command -v xorriso >/dev/null 2>&1; then
    xorriso -osirrox on -indev "$iso" -extract / "$tmp" >/dev/null 2>&1 && rc=0
  fi
  if [ "$rc" != 0 ]; then
    mnt="$(mktemp -d)"
    if mount -o loop,ro "$iso" "$mnt" 2>/dev/null; then
      cp -a "$mnt/." "$tmp/" && rc=0
      umount "$mnt"
    fi
    rmdir "$mnt" 2>/dev/null || true
  fi
  if [ "$rc" != 0 ] && command -v 7z >/dev/null 2>&1; then
    7z x -y -o"$tmp" "$iso" >/dev/null && rc=0
  fi
  if [ "$rc" != 0 ]; then
    rm -rf "$tmp"
    warn "falhou extrair $iso (instale xorriso ou p7zip-full)"
    return 1
  fi
  [ -d "$tmp/casper" ] || { rm -rf "$tmp"; warn "$iso nao tem casper/"; return 1; }

  mv "$tmp" "$dest"
  chmod -R a+rX "$dest"
  chown -R www-data:www-data "$dest" 2>/dev/null || true
  info "extraido: $dest"
}

# ---------------------------------------------------------------------------
# 2) Camada base com o nome que o casper espera (casper/minimal.squashfs).
#    O instalador do 24/26 nao esta na base: esta em
#    casper/minimal.standard.live.squashfs. O casper monta TODAS as camadas
#    casper/*.squashfs (igual ao ISO) - nao passe layerfs-path.
# ---------------------------------------------------------------------------
fix_base_name(){
  local dir="$1/casper"
  [ -d "$dir" ] || return 0
  if [ -f "$dir/filesystem.squashfs" ] && [ ! -e "$dir/minimal.squashfs" ]; then
    info "renomeando $(basename "$1")/casper/filesystem.squashfs -> minimal.squashfs"
    mv "$dir/filesystem.squashfs" "$dir/minimal.squashfs"
  fi
  if [ ! -f "$dir/minimal.squashfs" ]; then
    warn "$(basename "$1")/casper/minimal.squashfs nao existe (is_casper_path vai falhar)"
  fi
}

# ---------------------------------------------------------------------------
# 3) Share SMB somente leitura para convidado
# ---------------------------------------------------------------------------
setup_samba(){
  local bak
  bak="$SMB_CONF.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$SMB_CONF" "$bak"
  info "backup: $bak"

  if grep -qE '^[[:space:]]*map to guest[[:space:]]*=' "$SMB_CONF"; then
    sed -i -E 's|^[[:space:]]*map to guest[[:space:]]*=.*|   map to guest = Bad User|' "$SMB_CONF"
  else
    sed -i '0,/^\[global\]/s//[global]\n   map to guest = Bad User/' "$SMB_CONF"
  fi

  # recria o share do zero (idempotente)
  python3 - "$SMB_CONF" "$CIFS_SHARE_NAME" <<'PY'
import sys
path, share = sys.argv[1], sys.argv[2].lower()
out, skip = [], False
for line in open(path):
    if line.strip().lower() == "[%s]" % share:
        skip = True
        continue
    if skip and line.lstrip().startswith("["):
        skip = False
    if not skip:
        out.append(line)
open(path, "w").writelines(out)
PY

  cat >> "$SMB_CONF" <<EOF

[$CIFS_SHARE_NAME]
   comment = Imagens PXE (somente leitura, convidado)
   path = $CIFS_ROOT
   browseable = yes
   read only = yes
   guest ok = yes
   force user = nobody
EOF

  testparm -s >/dev/null || die "smb.conf invalido - rode 'testparm'"
  systemctl restart smbd
  systemctl is-active --quiet smbd || die "smbd nao subiu - veja journalctl -u smbd"
  info "share [$CIFS_SHARE_NAME] -> $CIFS_ROOT (convidado, somente leitura)"
}

# ---------------------------------------------------------------------------
# 4) Validar do mesmo jeito que o initrd faz (user=root, senha vazia).
#    ATENCAO: no smbclient o argumento do `ls` e' MASCARA, nao caminho.
#    `ls pasta/sub` NAO lista pasta/sub (lista a pasta pai) - use `cd ...; ls`.
# ---------------------------------------------------------------------------
verify_share(){
  local folder="$1" out="" i
  for i in $(seq 1 15); do
    out=$(smbclient -N -U root "//127.0.0.1/$CIFS_SHARE_NAME" \
          -c "cd $folder/casper; ls *.squashfs" 2>&1 || true)
    printf '%s' "$out" | grep -q 'squashfs' && return 0
    sleep 1
  done
  printf '%s\n' "$out" >&2
  return 1
}

# ---------------------------------------------------------------------------
# 5) Entradas iPXE (kernel/initrd saem da propria pasta extraida, via HTTP)
# ---------------------------------------------------------------------------
entry_items(){
  echo "item --gap -- Ubuntu (SMB/CIFS - 4GB RAM)"
  for pair in "${DISTROS[@]}"; do
    printf 'item %s-smb   %s Desktop (SMB, 4GB RAM)\n' "$(folder_of "$pair")" "$(release_of "$pair")"
  done
}

entry_sections(){
  local folder
  for pair in "${DISTROS[@]}"; do
    folder="$(folder_of "$pair")"
    cat <<EOF

:$folder-smb
echo Booting [SMB] $(release_of "$pair") Desktop (4GB RAM)...
kernel http://$PXE_IP/distros/$folder/casper/vmlinuz ip=dhcp boot=casper netboot=cifs nfsroot=//$PXE_IP/$CIFS_SHARE_NAME/$folder ignore_uuid cloud-config-url=/dev/null cloud-init=disabled quiet splash
initrd http://$PXE_IP/distros/$folder/casper/initrd
boot
EOF
  done
}

write_menu(){
  local snippet="/srv/tftp/boot/cifs.ipxe" items sections
  mkdir -p "$(dirname "$snippet")"
  items="$(entry_items)"
  sections="$(entry_sections)"

  { echo "# Gerado por 04-setup-pxe-cifs.sh - Ubuntu via SMB/CIFS (4 GB de RAM)"
    echo "# ip=dhcp boot=casper netboot=cifs nfsroot=//SERVER/SHARE/PASTA ignore_uuid"
    echo "$items"; echo "$sections"; } > "$snippet"
  info "snippet iPXE: $snippet"

  if [ ! -f "$MENU_FILE" ]; then
    warn "menu $MENU_FILE nao existe (rode 03-setup-pxe-menu.sh, ou use o snippet acima)"
    return 0
  fi

  ITEMS="$items" SECTIONS="$sections" python3 - "$MENU_FILE" <<'PY'
import os, sys
menu = sys.argv[1]
I1, I2 = "# >>> pxe-cifs items >>>", "# <<< pxe-cifs items <<<"
S1, S2 = "# >>> pxe-cifs sections >>>", "# <<< pxe-cifs sections <<<"
items = os.environ["ITEMS"].splitlines()
sections = os.environ["SECTIONS"].strip("\n").splitlines()

lines = open(menu).read().splitlines()

def drop(ls, a_mark, b_mark):
    if a_mark in ls and b_mark in ls:
        a, b = ls.index(a_mark), ls.index(b_mark)
        del ls[a:b + 1]

drop(lines, I1, I2)
drop(lines, S1, S2)
while lines and not lines[-1].strip():
    lines.pop()

# Os `item` precisam estar ANTES do `choose`/`prompt`, senao nao aparecem.
def insert_at(ls):
    for i, l in enumerate(ls):
        if l.strip().startswith(("choose", "prompt", "goto")):
            return i
    for i, l in enumerate(ls):
        if l.startswith(":"):
            return i
    return len(ls)

at = insert_at(lines)
lines[at:at] = [I1] + items + [I2]
lines += ["", S1] + sections + [S2]
open(menu, "w").write("\n".join(lines) + "\n")
PY
  info "entradas [SMB] inseridas em $MENU_FILE (bloco # >>> pxe-cifs >>>)"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
log "1/5 Extraindo os ISOs para pastas em $ISO_DIR"
for pair in "${DISTROS[@]}"; do
  extract_iso "$ISO_DIR/$(iso_of "$pair")" "$ISO_DIR/$(folder_of "$pair")" || true
done
mkdir -p "$CIFS_ROOT"

log "2/5 Conferindo a camada base do casper"
for pair in "${DISTROS[@]}"; do
  fix_base_name "$ISO_DIR/$(folder_of "$pair")"
done

log "3/5 Configurando o share SMB de convidado"
setup_samba

log "4/5 Testando o acesso de convidado (mesmo login que o initrd usa)"
fail=0
for pair in "${DISTROS[@]}"; do
  folder="$(folder_of "$pair")"
  if verify_share "$folder"; then
    info "OK  //$PXE_IP/$CIFS_SHARE_NAME/$folder"
  else
    warn "FALHOU //$PXE_IP/$CIFS_SHARE_NAME/$folder"
    fail=1
  fi
done
if [ "$fail" != 0 ]; then
  warn "diagnostico: smbclient -N -U root //127.0.0.1/$CIFS_SHARE_NAME -c 'ls'"
  die "o share nao respondeu como convidado (veja journalctl -u smbd -n 50)"
fi

log "5/5 Entradas do menu PXE"
write_menu

cat <<EOF

Tudo pronto. No menu do PXE escolha uma entrada "[SMB] ... (4GB RAM)".

Conferir do servidor enquanto o cliente inicializa:
  watch -n2 'smbstatus -b; ss -tn | grep ":445"'

Se o cliente reclamar "nfsmount: ...: need a server", o mount CIFS falhou e o
casper caiu no fallback NFS. Veja docs/instalar-4gb-ram.md (secao Problemas).
EOF

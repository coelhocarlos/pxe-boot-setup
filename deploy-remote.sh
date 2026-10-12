#!/usr/bin/env bash
# =============================================================================
# deploy-remote.sh - Envia e executa o setup PXE no servidor via SSH
#   Host: $SSH_HOST   Usuario: $SSH_USER
# Uso: ./deploy-remote.sh [install|download|menu|all]
# =============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config-pxe.sh
source "$DIR/config-pxe.sh"

STEP="${1:-all}"

command -v sshpass >/dev/null 2>&1 || die "Instale sshpass (apt install sshpass / brew install hudochenkov/sshpass/sshpass)"
command -v rsync   >/dev/null 2>&1 || die "Instale rsync"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
SSH_TARGET="$SSH_USER@$SSH_HOST"

remote()      { sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }
run_root()    { remote "echo '$SSH_PASS' | sudo -S bash -lc '$1'"; }

log "Testando conexao SSH em $SSH_TARGET"
remote "echo conectado: \$(whoami)@\$(hostname)" || die "Falha no SSH (verifique usuario/senha)"

log "Enviando arquivos para $SSH_TARGET:$REMOTE_DIR"
sshpass -p "$SSH_PASS" rsync -avz --progress \
  -e "ssh ${SSH_OPTS[*]}" \
  --exclude '.git' --exclude '*.iso' \
  "$DIR/" "$SSH_TARGET:$REMOTE_DIR/"

if [ "$STEP" = "install" ] || [ "$STEP" = "all" ]; then
  log "Etapa 1/3: instalando PXE (dnsmasq, tftp, apache, ipxe)"
  run_root "cd '$REMOTE_DIR' && chmod +x *.sh && bash 01-install-pxe.sh"
fi

if [ "$STEP" = "download" ] || [ "$STEP" = "all" ]; then
  log "Etapa 2/3: baixando distros para $ISO_DIR (pode levar horas)"
  run_root "cd '$REMOTE_DIR' && bash 02-download-isos.sh"
fi

if [ "$STEP" = "menu" ] || [ "$STEP" = "all" ]; then
  log "Etapa 3/3: gerando menus PXE"
  run_root "cd '$REMOTE_DIR' && bash 03-setup-pxe-menu.sh"
fi

log "Concluido. Servidor PXE pronto: http://$PXE_IP/distros/"

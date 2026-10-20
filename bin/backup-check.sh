#!/usr/bin/env bash
# backup-check.sh — verificação periódica do repositório restic
#
# Por padrão lê 10% dos dados (amostra diferente a cada execução), o que detecta
# corrupção no armazenamento sem baixar o repositório inteiro.
set -uo pipefail

CONF_DIR="${BACKUP_CONF_DIR:-/etc/backup-restic}"
ENV_FILE="${ENV_FILE:-$CONF_DIR/backup.env}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "$ENV_FILE" ]]; then echo "ERRO: não consigo ler $ENV_FILE" >&2; exit 2; fi
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

STATE_DIR="${STATE_DIR:-/var/lib/backup-restic}"
LOG_FILE="${LOG_FILE:-/var/log/backup-restic.log}"
CHECK_SUBSET="${CHECK_SUBSET:-10%}"
RESTIC="${RESTIC:-restic}"

log() { printf '%s [check] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }

# Aviso pelo Telegram (opcional). Uma falha no envio nunca muda o resultado.
avisar() { "$AQUI/backup-notify.sh" "$@" || true; }

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/.lock"
if ! flock -w 3600 9; then
    log "não consegui a trava em 1h; saindo"
    avisar falha "Verificação não rodou: outro processo segurou a trava por mais de 1 h."
    exit 3
fi

log "verificando (read-data-subset=$CHECK_SUBSET)"
if "$RESTIC" check --read-data-subset="$CHECK_SUBSET" >>"$LOG_FILE" 2>&1; then
    date +%s > "$STATE_DIR/last-check"
    log "repositório OK"
else
    log "FALHA na verificação do repositório"
    avisar falha "FALHA na verificação do repositório (restic check)
Veja: tail -50 $LOG_FILE"
    exit 1
fi

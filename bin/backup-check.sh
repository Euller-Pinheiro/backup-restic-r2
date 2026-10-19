#!/usr/bin/env bash
# backup-check.sh — verificação periódica do repositório restic
#
# Por padrão lê 10% dos dados (amostra diferente a cada execução), o que detecta
# corrupção no armazenamento sem baixar o repositório inteiro.
set -uo pipefail

CONF_DIR="${BACKUP_CONF_DIR:-/etc/backup-restic}"
ENV_FILE="${ENV_FILE:-$CONF_DIR/backup.env}"
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

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/.lock"
flock -w 3600 9 || { log "não consegui a trava em 1h; saindo"; exit 3; }

log "verificando (read-data-subset=$CHECK_SUBSET)"
if "$RESTIC" check --read-data-subset="$CHECK_SUBSET" >>"$LOG_FILE" 2>&1; then
    date +%s > "$STATE_DIR/last-check"
    log "repositório OK"
else
    log "FALHA na verificação do repositório"
    exit 1
fi

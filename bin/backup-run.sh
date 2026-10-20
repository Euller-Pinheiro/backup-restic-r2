#!/usr/bin/env bash
# backup-run.sh — ciclo completo: dumps -> restic backup -> retenção -> marca de sucesso
#
# Lê a configuração de $BACKUP_CONF_DIR/backup.env (padrão /etc/backup-restic/backup.env).
# Só grava a marca de sucesso (lida pelo Zabbix) se TODAS as etapas terminarem bem.
# Duas execuções nunca rodam ao mesmo tempo (flock).
set -uo pipefail

CONF_DIR="${BACKUP_CONF_DIR:-/etc/backup-restic}"
ENV_FILE="${ENV_FILE:-$CONF_DIR/backup.env}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -r "$ENV_FILE" ]]; then echo "ERRO: não consigo ler $ENV_FILE" >&2; exit 2; fi
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

: "${RESTIC_REPOSITORY:?defina RESTIC_REPOSITORY em $ENV_FILE}"
: "${RESTIC_PASSWORD_FILE:?defina RESTIC_PASSWORD_FILE em $ENV_FILE}"
: "${BACKUP_PATHS:?defina BACKUP_PATHS em $ENV_FILE}"

DUMP_DIR="${DUMP_DIR:-/var/backups/restic-dumps}"
STATE_DIR="${STATE_DIR:-/var/lib/backup-restic}"
LOG_FILE="${LOG_FILE:-/var/log/backup-restic.log}"
EXCLUDES_FILE="${EXCLUDES_FILE:-$CONF_DIR/excludes}"
KEEP_LAST="${KEEP_LAST:-3}"
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
RESTIC="${RESTIC:-restic}"
export DUMP_DIR LOG_FILE

log() { printf '%s [backup] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }

# Aviso pelo Telegram (opcional). Uma falha no envio nunca muda o resultado do backup.
avisar() { "$AQUI/backup-notify.sh" "$@" || true; }

# Registra a falha, avisa e sai com erro, sem gravar a marca de sucesso.
# A marca backup-falhou permite avisar quando o backup volta a funcionar.
falhar() {
    log "$1"
    touch "$STATE_DIR/backup-falhou"
    avisar falha "$1
Veja: tail -50 $LOG_FILE"
    exit 1
}

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/.lock"
if ! flock -n 9; then log "outro backup em andamento; saindo"; exit 3; fi

inicio=$(date +%s)
log "===== início ====="

# 1) Dumps
if ! "$AQUI/backup-dumps.sh"; then
    falhar "FALHA nos dumps — backup NÃO marcado como sucesso"
fi

# 2) Repositório: cria na primeira vez
if ! "$RESTIC" cat config >/dev/null 2>&1; then
    log "repositório não inicializado; criando"
    "$RESTIC" init >>"$LOG_FILE" 2>&1 || falhar "FALHA ao criar o repositório"
fi

# 3) Backup
read -r -a caminhos <<< "$BACKUP_PATHS"
excl=()
[[ -f "$EXCLUDES_FILE" ]] && excl=(--exclude-file "$EXCLUDES_FILE")
if ! "$RESTIC" backup --one-file-system --exclude-caches "${excl[@]}" --tag auto \
        "$DUMP_DIR" "${caminhos[@]}" >>"$LOG_FILE" 2>&1; then
    falhar "FALHA no restic backup"
fi

# 4) Retenção
if ! "$RESTIC" forget --tag auto --prune \
        --keep-last "$KEEP_LAST" --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" >>"$LOG_FILE" 2>&1; then
    falhar "FALHA na retenção (forget/prune)"
fi

# 5) Marca de sucesso (epoch) — o Zabbix alerta se ficar velha
date +%s > "$STATE_DIR/last-success.tmp" && mv -f "$STATE_DIR/last-success.tmp" "$STATE_DIR/last-success"
duracao=$(( $(date +%s) - inicio ))
log "===== sucesso em ${duracao}s ====="

# 6) Aviso: "voltou a funcionar" depois de uma falha; "concluído" se NOTIFY_ON=sempre
if [[ -e "$STATE_DIR/backup-falhou" ]]; then
    rm -f "$STATE_DIR/backup-falhou"
    avisar recuperado "Backup concluído em ${duracao}s depois de uma falha anterior."
else
    avisar sucesso "Backup concluído em ${duracao}s."
fi

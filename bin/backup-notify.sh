#!/usr/bin/env bash
# backup-notify.sh — envia um aviso do kit de backup pelo Telegram
#
#   backup-notify.sh <tipo> <mensagem>
#
#   tipo: falha | recuperado | sucesso | teste
#
# Configuração (em backup.env):
#   TELEGRAM_BOT_TOKEN   token do bot, no formato 123456789:AAE...  (fale com o @BotFather)
#   TELEGRAM_CHAT_ID     id do chat, grupo ou canal que recebe os avisos
#   NOTIFY_ON            falha (padrão): avisa falhas e a volta ao normal
#                        sempre: avisa também cada backup bem-sucedido
#                        desligado: não avisa nada (o tipo "teste" ainda envia)
#
# Sem as duas variáveis, o script não faz nada e sai com 0: o aviso é opcional.
#
# Decisões de segurança:
#   - O token vai para o curl pela entrada padrão (curl -K -), nunca na linha de
#     comando. Assim ele não aparece no `ps` nem no histórico de processos.
#   - O token nunca é escrito no log.
#   - Tempo máximo de 20 s: um Telegram fora do ar não pode travar o backup.
#
# Código de saída: 0 enviado (ou aviso desligado), 1 falha no envio, 2 uso errado.
set -uo pipefail

CONF_DIR="${BACKUP_CONF_DIR:-/etc/backup-restic}"
ENV_FILE="${ENV_FILE:-$CONF_DIR/backup.env}"

# Chamado à mão (ex.: para testar o bot), o ambiente ainda não foi carregado.
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" && -r "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
fi

TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"
NOTIFY_HOST="${NOTIFY_HOST:-$(hostname -s 2>/dev/null || hostname)}"
LOG_FILE="${LOG_FILE:-/var/log/backup-restic.log}"
CURL="${CURL:-curl}"
LIMITE_TEXTO=4000   # o Telegram aceita até 4096 caracteres por mensagem

log() { printf '%s [aviso] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }

if (( $# < 2 )); then
    echo "uso: $(basename "$0") <falha|recuperado|sucesso|teste> <mensagem>" >&2
    exit 2
fi
tipo="$1"; shift
mensagem="$*"

case "$tipo" in
    falha)      titulo="❌ Backup com FALHA" ;;
    recuperado) titulo="✅ Backup voltou a funcionar" ;;
    sucesso)    titulo="✅ Backup concluído" ;;
    teste)      titulo="🔔 Teste de aviso do backup" ;;
    *) echo "tipo inválido: $tipo (use falha, recuperado, sucesso ou teste)" >&2; exit 2 ;;
esac

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    exit 0   # aviso não configurado
fi

# Filtro pelo NOTIFY_ON. O padrão evita o "aviso de tudo certo" diário, que
# acostuma a pessoa a ignorar o canal; a volta ao normal sempre é avisada,
# para quem recebeu a falha saber que pode parar de se preocupar.
case "${NOTIFY_ON:-falha}" in
    falha)     [[ "$tipo" == sucesso ]] && exit 0 ;;
    sempre)    ;;
    desligado) [[ "$tipo" != teste ]] && exit 0 ;;
    *)         log "NOTIFY_ON inválido (${NOTIFY_ON}); usando 'falha'"
               [[ "$tipo" == sucesso ]] && exit 0 ;;
esac

# Valida o formato antes de montar a URL: impede que um valor errado (aspas,
# espaços, quebra de linha) altere a configuração passada ao curl.
if [[ ! "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
    log "TELEGRAM_BOT_TOKEN com formato inválido; aviso não enviado"
    exit 1
fi
if [[ ! "$TELEGRAM_CHAT_ID" =~ ^(-?[0-9]+|@[A-Za-z0-9_]{5,})$ ]]; then
    log "TELEGRAM_CHAT_ID com formato inválido; aviso não enviado"
    exit 1
fi

texto="$titulo — $NOTIFY_HOST
$mensagem
$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
texto="${texto:0:$LIMITE_TEXTO}"

# Texto puro (sem parse_mode): nada na mensagem precisa ser escapado.
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
if printf 'url = "%s/bot%s/sendMessage"\n' "$TELEGRAM_API_URL" "$TELEGRAM_BOT_TOKEN" |
    "$CURL" --silent --show-error --fail --max-time 20 --config - \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$texto" \
        --data "disable_web_page_preview=true" >/dev/null 2>"$err"; then
    exit 0
fi

# O erro do curl pode conter a URL (com o token): troca o token antes de logar.
erro="$(sed "s/$TELEGRAM_BOT_TOKEN/<token>/g" "$err" | tr '\n' ' ' | head -c 300)"
log "aviso pelo Telegram NÃO enviado (${erro:-erro desconhecido})"
exit 1

#!/usr/bin/env bash
# install.sh — instala o kit de backup restic num servidor Linux (systemd)
#
#   sudo ./install.sh
#
# Não sobrescreve configuração existente. Não ativa os timers sozinho:
# primeiro você preenche /etc/backup-restic/backup.env e testa.
set -euo pipefail

RAIZ="${RAIZ:-}"                     # prefixo para testes (ex.: RAIZ=/tmp/fake)
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$RAIZ/usr/local/bin"
CONF="$RAIZ/etc/backup-restic"
UNITS="$RAIZ/etc/systemd/system"
STATE="$RAIZ/var/lib/backup-restic"

if [[ -z "$RAIZ" && $EUID -ne 0 ]]; then echo "Rode como root (sudo ./install.sh)"; exit 1; fi

if ! command -v restic >/dev/null; then
    echo "AVISO: restic não encontrado. Instale antes de usar (ex.: apt install restic && restic self-update)."
fi
command -v sqlite3 >/dev/null || echo "AVISO: sqlite3 não encontrado (necessário só para bancos SQLite)."
command -v curl >/dev/null || echo "AVISO: curl não encontrado (necessário só para o aviso pelo Telegram)."

mkdir -p "$BIN" "$CONF" "$UNITS" "$STATE"
install -m 0755 "$AQUI"/bin/backup-*.sh "$BIN/"
install -m 0644 "$AQUI"/systemd/backup-restic*.service "$AQUI"/systemd/backup-restic*.timer "$UNITS/"

copiar_se_faltar() { [[ -e "$2" ]] && echo "mantido:  $2" || { install -m "$3" "$1" "$2"; echo "criado:   $2"; }; }
copiar_se_faltar "$AQUI/exemplos/backup.env.example" "$CONF/backup.env" 0600
copiar_se_faltar "$AQUI/exemplos/dumps.conf.example" "$CONF/dumps.conf" 0600
copiar_se_faltar "$AQUI/exemplos/excludes.example"   "$CONF/excludes"   0644

if [[ ! -e "$CONF/restic-password" ]]; then
    ( umask 077; head -c 48 /dev/urandom | base64 | tr -d '\n=+/' > "$CONF/restic-password" )
    echo "criado:   $CONF/restic-password  <- COPIE ESTA SENHA PARA FORA DO SERVIDOR"
fi
chmod 700 "$CONF"

# O agente do Zabbix precisa ler as marcas de sucesso
chmod 755 "$STATE"
for d in "$RAIZ/etc/zabbix/zabbix_agent2.d" "$RAIZ/etc/zabbix/zabbix_agentd.d"; do
    if [[ -d "$d" ]]; then install -m 0644 "$AQUI/zabbix/backup-restic.conf" "$d/"; echo "zabbix:   $d/backup-restic.conf (reinicie o agente)"; fi
done

[[ -z "$RAIZ" ]] && systemctl daemon-reload

cat <<EOF

Instalado. Próximos passos:
  1. Edite $CONF/backup.env (R2, caminhos) e $CONF/dumps.conf (bancos).
  2. Rode um backup manual:      sudo backup-run.sh && tail -20 /var/log/backup-restic.log
  3. Prove que volta:            sudo backup-restore-test.sh
     (no dia em que precisar:   sudo backup-restaurar.sh)
  4. Ative os agendamentos:      sudo systemctl enable --now backup-restic.timer backup-restic-check.timer
  5. No Zabbix, crie o item backup.restic.age e o alerta (veja o README).
  6. (Opcional) Aviso pelo Telegram: preencha TELEGRAM_BOT_TOKEN e TELEGRAM_CHAT_ID
     no backup.env e teste com:  sudo backup-notify.sh teste "funcionou"
EOF

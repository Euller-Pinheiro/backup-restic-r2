#!/usr/bin/env bash
# shellcheck disable=SC2034  # variáveis lidas dentro das expressões passadas a ok() (eval)
# Teste de ponta a ponta do kit (repositório restic LOCAL, sem nuvem).
# Requer: restic, sqlite3, gzip, flock.   Uso: ./tests/test.sh
set -uo pipefail

RAIZ_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
falhas=0
ok()    { if eval "$2"; then echo "  [ok]    $1"; else echo "  [FALHA] $1"; falhas=$((falhas + 1)); fi; }

# --------------------------------------------------------------- instalação
echo "1. Instalação (em diretório de teste)"
RAIZ="$T/raiz" "$RAIZ_REPO/install.sh" >/dev/null
mkdir -p "$T/raiz/etc/zabbix/zabbix_agent2.d"
RAIZ="$T/raiz" "$RAIZ_REPO/install.sh" > "$T/install2.out"
CONF="$T/raiz/etc/backup-restic"
BIN="$T/raiz/usr/local/bin"
ok "scripts instalados"                 '[[ -x $BIN/backup-run.sh && -x $BIN/backup-dumps.sh && -x $BIN/backup-check.sh && -x $BIN/backup-restore-test.sh && -f $BIN/backup-lib.sh ]]'
ok "senha do repositório gerada (600)"  '[[ -s $CONF/restic-password && $(stat -c %a $CONF/restic-password) == 600 ]]'
ok "backup.env com permissão 600"       '[[ $(stat -c %a $CONF/backup.env) == 600 ]]'
ok "reinstalar mantém a configuração"   'grep -q "mantido:  .*backup.env" "$T/install2.out"'
ok "config do Zabbix copiada"           '[[ -f $T/raiz/etc/zabbix/zabbix_agent2.d/backup-restic.conf ]]'

# --------------------------------------------------------------- cenário
mkdir -p "$T/app/dados" "$T/fakebin"
sqlite3 "$T/app/app1.sqlite3" "CREATE TABLE t(x); INSERT INTO t VALUES (1),(2),(3);"
sqlite3 "$T/app/app2.sqlite3" "CREATE TABLE u(y); INSERT INTO u VALUES ('a');"
echo "arquivo do app" > "$T/app/dados/config.txt"
# mysqldump falso: imprime um dump válido
cat > "$T/fakebin/mysqldump" <<'EOF'
#!/usr/bin/env bash
db="${@: -1}"
echo "$*" > "$FAKE_ARGS_LOG"
echo "-- MySQL dump (falso) do banco $db"
echo "CREATE TABLE t (id int);"
echo "-- Dump completed on $(date)"
EOF
chmod +x "$T/fakebin/mysqldump"
export FAKE_ARGS_LOG="$T/mysqldump.args"
export PATH="$T/fakebin:$BIN:$PATH"

cat > "$CONF/backup.env" <<EOF
RESTIC_REPOSITORY=$T/repo
RESTIC_PASSWORD_FILE=$CONF/restic-password
BACKUP_PATHS="$T/app/dados"
DUMP_DIR=$T/dumps
STATE_DIR=$T/state
LOG_FILE=$T/backup.log
EXCLUDES_FILE=$CONF/excludes
KEEP_LAST=2
KEEP_DAILY=0
KEEP_WEEKLY=0
KEEP_MONTHLY=0
EOF
cat > "$CONF/dumps.conf" <<EOF
# comentário
sqlite  app1   $T/app/app1.sqlite3
sqlite  app2   $T/app/app2.sqlite3
mysql   erp    erp_producao --skip-lock-tables
EOF
export BACKUP_CONF_DIR="$CONF"
set -a; . "$CONF/backup.env"; set +a
snaps() { restic snapshots --json 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'; }

# --------------------------------------------------------------- ciclo OK
echo "2. Primeiro backup"
backup-run.sh 2>/dev/null; rc=$?
ok "backup-run termina com sucesso"     '[[ $rc -eq 0 ]]'
ok "repositório criado sozinho"         '[[ -f $T/repo/config ]]'
ok "1 snapshot"                         '[[ $(snaps) -eq 1 ]]'
ok "dumps gerados (2 sqlite + 1 mysql)" '[[ -f $T/dumps/sqlite-app1.sqlite3 && -f $T/dumps/sqlite-app2.sqlite3 && -f $T/dumps/mysql-erp.sql.gz ]]'
ok "marca de sucesso gravada"           '[[ -s $T/state/last-success ]]'
ok "args extras chegam ao mysqldump"   'grep -q -- "--single-transaction.*--skip-lock-tables erp_producao" "$T/mysqldump.args"'

echo "3. Restauração de verdade"
backup-restore-test.sh > "$T/restore.out" 2>&1; rc=$?
ok "restore-test confere os 3 dumps"    '[[ $rc -eq 0 ]] && grep -q "3 dumps conferidos" "$T/restore.out"'
ok "arquivo comum também volta"         'mkdir -p $T/r && restic restore latest --target $T/r --include $T/app/dados >/dev/null 2>&1 && diff -q $T/app/dados/config.txt $T/r$T/app/dados/config.txt >/dev/null'

echo "4. Verificação do repositório"
backup-check.sh 2>/dev/null; rc=$?
ok "check OK e marca gravada"           '[[ $rc -eq 0 && -s $T/state/last-check ]]'

echo "5. Retenção (KEEP_LAST=2)"
sqlite3 "$T/app/app1.sqlite3" "INSERT INTO t VALUES (4);"; backup-run.sh 2>/dev/null
sqlite3 "$T/app/app1.sqlite3" "INSERT INTO t VALUES (5);"; backup-run.sh 2>/dev/null
ok "fica no máximo 2 snapshots"         '[[ $(snaps) -eq 2 ]]'

echo "6. Falhas NÃO viram sucesso"
antes="$(cat "$T/state/last-success")"; n_antes="$(snaps)"; sleep 1
echo "sqlite  sumiu  $T/app/nao-existe.sqlite3" >> "$CONF/dumps.conf"
backup-run.sh 2>/dev/null; rc=$?
ok "banco ausente -> código de erro"    '[[ $rc -ne 0 ]]'
ok "marca de sucesso NÃO atualizada"    '[[ "$(cat $T/state/last-success)" == "$antes" ]]'
ok "nenhum snapshot novo"               '[[ $(snaps) -eq $n_antes ]]'
sed -i '/sumiu/d' "$CONF/dumps.conf"
echo "isto não é um banco sqlite" > "$T/app/corrompido.sqlite3"
echo "sqlite  ruim   $T/app/corrompido.sqlite3" >> "$CONF/dumps.conf"
backup-run.sh 2>/dev/null; rc=$?
ok "banco corrompido -> código de erro" '[[ $rc -ne 0 ]]'
ok "dump anterior bom não é apagado"    '[[ $(sqlite3 $T/dumps/sqlite-app1.sqlite3 "SELECT count(*) FROM t") -eq 5 ]]'
sed -i '/ruim/d' "$CONF/dumps.conf"

echo "7. Trava contra execução dupla"
exec 8>"$T/state/.lock"; flock -n 8
backup-run.sh 2>/dev/null; rc=$?
ok "segunda execução simultânea sai com 3" '[[ $rc -eq 3 ]]'
flock -u 8; exec 8>&-

echo "8. Item do Zabbix"
cmd="$(sed -n 's/^UserParameter=backup.restic.age,//p' "$RAIZ_REPO/zabbix/backup-restic.conf" | sed "s#/var/lib/backup-restic#$T/state#")"
idade="$(bash -c "$cmd")"
ok "backup.restic.age devolve segundos (recente)" '[[ "$idade" =~ ^[0-9]+$ && $idade -lt 120 ]]'
cmd2="$(sed -n 's/^UserParameter=backup.restic.age,//p' "$RAIZ_REPO/zabbix/backup-restic.conf" | sed "s#/var/lib/backup-restic#$T/nada#")"
ok "sem backup nunca feito -> 999999999"  '[[ "$(bash -c "$cmd2")" == 999999999 ]]'

echo "9. Aviso pelo Telegram (servidor falso local)"
python3 "$RAIZ_REPO/tests/telegram_falso.py" "$T/tg.porta" "$T/tg.pedidos" &
tg_pid=$!
trap 'kill "$tg_pid" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 50); do [[ -s "$T/tg.porta" ]] && break; sleep 0.1; done
touch "$T/tg.pedidos"
backup-run.sh 2>/dev/null   # limpa a marca de falha deixada pela parte 6, ainda sem aviso
TOKEN_TESTE="123456789:AAE-token_de_teste"
cp "$CONF/backup.env" "$T/backup.env.sem-aviso"
cat >> "$CONF/backup.env" <<EOF
TELEGRAM_API_URL=http://127.0.0.1:$(cat "$T/tg.porta")
TELEGRAM_BOT_TOKEN=$TOKEN_TESTE
TELEGRAM_CHAT_ID=-1001234567890
NOTIFY_HOST=servidor-teste
EOF
pedidos() { wc -l < "$T/tg.pedidos"; }
ultimo()  { tail -n 1 "$T/tg.pedidos" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"$1\"])"; }

n="$(pedidos)"; backup-run.sh 2>/dev/null; rc=$?
ok "sucesso normal não avisa (NOTIFY_ON=falha)" '[[ $rc -eq 0 && $(pedidos) -eq $n ]]'

echo "sqlite  sumiu  $T/app/nao-existe.sqlite3" >> "$CONF/dumps.conf"
backup-run.sh 2>/dev/null; rc=$?
ok "falha nos dumps manda 1 aviso"         '[[ $rc -ne 0 && $(pedidos) -eq $((n + 1)) ]]'
ok "aviso vai para o bot e o chat certos"  '[[ "$(ultimo caminho)" == "/bot$TOKEN_TESTE/sendMessage" && "$(ultimo chat_id)" == -1001234567890 ]]'
ok "aviso diz o servidor e a etapa"        'ultimo text | grep -q "FALHA.*servidor-teste" && ultimo text | grep -q "FALHA nos dumps"'
sed -i '/sumiu/d' "$CONF/dumps.conf"

backup-run.sh 2>/dev/null; rc=$?
ok "sucesso depois da falha avisa a volta" '[[ $rc -eq 0 && $(pedidos) -eq $((n + 2)) ]] && ultimo text | grep -q "voltou a funcionar"'
backup-run.sh 2>/dev/null
ok "a volta ao normal é avisada só 1 vez"  '[[ $(pedidos) -eq $((n + 2)) ]]'

NOTIFY_ON=sempre backup-run.sh 2>/dev/null
ok "NOTIFY_ON=sempre avisa o sucesso"      '[[ $(pedidos) -eq $((n + 3)) ]] && ultimo text | grep -q "Backup concluído"'
echo "sqlite  sumiu  $T/app/nao-existe.sqlite3" >> "$CONF/dumps.conf"
NOTIFY_ON=desligado backup-run.sh 2>/dev/null
ok "NOTIFY_ON=desligado não avisa a falha" '[[ $(pedidos) -eq $((n + 3)) ]]'
sed -i '/sumiu/d' "$CONF/dumps.conf"
backup-run.sh 2>/dev/null

RESTIC=false backup-check.sh 2>/dev/null; rc=$?
ok "falha na verificação avisa"            '[[ $rc -ne 0 ]] && ultimo text | grep -q "verificação do repositório"'
backup-check.sh 2>/dev/null
ok "verificação OK depois da falha avisa"  'ultimo text | grep -q "Verificação do repositório OK depois"'

m="$(pedidos)"
# Telegram fora do ar: aponta para uma porta fechada (o backup.env é relido a cada execução)
sed -i 's#^TELEGRAM_API_URL=.*#TELEGRAM_API_URL=http://127.0.0.1:1#' "$CONF/backup.env"
NOTIFY_ON=sempre backup-run.sh 2>/dev/null; rc=$?
ok "Telegram fora do ar não derruba o backup" '[[ $rc -eq 0 && -s $T/state/last-success ]]'
backup-notify.sh teste "x" 2>/dev/null; rc=$?
ok "envio que falha sai com 1 e é registrado" '[[ $rc -eq 1 ]] && grep -q "aviso pelo Telegram NÃO enviado" "$T/backup.log"'
ok "token nunca aparece no log"            '! grep -qF "$TOKEN_TESTE" "$T/backup.log"'
TELEGRAM_BOT_TOKEN='123:abc" -o /tmp/x' TELEGRAM_CHAT_ID=1 backup-notify.sh teste "x" 2>/dev/null; rc=$?
ok "token com formato inválido é recusado" '[[ $rc -eq 1 && $(pedidos) -eq $m ]]'
backup-notify.sh 2>/dev/null; rc=$?
ok "uso sem argumentos sai com 2"          '[[ $rc -eq 2 ]]'
cp "$T/backup.env.sem-aviso" "$CONF/backup.env"
env -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID backup-notify.sh falha "x"; rc=$?
ok "sem configuração não envia nada (0)"   '[[ $rc -eq 0 && $(pedidos) -eq $m ]]'

echo
if (( falhas > 0 )); then echo "$falhas verificação(ões) falharam"; exit 1; fi
echo "Todos os testes passaram."

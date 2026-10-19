#!/usr/bin/env bash
# backup-restore-test.sh — prova que o backup volta: restaura os dumps do último
# snapshot numa pasta temporária e confere cada um.
#
#   SQLite   -> PRAGMA integrity_check = ok
#   MySQL    -> gzip íntegro e contém "Dump completed"
#   Postgres -> pg_restore --list funciona (se pg_restore existir)
#
# Backup que nunca foi restaurado é só esperança. Rode isto depois de instalar
# e de tempos em tempos (ex.: uma vez por mês).
set -uo pipefail

CONF_DIR="${BACKUP_CONF_DIR:-/etc/backup-restic}"
ENV_FILE="${ENV_FILE:-$CONF_DIR/backup.env}"
if [[ ! -r "$ENV_FILE" ]]; then echo "ERRO: não consigo ler $ENV_FILE" >&2; exit 2; fi
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a
DUMP_DIR="${DUMP_DIR:-/var/backups/restic-dumps}"
RESTIC="${RESTIC:-restic}"

alvo="$(mktemp -d)"
trap 'rm -rf "$alvo"' EXIT

echo "Restaurando $DUMP_DIR do último snapshot..."
if ! "$RESTIC" restore latest --tag auto --target "$alvo" --include "$DUMP_DIR" >/dev/null; then
    echo "FALHA: restic restore"; exit 1
fi

falhas=0; total=0
while IFS= read -r -d '' f; do
    total=$((total + 1))
    case "$f" in
        *.sqlite3)
            r="$(sqlite3 "$f" 'PRAGMA integrity_check;' 2>&1)"
            if [[ "$r" == "ok" ]]; then echo "  ok     $(basename "$f")"; else echo "  FALHA  $(basename "$f"): $r"; falhas=$((falhas + 1)); fi ;;
        *.sql.gz)
            if gzip -t "$f" && zcat "$f" | tail -n 3 | grep -q 'Dump completed'; then echo "  ok     $(basename "$f")"
            else echo "  FALHA  $(basename "$f"): gzip corrompido ou dump incompleto"; falhas=$((falhas + 1)); fi ;;
        *.dump)
            if ! command -v pg_restore >/dev/null; then echo "  ?      $(basename "$f") (pg_restore não instalado)"
            elif pg_restore --list "$f" >/dev/null 2>&1; then echo "  ok     $(basename "$f")"
            else echo "  FALHA  $(basename "$f"): pg_restore não consegue ler"; falhas=$((falhas + 1)); fi ;;
        *) total=$((total - 1)) ;;
    esac
done < <(find "$alvo" -type f -print0)

if (( total == 0 )); then echo "FALHA: nenhum dump encontrado no snapshot"; exit 1; fi
if (( falhas > 0 )); then echo "$falhas de $total dumps com problema"; exit 1; fi
echo "Restauração OK: $total dumps conferidos."

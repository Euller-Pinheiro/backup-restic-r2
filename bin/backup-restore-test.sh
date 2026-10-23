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
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-lib.sh
. "$AQUI/backup-lib.sh"
RESTIC="${RESTIC:-restic}"

alvo="$(mktemp -d)"
trap 'rm -rf "$alvo"' EXIT

echo "Restaurando $DUMP_DIR do último snapshot..."
if ! "$RESTIC" restore latest --tag auto --target "$alvo" --include "$DUMP_DIR" >/dev/null; then
    echo "FALHA: restic restore"; exit 1
fi

falhas=0; total=0
while IFS= read -r -d '' f; do
    conferir_dump "$f"; rc=$?
    (( rc == 3 )) && continue          # não é dump (arquivo comum do snapshot)
    total=$((total + 1))
    (( rc == 1 )) && falhas=$((falhas + 1))
done < <(find "$alvo" -type f -print0)

if (( total == 0 )); then echo "FALHA: nenhum dump encontrado no snapshot"; exit 1; fi
if (( falhas > 0 )); then echo "$falhas de $total dumps com problema"; exit 1; fi
echo "Restauração OK: $total dumps conferidos."

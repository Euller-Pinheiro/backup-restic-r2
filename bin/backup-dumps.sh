#!/usr/bin/env bash
# backup-dumps.sh — gera dumps consistentes dos bancos listados em dumps.conf
#
# Cada linha de dumps.conf:
#   sqlite    <nome> <caminho/arquivo.sqlite3>
#   mysql     <nome> <banco> [argumentos extras do mysqldump...]
#   postgres  <nome> <banco> [argumentos extras do pg_dump...]
# Linhas vazias e começando com # são ignoradas.
#
# Regras:
#   - SQLite: ".backup" (cópia consistente mesmo com o app gravando) + PRAGMA integrity_check.
#   - MySQL/MariaDB: mysqldump --single-transaction (sem travar tabelas InnoDB), comprimido.
#   - PostgreSQL: pg_dump -Fc (formato custom, já comprimido).
#   - Cada dump é escrito num arquivo temporário e só substitui o anterior se terminar OK.
#   - Sai com código != 0 se QUALQUER dump falhar (o backup-run.sh então não marca sucesso).
set -uo pipefail

CONF_DIR="${BACKUP_CONF_DIR:-/etc/backup-restic}"
DUMPS_CONF="${DUMPS_CONF:-$CONF_DIR/dumps.conf}"
DUMP_DIR="${DUMP_DIR:-/var/backups/restic-dumps}"
LOG_FILE="${LOG_FILE:-/var/log/backup-restic.log}"
MYSQLDUMP="${MYSQLDUMP:-mysqldump}"
PG_DUMP="${PG_DUMP:-pg_dump}"

log() { printf '%s [dumps] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }

falhas=0
ok()   { log "OK    $1 $2"; }
erro() { log "ERRO  $1 $2: $3"; falhas=$((falhas + 1)); }

dump_sqlite() {
    local nome="$1" origem="$2"
    local destino="$DUMP_DIR/sqlite-$nome.sqlite3" tmp="$DUMP_DIR/.sqlite-$nome.tmp"
    if [[ ! -f "$origem" ]]; then erro sqlite "$nome" "arquivo não existe: $origem"; return; fi
    rm -f "$tmp"
    if ! sqlite3 "$origem" ".timeout 30000" ".backup '$tmp'" 2>>"$LOG_FILE"; then
        erro sqlite "$nome" ".backup falhou"; rm -f "$tmp"; return
    fi
    local integ
    integ="$(sqlite3 "$tmp" 'PRAGMA integrity_check;' 2>&1)"
    if [[ "$integ" != "ok" ]]; then
        erro sqlite "$nome" "integrity_check: $integ"; rm -f "$tmp"; return
    fi
    mv -f "$tmp" "$destino" && ok sqlite "$nome"
}

dump_mysql() {
    local nome="$1" banco="$2"; shift 2
    local destino="$DUMP_DIR/mysql-$nome.sql.gz" tmp="$DUMP_DIR/.mysql-$nome.tmp"
    if "$MYSQLDUMP" --single-transaction --quick --routines --events --triggers "$@" "$banco" 2>>"$LOG_FILE" | gzip -6 > "$tmp" \
       && gzip -t "$tmp" && [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$destino" && ok mysql "$nome"
    else
        erro mysql "$nome" "mysqldump falhou"; rm -f "$tmp"
    fi
}

dump_postgres() {
    local nome="$1" banco="$2"; shift 2
    local destino="$DUMP_DIR/postgres-$nome.dump" tmp="$DUMP_DIR/.postgres-$nome.tmp"
    if "$PG_DUMP" -Fc "$@" -f "$tmp" "$banco" 2>>"$LOG_FILE" && [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$destino" && ok postgres "$nome"
    else
        erro postgres "$nome" "pg_dump falhou"; rm -f "$tmp"
    fi
}

mkdir -p "$DUMP_DIR" && chmod 700 "$DUMP_DIR"
if [[ ! -f "$DUMPS_CONF" ]]; then
    log "sem $DUMPS_CONF: nenhum banco para exportar"
    exit 0
fi

log "=== início ==="
lin=0
while read -r tipo nome resto || [[ -n "${tipo:-}" ]]; do
    lin=$((lin + 1))
    [[ -z "${tipo:-}" || "${tipo:0:1}" == "#" ]] && continue
    # shellcheck disable=SC2206  # argumentos extras são separados por espaço de propósito
    args=( ${resto:-} )
    if [[ -z "${nome:-}" || ${#args[@]} -lt 1 ]]; then
        erro "linha$lin" "?" "linha incompleta em $DUMPS_CONF"; continue
    fi
    case "$tipo" in
        sqlite)   dump_sqlite   "$nome" "${args[0]}" ;;
        mysql)    dump_mysql    "$nome" "${args[@]}" ;;
        postgres) dump_postgres "$nome" "${args[@]}" ;;
        *)        erro "$tipo" "$nome" "tipo desconhecido (use sqlite, mysql ou postgres)" ;;
    esac
done < "$DUMPS_CONF"

if (( falhas > 0 )); then
    log "=== fim com $falhas falha(s) ==="
    exit 1
fi
log "=== fim: todos os dumps OK ==="

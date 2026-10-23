#!/usr/bin/env bash
# backup-lib.sh — funções compartilhadas pelos scripts do kit.
#
# Não é para rodar sozinho: os outros scripts carregam este arquivo com
#   . "$AQUI/backup-lib.sh"
# Fica em bin/ ao lado deles para que o install.sh o copie junto.

# conferir_dump <arquivo>
#   Confere se um dump restaurado está utilizável, pelo tipo (extensão):
#     *.sqlite3 -> PRAGMA integrity_check = ok
#     *.sql.gz  -> gzip íntegro e termina com "Dump completed" (mysqldump)
#     *.dump    -> pg_restore --list consegue ler (se pg_restore existir)
#   Imprime uma linha "  ok     nome" / "  FALHA  nome: motivo" / "  ?      nome (...)".
#   Retorno: 0 = ok, 1 = com problema, 2 = não deu para conferir, 3 = não é dump.
conferir_dump() {
    local f="$1" nome r
    nome="$(basename "$f")"
    case "$f" in
        *.sqlite3)
            r="$(sqlite3 "$f" 'PRAGMA integrity_check;' 2>&1)"
            if [[ "$r" == "ok" ]]; then echo "  ok     $nome"; return 0; fi
            echo "  FALHA  $nome: $r"; return 1 ;;
        *.sql.gz)
            if gzip -t "$f" 2>/dev/null && zcat "$f" | tail -n 3 | grep -q 'Dump completed'; then
                echo "  ok     $nome"; return 0
            fi
            echo "  FALHA  $nome: gzip corrompido ou dump incompleto"; return 1 ;;
        *.dump)
            if ! command -v pg_restore >/dev/null; then
                echo "  ?      $nome (pg_restore não instalado)"; return 2
            fi
            if pg_restore --list "$f" >/dev/null 2>&1; then echo "  ok     $nome"; return 0; fi
            echo "  FALHA  $nome: pg_restore não consegue ler"; return 1 ;;
        *) return 3 ;;
    esac
}

#!/usr/bin/env bash
# backup-restaurar.sh — assistente de restauração.
#
# Pergunta, passo a passo, QUAL snapshot, O QUE restaurar (um dump de banco,
# um arquivo ou pasta, ou o snapshot inteiro) e PARA ONDE. Restaura sempre numa
# pasta separada, nunca por cima do original, confere os dumps restaurados e
# mostra o comando para colocar cada coisa no lugar.
#
#   sudo backup-restaurar.sh                      # assistente interativo
#   sudo backup-restaurar.sh --listar             # só lista os snapshots
#   sudo backup-restaurar.sh -s latest -d sqlite-app1.sqlite3 -y
#
# Tudo o que não vier por opção é perguntado. Veja --ajuda.
set -uo pipefail

CONF_DIR="${BACKUP_CONF_DIR:-/etc/backup-restic}"
ENV_FILE="${ENV_FILE:-$CONF_DIR/backup.env}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-lib.sh
. "$AQUI/backup-lib.sh"

# Códigos de saída
readonly SAI_OK=0 SAI_FALHA=1 SAI_USO=2 SAI_CANCELADO=4

uso() {
    cat <<'EOF'
Uso: backup-restaurar.sh [opções]

Sem opções, pergunta tudo. Cada opção dada pula a pergunta correspondente.

  -s, --snapshot ID      snapshot a restaurar ("latest" = o mais recente)
  -d, --dump ARQUIVO     restaura só esse dump (ex.: sqlite-app1.sqlite3)
  -c, --caminho CAMINHO  restaura só esse arquivo ou pasta (caminho original, absoluto)
  -t, --tudo             restaura o snapshot inteiro
  -D, --destino PASTA    pasta de destino; precisa estar vazia ou não existir
                         (padrão: /var/tmp/restaurado-<snapshot>-<data>)
  -y, --sim              não pede confirmação e aceita os padrões
                         (snapshot mais recente e destino padrão)
  -l, --listar           lista os snapshots e sai
  -h, --ajuda            mostra esta ajuda

Nunca restaura por cima dos arquivos originais: o resultado fica em
<destino>/<caminho original>, e o script mostra como colocar no lugar.

Saída: 0 ok | 1 falha na restauração ou dump com problema | 2 uso ou
configuração inválida | 4 cancelado
EOF
}

erro_uso() { echo "ERRO: $*" >&2; exit "$SAI_USO"; }

# ------------------------------------------------------------------ opções
snapshot="" modo="" item="" destino="" sim=0 listar=0
definir_modo() {
    [[ -n "$modo" && "$modo" != "$1" ]] && erro_uso "use só uma entre --dump, --caminho e --tudo"
    modo="$1"
}
while (( $# > 0 )); do
    case "$1" in
        -s|--snapshot) (( $# >= 2 )) || erro_uso "$1 precisa de um valor"; snapshot="$2"; shift 2 ;;
        -d|--dump)     (( $# >= 2 )) || erro_uso "$1 precisa de um valor"; definir_modo dump;    item="$2"; shift 2 ;;
        -c|--caminho)  (( $# >= 2 )) || erro_uso "$1 precisa de um valor"; definir_modo caminho; item="$2"; shift 2 ;;
        -t|--tudo)     definir_modo tudo; shift ;;
        -D|--destino)  (( $# >= 2 )) || erro_uso "$1 precisa de um valor"; destino="$2"; shift 2 ;;
        -y|--sim)      sim=1; shift ;;
        -l|--listar)   listar=1; shift ;;
        -h|--ajuda)    uso; exit "$SAI_OK" ;;
        *)             echo "Opção desconhecida: $1" >&2; uso >&2; exit "$SAI_USO" ;;
    esac
done

# ------------------------------------------------------------ configuração
if [[ ! -r "$ENV_FILE" ]]; then echo "ERRO: não consigo ler $ENV_FILE" >&2; exit "$SAI_USO"; fi
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a
: "${RESTIC_REPOSITORY:?defina RESTIC_REPOSITORY em $ENV_FILE}"
DUMP_DIR="${DUMP_DIR:-/var/backups/restic-dumps}"
DUMPS_CONF="${DUMPS_CONF:-$CONF_DIR/dumps.conf}"
LOG_FILE="${LOG_FILE:-/var/log/backup-restic.log}"
RESTAURAR_EM="${RESTAURAR_EM:-/var/tmp}"
RESTIC="${RESTIC:-restic}"

# Registro de quem restaurou o quê. Se o log não puder ser gravado (usuário
# sem permissão), a restauração segue mesmo assim.
log() { printf '%s [restaurar] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

# ------------------------------------------------------------- perguntas
# perguntar "texto" "padrão" -> resposta em $resposta. O texto vai para a saída
# de erro, para não se misturar com a saída do script. Lê da entrada padrão, o
# que permite responder por um pipe (ex.: nos testes). Sem resposta (fim da
# entrada), sai com erro em vez de seguir com um valor que ninguém escolheu.
resposta=""
perguntar() {
    local texto="$1" padrao="${2:-}"
    if [[ -n "$padrao" ]]; then printf '%s [%s]: ' "$texto" "$padrao" >&2; else printf '%s: ' "$texto" >&2; fi
    if ! IFS= read -r resposta; then
        echo >&2; erro_uso "a pergunta \"$texto\" ficou sem resposta (use as opções para rodar sem perguntas)"
    fi
    [[ -z "$resposta" ]] && resposta="$padrao"
    return 0
}

# escolher_da_lista "título" item1 item2 ... -> item escolhido em $resposta.
# Aceita o número da lista. Enter escolhe o primeiro.
escolher_da_lista() {
    local titulo="$1"; shift
    local i=1 opcao
    echo "$titulo" >&2
    for opcao in "$@"; do printf '  %2d) %s\n' "$i" "$opcao" >&2; i=$((i + 1)); done
    while true; do
        perguntar "Número" 1
        if [[ "$resposta" =~ ^[0-9]+$ ]] && (( resposta >= 1 && resposta <= $# )); then
            resposta="${!resposta}"; return 0
        fi
        echo "  Escolha um número de 1 a $#." >&2
    done
}

confirmar() {
    (( sim )) && return 0
    perguntar "$1 (s/N)"
    [[ "$resposta" =~ ^[sS]([iI][mM])?$ ]]
}

# ------------------------------------------------------------- snapshots
# Mostra a tabela do próprio restic: ela já traz data, servidor e pastas.
listar_snapshots() {
    "$RESTIC" snapshots --tag auto
}

# id_curto <snapshot> -> imprime o ID curto (8 caracteres) ou falha se não existir.
# O cabeçalho do "restic ls" diz qual snapshot foi escolhido, inclusive para "latest".
id_curto() {
    local cabecalho
    cabecalho="$("$RESTIC" ls --tag auto "$1" /.restaurar-nada 2>/dev/null | head -n 1)" || return 1
    [[ "$cabecalho" =~ ^snapshot\ ([0-9a-f]{8}) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# Só "latest" ou um prefixo hexadecimal: evita que um texto qualquer chegue ao
# restic como se fosse uma opção.
snapshot_valido() { [[ "$1" == latest || "$1" =~ ^[0-9a-f]{4,64}$ ]]; }

# existe_no_snapshot <id> <caminho> -> 0 se o arquivo ou pasta está no snapshot.
# "restic ls" com filtro lista a pasta e o que há dentro dela; procurar o
# caminho na listagem da pasta-mãe funciona tanto para arquivo quanto para pasta.
existe_no_snapshot() {
    local pai
    pai="$(dirname -- "$2")"
    "$RESTIC" ls "$1" "$pai" 2>/dev/null | tail -n +2 | grep -Fxq -- "$2"
}

# dumps_no_snapshot <id> -> nomes dos dumps (só o nome do arquivo), um por linha.
dumps_no_snapshot() {
    "$RESTIC" ls "$1" "$DUMP_DIR" 2>/dev/null | tail -n +2 \
        | awk -v d="$DUMP_DIR/" 'index($0, d) == 1 { n = substr($0, length(d) + 1); if (n !~ /\//) print n }' \
        | grep -E '\.(sqlite3|sql\.gz|dump)$'
}

# ------------------------------------------------------------ dicas finais
# origem_do_dump <tipo> <nome> -> 3ª coluna da linha de dumps.conf (arquivo do
# SQLite ou nome do banco), para mostrar o comando exato de volta.
origem_do_dump() {
    [[ -r "$DUMPS_CONF" ]] || return 1
    awk -v t="$1" -v n="$2" '$1 == t && $2 == n { print $3; exit }' "$DUMPS_CONF"
}

dica_dump() {
    local arquivo="$1" nome tipo base origem
    nome="$(basename "$arquivo")"
    case "$nome" in
        sqlite-*.sqlite3) tipo=sqlite;   base="${nome#sqlite-}";   base="${base%.sqlite3}" ;;
        mysql-*.sql.gz)   tipo=mysql;    base="${nome#mysql-}";    base="${base%.sql.gz}" ;;
        postgres-*.dump)  tipo=postgres; base="${nome#postgres-}"; base="${base%.dump}" ;;
        *) return 0 ;;
    esac
    origem="$(origem_do_dump "$tipo" "$base")"
    echo
    echo "Como colocar $nome no lugar:"
    case "$tipo" in
        sqlite)
            origem="${origem:-<arquivo original do banco>}"
            echo "  1. Pare o aplicativo que usa o banco."
            echo "  2. Guarde o atual:   mv '$origem' '$origem.antes-da-restauracao'"
            echo "     Se existirem '$origem-wal' e '$origem-shm', mova-os também:"
            echo "     um WAL antigo aplicado sobre o banco restaurado o corrompe."
            echo "  3. Coloque o antigo: cp '$arquivo' '$origem'"
            echo "  4. Suba o aplicativo e confira." ;;
        mysql)
            origem="${origem:-<banco>}"
            echo "  Teste antes num banco novo, sem tocar no de produção:"
            echo "    mysql -e 'CREATE DATABASE ${origem}_restaurado'"
            echo "    zcat '$arquivo' | mysql ${origem}_restaurado"
            echo "  Para substituir o de produção (apaga as tabelas atuais):"
            echo "    zcat '$arquivo' | mysql $origem" ;;
        postgres)
            origem="${origem:-<banco>}"
            echo "  Teste antes num banco novo, sem tocar no de produção:"
            echo "    createdb ${origem}_restaurado && pg_restore -d ${origem}_restaurado '$arquivo'"
            echo "  Para substituir o de produção (recria os objetos):"
            echo "    pg_restore --clean --if-exists -d $origem '$arquivo'" ;;
    esac
}

dica_arquivos() {
    local restaurado="$1" original="$2"
    echo
    echo "Para comparar com o que está no servidor agora:"
    echo "  diff -r '$original' '$restaurado' | head"
    echo "Para colocar no lugar (veja antes o que mudaria com --dry-run):"
    if [[ -d "$restaurado" ]]; then
        echo "  rsync -a --dry-run -v '$restaurado/' '$original/'"
    else
        echo "  rsync -a --dry-run -v '$restaurado' '$original'"
    fi
}

# ============================================================== principal
if (( listar )); then listar_snapshots; exit $?; fi

# 1) Qual snapshot (com --sim, sem --snapshot: o mais recente)
(( sim )) && [[ -z "$snapshot" ]] && snapshot=latest
if [[ -z "$snapshot" ]]; then
    echo "Snapshots disponíveis (do mais antigo para o mais recente):" >&2
    listar_snapshots >&2 || { echo "FALHA: não consegui ler o repositório $RESTIC_REPOSITORY" >&2; exit "$SAI_FALHA"; }
    while true; do
        perguntar "ID do snapshot (Enter = o mais recente)" latest
        snapshot_valido "$resposta" && break
        echo "  Digite o ID (os 8 primeiros caracteres bastam) ou latest." >&2
    done
    snapshot="$resposta"
fi
snapshot_valido "$snapshot" || erro_uso "snapshot inválido: $snapshot (use latest ou o ID)"
if ! snap_id="$(id_curto "$snapshot")"; then
    echo "FALHA: snapshot $snapshot não encontrado (veja: backup-restaurar.sh --listar)" >&2
    exit "$SAI_FALHA"
fi

# 2) O que restaurar
if [[ -z "$modo" ]]; then
    escolher_da_lista "O que restaurar do snapshot $snap_id?" \
        "Um dump de banco de dados (de $DUMP_DIR)" \
        "Um arquivo ou uma pasta" \
        "O snapshot inteiro"
    case "$resposta" in
        Um\ dump*)    modo=dump ;;
        Um\ arquivo*) modo=caminho ;;
        *)            modo=tudo ;;
    esac
fi

incluir=""
case "$modo" in
    dump)
        mapfile -t dumps < <(dumps_no_snapshot "$snap_id")
        if (( ${#dumps[@]} == 0 )); then
            echo "FALHA: o snapshot $snap_id não tem dumps em $DUMP_DIR" >&2; exit "$SAI_FALHA"
        fi
        if [[ -z "$item" ]]; then
            escolher_da_lista "Qual dump?" "${dumps[@]}"
            item="$resposta"
        fi
        item="${item##*/}"     # aceita o caminho completo ou só o nome
        printf '%s\n' "${dumps[@]}" | grep -Fxq -- "$item" \
            || { echo "FALHA: o dump $item não está no snapshot $snap_id. Há: ${dumps[*]}" >&2; exit "$SAI_FALHA"; }
        incluir="$DUMP_DIR/$item" ;;
    caminho)
        if [[ -z "$item" ]]; then
            perguntar "Caminho original do arquivo ou pasta (ex.: /etc/nginx)"
            item="$resposta"
        fi
        [[ "$item" == /* ]] || erro_uso "o caminho precisa ser absoluto (começar com /): $item"
        [[ "$item" == *$'\n'* ]] && erro_uso "caminho com quebra de linha não é aceito"
        while [[ "$item" == */ && "$item" != / ]]; do item="${item%/}"; done
        if [[ "$item" == / ]]; then
            modo=tudo
        else
            existe_no_snapshot "$snap_id" "$item" \
                || { echo "FALHA: $item não está no snapshot $snap_id" >&2; exit "$SAI_FALHA"; }
            incluir="$item"
        fi ;;
esac

# 3) Para onde. Nunca "/" (seria restaurar por cima do original) e nunca numa
#    pasta com conteúdo (o resultado se misturaria com o que já está lá).
if [[ -z "$destino" ]]; then
    padrao="$RESTAURAR_EM/restaurado-$snap_id-$(date '+%Y%m%d-%H%M%S')"
    if (( sim )); then
        destino="$padrao"
    else
        perguntar "Pasta de destino" "$padrao"
        destino="$resposta"
    fi
fi
[[ "$destino" == /* ]] || destino="$PWD/$destino"
destino="$(realpath -m -- "$destino")"
if [[ "$destino" == / ]]; then
    erro_uso "destino / sobrescreveria os arquivos originais; escolha uma pasta separada"
fi
if [[ -e "$destino" && ! -d "$destino" ]]; then erro_uso "$destino existe e não é uma pasta"; fi
if [[ -d "$destino" ]] && [[ -n "$(ls -A -- "$destino")" ]]; then
    erro_uso "$destino não está vazia; escolha outra pasta para não misturar arquivos"
fi

# 4) Confirmação
echo >&2
echo "Resumo:" >&2
echo "  snapshot  $snap_id" >&2
case "$modo" in
    dump)    echo "  restaurar o dump $item" >&2 ;;
    caminho) echo "  restaurar $item" >&2 ;;
    tudo)    echo "  restaurar o snapshot INTEIRO" >&2 ;;
esac
echo "  destino   $destino  (os originais não são tocados)" >&2
if ! confirmar "Restaurar agora?"; then echo "Cancelado. Nada foi restaurado." >&2; exit "$SAI_CANCELADO"; fi

# 5) Restauração. A pasta fica só para o root: dumps têm os dados do sistema.
( umask 077; mkdir -p -- "$destino" ) || { echo "FALHA: não consegui criar $destino" >&2; exit "$SAI_FALHA"; }
chmod 700 -- "$destino"
args=(restore "$snap_id" --target "$destino")
[[ -n "$incluir" ]] && args+=(--include "$incluir")
log "início: snapshot $snap_id, ${incluir:-snapshot inteiro} -> $destino (usuário ${SUDO_USER:-$(id -un)})"
if ! "$RESTIC" "${args[@]}" >/dev/null; then
    log "FALHA: restic restore do snapshot $snap_id"
    echo "FALHA: restic restore" >&2; exit "$SAI_FALHA"
fi
n_arquivos="$(find "$destino" -type f | wc -l)"
if (( n_arquivos == 0 )); then
    log "FALHA: nada restaurado do snapshot $snap_id"
    echo "FALHA: nenhum arquivo foi restaurado" >&2; exit "$SAI_FALHA"
fi

# 6) Conferência dos dumps que vieram na restauração
resultado="$SAI_OK"
dumps_restaurados=()
if [[ -d "$destino$DUMP_DIR" ]]; then
    while IFS= read -r -d '' f; do dumps_restaurados+=("$f"); done \
        < <(find "$destino$DUMP_DIR" -maxdepth 1 -type f -print0 | sort -z)
fi
echo
echo "Restaurado: $n_arquivos arquivo(s) em $destino"
if (( ${#dumps_restaurados[@]} > 0 )); then
    echo "Conferindo os dumps restaurados:"
    for f in "${dumps_restaurados[@]}"; do
        conferir_dump "$f"; rc=$?
        (( rc == 1 )) && resultado="$SAI_FALHA"
    done
fi

# 7) Como colocar no lugar
case "$modo" in
    dump)    dica_dump "$destino$incluir" ;;
    caminho) dica_arquivos "$destino$incluir" "$incluir" ;;
    tudo)
        echo
        echo "Cada arquivo está em $destino<caminho original>."
        echo "Para recuperar uma pasta, compare e copie com rsync, por exemplo:"
        echo "  rsync -a --dry-run -v '$destino/etc/' /etc/" ;;
esac

if (( resultado == SAI_OK )); then
    log "OK: snapshot $snap_id -> $destino ($n_arquivos arquivos)"
else
    log "FALHA: dump restaurado com problema (snapshot $snap_id -> $destino)"
    echo; echo "ATENÇÃO: há dump com problema. Tente um snapshot anterior."
fi
exit "$resultado"

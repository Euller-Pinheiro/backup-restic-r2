# Backup restic + Cloudflare R2

[![Testes](https://github.com/Euller-Pinheiro/backup-restic-r2/actions/workflows/testes.yml/badge.svg)](https://github.com/Euller-Pinheiro/backup-restic-r2/actions/workflows/testes.yml)
![Bash](https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=white)
![restic](https://img.shields.io/badge/restic-0.16%2B-blue)
![Licença MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-green)

**[English below](#english)**

Kit de backup para servidores Linux. Exporta os bancos de dados de forma consistente, cifra tudo com o [restic](https://restic.net), guarda no **Cloudflare R2** (ou em qualquer S3, B2, SFTP ou disco local), aplica retenção, verifica o repositório toda semana e **avisa no Zabbix e no Telegram** quando o backup para.

É a versão aberta do que eu uso em produção nos servidores da [ESX Tecnologia](https://esxtecnologia.com). O kit protege ERP, cofre de senhas, helpdesk e sites, e cada servidor ocupa uma fração dos 10 GB gratuitos do R2.

## Por que assim

| Problema comum | O que o kit faz |
|---|---|
| Copiar o arquivo do banco com o app rodando gera cópia corrompida | SQLite via `.backup` seguido de `PRAGMA integrity_check`. MySQL/MariaDB via `mysqldump --single-transaction`. PostgreSQL via `pg_dump -Fc`. |
| Um dump falha e substitui o bom de ontem | Cada dump é escrito num arquivo temporário e só substitui o anterior se passar na verificação. |
| O backup para de rodar e ninguém percebe | Uma marca de sucesso só é gravada se **todas** as etapas derem certo. O Zabbix lê a idade dela e alerta. |
| Backup que nunca foi restaurado | `backup-restore-test.sh` restaura os dumps do último snapshot e confere cada um. |
| Na hora do aperto, ninguém lembra a sintaxe do `restic restore` | `backup-restaurar.sh` pergunta o que restaurar, restaura numa pasta separada e mostra o comando para colocar no lugar. |
| Servidor invadido apaga o próprio backup | Recomendação: um bucket e um token por servidor, com escopo só naquele bucket. |
| O armazenamento corrompe em silêncio | Verificação semanal com `restic check --read-data-subset=10%`, sobre uma amostra diferente a cada vez. |
| O servidor roda em UTC e o horário "03:00" vira meia-noite | Os timers do systemd usam o sufixo `UTC` explícito. |
| Dois backups ao mesmo tempo | Trava com `flock`. A segunda execução sai sem fazer nada. |
| Quem não usa Zabbix só descobre a falha quando precisa restaurar | Aviso opcional pelo **Telegram** na falha e quando o backup volta ao normal. |

## O que vem no kit

```
bin/backup-dumps.sh          dumps consistentes (sqlite, mysql, postgres)
bin/backup-run.sh            ciclo: dumps -> restic backup -> retenção -> marca de sucesso
bin/backup-check.sh          verificação do repositório
bin/backup-restore-test.sh   restaura e confere os dumps do último snapshot
bin/backup-restaurar.sh      assistente de restauração (snapshot, o quê, para onde)
bin/backup-lib.sh            funções compartilhadas (conferência dos dumps)
bin/backup-notify.sh         aviso pelo Telegram (falha, volta ao normal, teste)
systemd/                     timers diário (backup) e semanal (verificação)
zabbix/backup-restic.conf    itens backup.restic.age e backup.restic.check.age
exemplos/                    backup.env, dumps.conf, excludes
install.sh                   instala sem sobrescrever a configuração existente
```

## Instalação

```bash
sudo apt install restic sqlite3 && sudo restic self-update
git clone https://github.com/Euller-Pinheiro/backup-restic-r2 && cd backup-restic-r2
sudo ./install.sh
```

1. **Cloudflare R2:** crie um bucket para o servidor (ex.: `backup-web01`). Em *Manage R2 API Tokens*, gere um token **Object Read & Write** restrito a esse bucket e com validade **Forever**. Token que expira é backup que para sem ninguém perceber.
2. **Configure** `/etc/backup-restic/backup.env` (repositório, chaves, pastas) e `/etc/backup-restic/dumps.conf` (bancos):
   ```
   sqlite    app1         /opt/app1/db.sqlite3
   mysql     erp          erp_producao
   mysql     zabbix       zabbix --ignore-table=zabbix.history --ignore-table=zabbix.trends
   postgres  site         site_producao
   ```
3. **Guarde a senha** de `/etc/backup-restic/restic-password` **fora do servidor**. Sem ela não há restauração. Se o seu cofre de senhas roda nesse mesmo servidor, guarde a senha também fora do cofre.
4. **Teste:**
   ```bash
   sudo backup-run.sh && tail -20 /var/log/backup-restic.log
   sudo backup-restore-test.sh        # "Restauração OK: N dumps conferidos."
   ```
5. **Ative os agendamentos:**
   ```bash
   sudo systemctl enable --now backup-restic.timer backup-restic-check.timer
   ```

### Alerta no Zabbix

O `install.sh` copia `zabbix/backup-restic.conf` para a pasta do agente. Reinicie o agente e, no host:

- **Item:** chave `backup.restic.age`, tipo *Zabbix agent*, intervalo de 10 minutos, unidade `s`.
- **Trigger:** `last(/SEU-HOST/backup.restic.age)>129600`, ou seja, 36 horas sem backup bem-sucedido.
- (Opcional) Faça o mesmo com `backup.restic.check.age` e o limite de 8 dias.

### Aviso pelo Telegram (opcional)

O Zabbix percebe quando o backup **para de acontecer**. O Telegram avisa **na hora** em que uma etapa falha, e de novo quando o backup volta a funcionar. Os dois se completam: se o servidor desligar, nenhum script roda para avisar, e aí só o Zabbix pega.

1. No Telegram, fale com o **@BotFather**, mande `/newbot` e copie o token.
2. Mande uma mensagem qualquer para o bot, ou adicione-o ao grupo da equipe.
3. Abra `https://api.telegram.org/bot<TOKEN>/getUpdates` e anote o `"chat":{"id":...}`. Grupos têm id negativo.
4. Preencha no `/etc/backup-restic/backup.env`:
   ```bash
   TELEGRAM_BOT_TOKEN=123456789:AAE...
   TELEGRAM_CHAT_ID=-1001234567890
   NOTIFY_ON=falha        # falha (padrão) | sempre | desligado
   ```
5. Teste: `sudo backup-notify.sh teste "funcionou"`

Um aviso de falha chega assim:

```
❌ Backup com FALHA — web01
FALHA nos dumps — backup NÃO marcado como sucesso
Veja: tail -50 /var/log/backup-restic.log
2026-10-20 06:20:14 UTC
```

**Decisões de projeto, e por quê:**

| Decisão | Motivo |
|---|---|
| Padrão `NOTIFY_ON=falha`, sem "deu tudo certo" diário | Mensagem que chega todo dia igual acostuma a pessoa a não ler o canal. Quando a falha vier, ela passa despercebida. |
| Aviso de **volta ao normal**, uma vez só | Quem recebeu a falha precisa saber que pode parar de se preocupar, sem ter que entrar no servidor. Uma marca em `/var/lib/backup-restic/backup-falhou` lembra que houve falha. |
| O token vai para o `curl` pela entrada padrão (`curl -K -`) | Na linha de comando, o token apareceria no `ps` para qualquer usuário do servidor. Se ele surgir numa mensagem de erro, é trocado por `<token>` antes de ir para o log. |
| Token e chat validados por expressão regular | Um valor com aspas ou espaço não consegue alterar a configuração passada ao `curl`. |
| Tempo máximo de 20 s e erro de envio ignorado | O Telegram fora do ar nunca pode travar nem derrubar o backup. O erro fica registrado no log. |
| Texto puro, sem Markdown | Nada na mensagem precisa ser escapado, então um nome de arquivo com `_` ou `*` não quebra o envio. |

## Restaurar

Restauração costuma acontecer com pressa: o banco corrompeu, alguém apagou uma pasta, o cliente está esperando. É a pior hora para lembrar a sintaxe do `restic restore`. Por isso o kit traz um assistente:

```bash
sudo backup-restaurar.sh
```

Ele faz três perguntas (qual snapshot, o que restaurar e para onde), mostra um resumo e só restaura depois do "s":

```
O que restaurar do snapshot 3f9a1c2e?
   1) Um dump de banco de dados (de /var/backups/restic-dumps)
   2) Um arquivo ou uma pasta
   3) O snapshot inteiro
Número [1]: 1
Qual dump?
   1) mysql-erp.sql.gz
   2) sqlite-app1.sqlite3
Número [1]: 2
Pasta de destino [/var/tmp/restaurado-3f9a1c2e-20261023-091512]:

Resumo:
  snapshot  3f9a1c2e
  restaurar o dump sqlite-app1.sqlite3
  destino   /var/tmp/restaurado-3f9a1c2e-20261023-091512  (os originais não são tocados)
Restaurar agora? (s/N): s

Restaurado: 1 arquivo(s) em /var/tmp/restaurado-3f9a1c2e-20261023-091512
Conferindo os dumps restaurados:
  ok     sqlite-app1.sqlite3

Como colocar sqlite-app1.sqlite3 no lugar:
  1. Pare o aplicativo que usa o banco.
  2. Guarde o atual:   mv '/opt/app1/db.sqlite3' '/opt/app1/db.sqlite3.antes-da-restauracao'
     Se existirem '/opt/app1/db.sqlite3-wal' e '/opt/app1/db.sqlite3-shm', mova-os também:
     um WAL antigo aplicado sobre o banco restaurado o corrompe.
  3. Coloque o antigo: cp '/var/tmp/restaurado-.../var/backups/restic-dumps/sqlite-app1.sqlite3' '/opt/app1/db.sqlite3'
  4. Suba o aplicativo e confira.
```

Para MySQL e PostgreSQL, o comando sugerido primeiro restaura num banco **novo** (`erp_producao_restaurado`), para conferir antes de substituir o de produção. Para arquivos e pastas, sugere `diff` e `rsync --dry-run`.

Cada pergunta pode ser pulada com uma opção, o que serve para documentação de procedimento e automação:

```bash
sudo backup-restaurar.sh --listar                                  # snapshots disponíveis
sudo backup-restaurar.sh -s latest -d sqlite-app1.sqlite3 -y       # um dump, sem perguntas
sudo backup-restaurar.sh -s 3f9a1c2e -c /etc/nginx -D /root/nginx-antigo
sudo backup-restaurar.sh -t -y                                     # snapshot inteiro, destino padrão
```

| Opção | O que faz |
|---|---|
| `-s`, `--snapshot ID` | snapshot (`latest` = o mais recente; os 8 primeiros caracteres do ID bastam) |
| `-d`, `--dump ARQUIVO` | só esse dump de `DUMP_DIR` |
| `-c`, `--caminho CAMINHO` | só esse arquivo ou pasta (caminho original, absoluto) |
| `-t`, `--tudo` | o snapshot inteiro |
| `-D`, `--destino PASTA` | destino vazio ou inexistente (padrão: `/var/tmp/restaurado-<snapshot>-<data>`, mude com `RESTAURAR_EM` no `backup.env`) |
| `-y`, `--sim` | sem confirmação; aceita o snapshot mais recente e o destino padrão |

Códigos de saída: `0` ok, `1` falha na restauração ou dump com problema, `2` uso ou configuração inválida, `4` cancelado.

**Decisões de projeto, e por quê:**

| Decisão | Motivo |
|---|---|
| Nunca restaura por cima do original | O restic grava em `<destino>/<caminho original>`. Com destino `/`, ele sobrescreveria o servidor ao vivo. O assistente recusa `/` e deixa a troca para o administrador, que sabe se o app está parado. |
| O destino precisa estar vazio | Restaurar numa pasta com arquivos mistura o antigo com o que já estava lá, e ninguém sabe mais o que veio do backup. |
| Pasta de destino com permissão 700 | Um dump tem todos os dados do sistema. Em `/var/tmp`, sem isso, qualquer usuário do servidor poderia ler. |
| Confere o dump depois de restaurar | Um dump corrompido descoberto **depois** de substituir o banco de produção é um segundo incidente. O assistente usa a mesma conferência do `backup-restore-test.sh`. |
| Banco novo antes do de produção | `zcat dump \| mysql banco` apaga as tabelas atuais. Restaurar primeiro em `banco_restaurado` permite comparar e escolher. |
| O ID do snapshot só aceita `latest` ou hexadecimal | Um texto como `--help` não chega ao restic como se fosse uma opção. |
| Pergunta sem resposta encerra com erro | Rodando por pipe ou cron, o script nunca segue com um valor que ninguém escolheu. |
| Cada restauração vai para o log | Fica registrado quem restaurou o quê, de qual snapshot e para onde. |

Se preferir o restic direto:

```bash
set -a; . /etc/backup-restic/backup.env; set +a
restic snapshots
restic restore latest --target /tmp/restaurado --include /opt/app1
```

## Testes

[`tests/test.sh`](tests/test.sh) roda o ciclo inteiro contra um repositório restic local e verifica:

- a instalação;
- os dumps e o primeiro backup;
- a **restauração real**;
- a verificação do repositório;
- a retenção;
- que **banco ausente ou corrompido não vira sucesso**, sem apagar o dump bom anterior;
- a trava contra execução dupla;
- os itens do Zabbix;
- a **restauração assistida**: modo interativo com respostas pela entrada padrão, as opções `--dump`, `--caminho` e `--tudo`, as proteções do destino e do snapshot, e um dump corrompido detectado depois de restaurar;
- o **aviso pelo Telegram**, contra um servidor falso local ([`tests/telegram_falso.py`](tests/telegram_falso.py)): falha, volta ao normal, `NOTIFY_ON`, Telegram fora do ar e o token fora do log.

O GitHub Actions roda os testes e o ShellCheck a cada push.

```bash
./tests/test.sh
```

## Autor

**Euller Pinheiro**, Diretor Técnico da [ESX Tecnologia](https://esxtecnologia.com). A ESX cuida de TI gerenciada, infraestrutura e desenvolvimento em São Paulo.

Quer backup monitorado nos servidores da sua empresa sem ter que pensar nisso? [Fale com a ESX](https://esxtecnologia.com).

---

<a name="english"></a>
## English

A backup kit for Linux servers. It takes consistent database dumps (SQLite `.backup` with an integrity check, `mysqldump --single-transaction`, `pg_dump -Fc`), runs an encrypted [restic](https://restic.net) backup to **Cloudflare R2** (or any restic backend), applies retention, verifies the repository weekly and exposes **Zabbix** items, so you get an alert when backups stop.

Optional **Telegram** alerts are sent when any step fails and once when backups recover (`NOTIFY_ON=falha|sempre|desligado`). The bot token is passed to `curl` through stdin, so it never shows up in `ps`, and a Telegram outage never breaks the backup.

A failed dump never overwrites the last good one, and never counts as success. `backup-restore-test.sh` proves that your backup actually restores, and `backup-restaurar.sh` is an interactive restore wizard (snapshot, what, where) that always restores into a separate, empty, root-only folder, checks the restored dumps and prints the exact commands to put them back (testing in a new database first). Fully tested in CI against a local repository.

Licensed under [MIT](LICENSE).

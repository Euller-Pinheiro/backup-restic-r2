# Backup restic + Cloudflare R2

[![Testes](https://github.com/Euller-Pinheiro/backup-restic-r2/actions/workflows/testes.yml/badge.svg)](https://github.com/Euller-Pinheiro/backup-restic-r2/actions/workflows/testes.yml)
![Bash](https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=white)
![restic](https://img.shields.io/badge/restic-0.16%2B-blue)
![Licença MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-green)

**[English below](#english)**

Kit de backup para servidores Linux. Exporta os bancos de dados de forma consistente, cifra tudo com o [restic](https://restic.net), guarda no **Cloudflare R2** (ou em qualquer S3, B2, SFTP ou disco local), aplica retenção, verifica o repositório toda semana e **avisa no Zabbix** quando o backup para.

É a versão aberta do que eu uso em produção nos servidores da [ESX Tecnologia](https://esxtecnologia.com). O kit protege ERP, cofre de senhas, helpdesk e sites, e cada servidor ocupa uma fração dos 10 GB gratuitos do R2.

## Por que assim

| Problema comum | O que o kit faz |
|---|---|
| Copiar o arquivo do banco com o app rodando gera cópia corrompida | SQLite via `.backup` seguido de `PRAGMA integrity_check`. MySQL/MariaDB via `mysqldump --single-transaction`. PostgreSQL via `pg_dump -Fc`. |
| Um dump falha e substitui o bom de ontem | Cada dump é escrito num arquivo temporário e só substitui o anterior se passar na verificação. |
| O backup para de rodar e ninguém percebe | Uma marca de sucesso só é gravada se **todas** as etapas derem certo. O Zabbix lê a idade dela e alerta. |
| Backup que nunca foi restaurado | `backup-restore-test.sh` restaura os dumps do último snapshot e confere cada um. |
| Servidor invadido apaga o próprio backup | Recomendação: um bucket e um token por servidor, com escopo só naquele bucket. |
| O armazenamento corrompe em silêncio | Verificação semanal com `restic check --read-data-subset=10%`, sobre uma amostra diferente a cada vez. |
| O servidor roda em UTC e o horário "03:00" vira meia-noite | Os timers do systemd usam o sufixo `UTC` explícito. |
| Dois backups ao mesmo tempo | Trava com `flock`. A segunda execução sai sem fazer nada. |

## O que vem no kit

```
bin/backup-dumps.sh          dumps consistentes (sqlite, mysql, postgres)
bin/backup-run.sh            ciclo: dumps -> restic backup -> retenção -> marca de sucesso
bin/backup-check.sh          verificação do repositório
bin/backup-restore-test.sh   restaura e confere os dumps do último snapshot
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

## Restaurar

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
- os itens do Zabbix.

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

A failed dump never overwrites the last good one, and never counts as success. `backup-restore-test.sh` proves that your backup actually restores. Fully tested in CI against a local repository.

Licensed under [MIT](LICENSE).

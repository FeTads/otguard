# OTGuard

**Filtro de pacotes, monitor de tráfego e alerta de ataque** para servidores Tibia / Open Tibia. Auto-instalável em Ubuntu/Debian.

---

## ⚠️ Importante: o que isto **NÃO** é

**OTGuard NÃO é um anti-DDoS de verdade.** Anti-DDoS sério mora em *scrubbing centers* com **terabits** de capacidade (Cloudflare Magic Transit, OVH VAC, NEEP/ShieldM, Hetzner DDoS Protection). Você **não consegue** rodar anti-DDoS dentro de uma VPS de 1 Gbps — quando o ataque é maior que a sua banda, o link satura na borda do datacenter e o OTGuard nem chega a ver o pacote.

O OTGuard faz **o outro pedaço do trabalho** — aquele que o scrubbing upstream não cobre ou que ele te delega:

| ✅ O OTGuard FAZ | ❌ O OTGuard NÃO faz |
|---|---|
| Descarta tráfego inútil (UDP nas portas TCP-only, pacotes malformados, SYN-flood dentro da capacidade do link) | Defender contra ataque volumétrico (≥ sua banda) |
| Limita conexões por IP de origem e por porta (hashlimit) | Substituir Cloudflare / OVH VAC / NEEP / Hetzner |
| Detecta ataque em andamento (pps, conntrack, SYN-RECV) e captura `.pcap` + relatório técnico | Mágica genérica contra qualquer DDoS |
| Alerta no Discord com mensagem pronta pra colar no chamado do provedor | Operar a partir da nuvem (é tudo local na VPS) |
| Painel ao vivo no terminal mostrando o que está acontecendo agora | |
| Blocklist persistente, sobrevive reboot (`otguard ban <ip>`) | |
| Esconder o IP real do servidor (libera 80/443 só pra Cloudflare) | |

### Regra prática

Se sua VPS tem **1 Gbps** e o ataque é de **5 Gbps**, o tráfego nem chega na VPS — ele já saturou o uplink **antes** do seu firewall. Pra isso você precisa de scrubbing **upstream do seu IP**.

**Onde o OTGuard ajuda de verdade:**

- Ataques **dentro da sua banda** (script-kiddies de 50–500 Mbps que uma VPS aguenta se o tráfego for filtrado cedo)
- Floods de **SYN/UDP** nas portas do jogo (lixo que infla conntrack e derruba CPU mesmo sem encher banda)
- Te dar **visibilidade** ("você ESTÁ sendo atacado, é de SYN-flood, vem desses 12 IPs, aqui está o pcap")
- Te dar a **mensagem pronta** pra abrir chamado no suporte do provedor (NEEP, OVH, Hetzner, etc.)
- Te dar uma **blocklist** que sobrevive reboot pra bloquear bots persistentes
- Te poupar CPU/RAM filtrando o lixo o mais cedo possível (`iptables raw + ipset`) — seu jogo continua jogável durante ataques pequenos

**Em uma frase:** OTGuard faz uns 50% do trabalho de mitigação — o pedaço que cabe dentro da sua VPS. O resto (volumétrico, terabits) tem que vir do upstream.

---

## Instalação (uma linha)

Na VPS que roda o servidor de OT (Ubuntu 20.04+ / Debian 11+, com `apt`):

```bash
curl -fsSL https://github.com/FeTads/otguard/releases/latest/download/install.sh | sudo sh
```

Quando terminar:

```bash
sudo otguard
```

O assistente abre uma tela azul tipo instalador do Ubuntu — 8 perguntas rápidas com sugestões prontas em cada tela. Depois disso o OTGuard inicializa sozinho a cada boot.

### Como funciona a verificação de integridade

A URL acima aponta para o `install.sh` que **vai junto com a última release**. Esse `install.sh` é gerado pelo GitHub Actions e traz **duas camadas de verificação**:

1. **Assinatura GPG** (`.deb.sig`) — chave pública fingerprint `C357 5800 8A4D EB52 EC99  6C78 5A7E 6EAD E40B B4A0` (gravada dentro do próprio `install.sh`). Mesmo se a conta GitHub for comprometida, sem a chave privada o atacante **não consegue assinar** um `.deb` falso — o `install.sh` aborta.
2. **SHA256 do `.deb`** — gravado dentro do próprio `install.sh`. Defesa redundante caso a primeira camada não esteja disponível (releases antigas, p.ex.).

Você pode verificar manualmente:

```bash
gpg --import otguard-public.gpg
gpg --verify otguard_<ver>_all.deb.sig otguard_<ver>_all.deb
sha256sum -c otguard_<ver>_all.deb.sha256
```

A chave pública mora em [`otguard-public.gpg`](otguard-public.gpg) na raiz do repo.

### URL alternativa (bootstrap, do main branch)

Se você quiser instalar antes de qualquer release existir, dá pra usar:

```bash
curl -fsSL https://raw.githubusercontent.com/FeTads/otguard/main/install.sh | sudo sh
```

Esse modo cai num caminho "bootstrap": consulta a API do GitHub pela última release, baixa o `.deb.sha256` separadamente e confere. Requer `jq` (instalado automaticamente). É o fallback.

## Comandos

| Comando | Faz |
|---|---|
| `sudo otguard` | menu + status atual |
| `sudo otguard mon` | painel ao vivo (pps, conntrack, SYN/s, half-open) |
| `sudo otguard status` | resumo dos serviços + contadores |
| `sudo otguard ban <ip>` | bloqueia IP nas portas do jogo (permanente, sobrevive reboot) |
| `sudo otguard unban <ip>` | libera IP |
| `sudo otguard banlist` | lista os IPs bloqueados |
| `sudo otguard test` | envia mensagem de teste ao Discord |
| `sudo otguard reconfig` | refaz o wizard |
| `sudo otguard uninstall` | remove tudo |
| `sudo otguard help` | ajuda completa |

## O que ele liga no sistema

Tudo via `systemd`, levantado no boot:

- **`otguard-mitigacao.service`** — escreve as regras `iptables raw` + `ipset` + RPS na inicialização
- **`otguard-watch.service`** — vigia pps/conntrack/SYN. Quando dispara, captura `.pcap` (até 100k pacotes / 120s) + relatório + alerta no Discord
- **`otguard-live.service`** — coleta 1 amostra/s pro painel ao vivo
- **`otguard-cfupdate.timer`** — semanal, atualiza ranges da Cloudflare (só se filtro 80/443 ligado)

Logs em `/var/log/otguard/`. Config em `/etc/otguard/otguard.conf`. Blocklist persistente em `/etc/otguard/blocklist.ipset`.

## Requisitos

- Ubuntu 20.04+ ou Debian 11+ (qualquer distro com `apt` + `systemd`)
- root / sudo
- Interface de rede normal (eth0 / ens3 / etc.)

Dependências (instaladas automaticamente pelo `.deb`):
`iptables`, `ipset`, `tcpdump`, `curl`, `gawk`, `whiptail`, `systemd`

## Pra mantenedores: empacotamento

O script é **auto-empacotável** — não tem árvore Debian, control files, nada. Basta:

```bash
sh otguard.sh --build-deb 1.1     # gera otguard_1.1_all.deb na pasta atual
```

O `.github/workflows/release.yml` faz isso sozinho quando você empurra uma tag `v*`:

```bash
git commit -am "release v1.1"
git tag v1.1
git push origin main v1.1
# o Actions builda o .deb e cria a Release automaticamente
```

## OTGuard Shadow (auto-ban via auth.log)

A partir de 1.7 o OTGuard inclui um daemon `otguard-shadow` que detecta padrões de attack via login de personagem. Ele depende de UM hook Lua no seu TFS (não vem instalado por default porque o caminho depende do seu server).

### Hook do TFS — adicione ao final do seu `onLogin(cid)` em `data/creaturescripts/scripts/login.lua` (antes do `return true`):

```lua
-- otguard-shadow: log persistente de cada login autenticado.
-- Tab-separated. Campos: ts ip nome accid level voc os
pcall(function()
    local f = io.open("/var/log/otguard/auth.log", "a")
    if f then
        f:write(string.format("%d\t%s\t%s\t%d\t%d\t%d\t%d\n",
            os.time(),
            doConvertIntegerToIp(getPlayerIp(cid)),
            getPlayerName(cid),
            getPlayerAccountId(cid),
            getPlayerLevel(cid),
            getPlayerVocation(cid),
            getPlayerOperatingSystem(cid)))
        f:close()
    end
end)
```

Depois faça `/reload creaturescripts` no chat do jogo (god/admin). Sem o hook, o `auth.log` fica vazio e o daemon shadow não tem como detectar nada.

### Como funciona

| componente | o que faz |
|---|---|
| **hook login.lua** | a cada login real escreve `timestamp IP char accid level voc os` em `/var/log/otguard/auth.log` |
| **otguard-shadow** (daemon) | a cada 60s analisa últimos 1h e bana automaticamente: char com 5+ IPs distintos (lvl<50) ou IP com 5+ chars lvl≤20 (com safety: skip se IP tem main lvl≥50 na janela, ou se algum account tem main lvl≥100 no DB) |
| **otguard-auth-check** | script CLI: `otguard-auth-check 3600` mostra cobertura auth/conn + distribuição de level + padrões A/B |
| **`otguard mon` [5]** | painel inline do auth-check (janela 2h) |
| **`otguard mon` [6]** | sweep manual 24h: lista candidatos, pede confirmação, bana em massa + alerta Discord agregado |

Tunable via `/etc/otguard/otguard.conf` (chaves `SHADOW_*`). Os defaults são conservadores (5 IPs/char, 5 chars/IP, ban 24h).

## Self-service unban (assimetria contra atacante)

A partir de 1.7 o OTGuard inclui `otguard-unban` — daemon que processa pedidos de desban feitos pelo jogador no site (via `accountmanagement.php`). A ideia:

- Jogador legit toma ban injusto durante ataque → loga no site (auth da conta dele) → vê os IPs dele → clica "Solicitar desban" → daemon processa em até 30s
- Atacante NÃO escala: pra desbanir N IPs do botnet, precisaria logar uma conta válida pra cada IP, abrir o accountmanagement, pedir o desban — friction enorme

A tabela `otguard_unban_requests` é criada automaticamente no apply se o TFS for detectado em `/home/otserv/*/config.lua` (ou aponte com `OTG_TFS_CONFIG` no conf).

### Hook no PHP (myaac)

Adicione ao seu `pages/accountmanagement.php`, logo antes do bloco `//########### CHANGE PASSWORD ##########`:

```php
//########### OTGUARD: SELF-SERVICE UNBAN ##########
if($action == "unbanip")
{
    $accId = (int)$account_logged->getId();
    $accName = $account_logged->getName();
    $remoteIp = $_SERVER['REMOTE_ADDR'] ?? '';
    $db = Website::getDBHandle();

    // Coleta IPs historicos da conta (lastip de cada char + IP atual da sessao)
    $ips = [];
    if(filter_var($remoteIp, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        $ips[$remoteIp] = 'IP atual (sessão web)';
    }
    try {
        $r = $db->query("SELECT name, INET_NTOA(lastip) AS ip FROM players WHERE account_id = $accId AND lastip > 0");
        while($row = $r->fetch()) {
            if($row['ip'] && !isset($ips[$row['ip']])) {
                $ips[$row['ip']] = 'último login de ' . htmlspecialchars($row['name']);
            }
        }
    } catch(Exception $e) {}

    // Le blocklist do otguard
    $bl = [];
    if(is_readable('/etc/otguard/blocklist.ipset')) {
        foreach(file('/etc/otguard/blocklist.ipset') as $line) {
            if(preg_match('/^add\s+otguard_bl\s+(\S+)/', $line, $m)) $bl[$m[1]] = true;
        }
    }

    // POST: solicita desban
    $msg = '';
    if(isset($_POST['unban_ip'])) {
        $reqIp = trim($_POST['unban_ip']);
        if(!filter_var($reqIp, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) $msg = '<font color=red>IP inválido.</font>';
        elseif(!isset($ips[$reqIp])) $msg = '<font color=red>IP não pertence à sua conta.</font>';
        elseif(!isset($bl[$reqIp])) $msg = '<font color=orange>IP não está banido.</font>';
        else {
            $now = time();
            $rl = $db->query("SELECT COUNT(*) AS n FROM otguard_unban_requests WHERE account_id=$accId AND requested_at > ".($now-3600))->fetch();
            if(($rl['n'] ?? 0) >= 1) $msg = '<font color=red>Você já fez um pedido na última hora.</font>';
            else {
                $db->query("INSERT INTO otguard_unban_requests (account_id, account_name, ip, remote_ip, requested_at, status) VALUES ($accId, ".$db->quote($accName).", ".$db->quote($reqIp).", ".$db->quote($remoteIp).", $now, 'pending')");
                $msg = '<font color=green>Pedido enviado. Processado em até 30s.</font>';
            }
        }
    }

    // Renderiza tabela com IPs + botão
    $rows = '';
    foreach($ips as $ip => $origem) {
        $ipEsc = htmlspecialchars($ip);
        if(isset($bl[$ip])) {
            $rows .= '<tr><td>'.$ipEsc.'</td><td>'.htmlspecialchars($origem).'</td><td><font color=red><b>BANIDO</b></font></td><td><form method=post action="?subtopic=accountmanagement&action=unbanip" style=margin:0><input type=hidden name=unban_ip value="'.$ipEsc.'"><input type=submit value="Solicitar desban" onclick="return confirm(\'Confirma desban?\')"></form></td></tr>';
        } else {
            $rows .= '<tr><td>'.$ipEsc.'</td><td>'.htmlspecialchars($origem).'</td><td><font color=green>OK</font></td><td>—</td></tr>';
        }
    }

    $main_content .= '<div class="TableContainer"><table class="Table1"><tr><td><div class="InnerTableContainer">'
        .($msg ? '<p style=text-align:center>'.$msg.'</p>' : '')
        .'<p>Limite: 1 pedido por hora, 5 por dia.</p>'
        .'<table style=width:100% border=1 cellpadding=4><tr><th>IP</th><th>Origem</th><th>Status</th><th>Ação</th></tr>'.$rows.'</table>'
        .'</div></td></tr></table></div>';
}
```

E opcionalmente adicione um link na action `"manage"` (logo após o fechamento `</tr><br/>';`):

```php
$main_content .= '<p style="text-align:center;padding:10px"><a href="?subtopic=accountmanagement&action=unbanip" style="color:#cc0000;font-weight:bold">⚠️ Gerenciar IPs banidos (OTGuard)</a></p>';
```

### Configuração (em `/etc/otguard/otguard.conf`)

```
UNBAN_INTERVAL=30          # poll a cada 30s
UNBAN_MAX_PER_HOUR=1       # max desbans por account por hora
UNBAN_MAX_PER_DAY=5        # max desbans por account por dia
```

### Como o ban é decidido vs desbanido

| ação | quem decide |
|---|---|
| **ban automático** | otguard (slowread/shadow): thresholds em tempo real |
| **ban manual** | admin via `otguard ban <ip>` ou `[6]` sweep |
| **unban automático** | jogador no site → daemon valida + executa |
| **unban manual** | admin via `otguard unban <ip>` ou `[u]` no mon |

## Estrutura do repo

```
otguard/
├── otguard.sh                       # o instalador auto-extraivel (~33 KB)
├── install.sh                       # one-liner que baixa o .deb da release
├── README.md                        # este arquivo
├── LICENSE                          # MIT
└── .github/workflows/release.yml    # CI: builda .deb em cada tag v*
```

## Licença

MIT. Veja `LICENSE`.

---

> **Disclaimer honesto:** se você está sob ataque volumétrico ativo (>= a sua banda), nenhuma ferramenta local te salva. Abra chamado no seu provedor **agora**, peça scrubbing L4 always-on, e considere migrar pra um host com proteção upstream incluída. O OTGuard te ajuda a **provar o ataque** (com pcap + relatório) e a **lidar com o que sobra** quando o scrubbing já está mitigando o resto. Não é magia.

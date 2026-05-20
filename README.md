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

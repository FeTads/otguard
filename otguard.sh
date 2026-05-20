#!/bin/sh
# ==========================================================================
#  OTGuard 1.0  —  filtro de pacotes + monitor de trafego + alerta de ataque
#                   para servidores Tibia / OTServ.  NAO substitui scrubbing
#                   upstream (Cloudflare/OVH VAC/NEEP); faz a parte local do
#                   trabalho: descarta lixo, limita flood dentro da banda,
#                   captura evidencia e alerta no Discord.
#  Instalador self-contained.  Todos os componentes vivem dentro deste arquivo.
#
#  Primeira vez:        sudo sh otguard.sh
#  Depois, em qualquer pasta, basta digitar:
#
#    otguard                 menu de comandos + status
#    otguard mon             painel ao vivo (alias de otguard-mon)
#    otguard status          estado dos servicos
#    otguard ban <ip>        bloqueia IP nas portas do jogo (sobrevive reboot)
#    otguard unban <ip>      libera um IP
#    otguard banlist         lista os IPs bloqueados
#    otguard test            envia mensagem de teste ao Discord
#    otguard reconfig        roda o assistente de novo
#    otguard uninstall       remove tudo
#    otguard --selftest      valida o pacote sem instalar nada
#
#  Empacotamento (para mantenedores):
#    sh otguard.sh --build-deb [versao]    gera otguard_<ver>_all.deb
#
#  Dica: digite "ot" e TAB para autocompletar (otguard / otguard-mon).
# ==========================================================================
OTG_VER=1.0
CONF_DIR=/etc/otguard
CONF=$CONF_DIR/otguard.conf
LOGDIR=/var/log/otguard

if [ -t 1 ]; then
  CT='\033[1;36m'; CO='\033[1;32m'; CW='\033[1;33m'; CE='\033[1;31m'; CD='\033[2m'; CR='\033[0m'
else CT=''; CO=''; CW=''; CE=''; CD=''; CR=''; fi
say()  { printf '%b\n' "$*"; }
ok()   { printf '%b\n' "${CO}  ✓${CR} $*"; }
warn() { printf '%b\n' "${CW}  !${CR} $*"; }
err()  { printf '%b\n' "${CE}  ✗${CR} $*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%b\n' "${CD}  ----------------------------------------------------------${CR}"; }
ask()  { # ask "texto" "default" -> ANS
  if [ "${WZ:-}" ]; then WZ_I=$(( WZ_I + 1 )); _sp="${CD}[$WZ_I/$WZ_N]${CR} "; else _sp=''; fi
  printf '%b\n' "  ${_sp}${CT}$1${CR}" >&2
  if [ -n "$2" ]; then
    printf '%b' "        ${CO}» ENTER${CR} ${CD}usa${CR} ${CO}$2${CR}${CD}   ·   ou digite outro valor e ENTER:${CR} " >&2
  else
    printf '%b' "        ${CO}» ENTER${CR} ${CD}pula   ·   ou digite e ENTER:${CR} " >&2
  fi
  read -r ANS 2>/dev/null || ANS=''
  [ -z "$ANS" ] && ANS=$2
}

# spin "mensagem" comando...  — roda o comando com spinner + cronometro
# (sem % falso: pra apt/needrestart nao da pra saber o total; mostra que esta vivo)
spin() {
  _m=$1; shift
  if [ ! -t 1 ]; then say "  $_m ..."; "$@"; return $?; fi
  _lg=$(mktemp 2>/dev/null || echo "/tmp/otg.$$")
  "$@" </dev/null >"$_lg" 2>&1 &
  _p=$!; _s=0
  printf '\033[?25l'
  while kill -0 "$_p" 2>/dev/null; do
    case $(( _s % 4 )) in 0) _c='|';; 1) _c='/';; 2) _c='-';; *) _c='\';; esac
    printf '\r  %b%s%b %s  %02d:%02d\033[K' "$CT" "$_c" "$CR" "$_m" $(( _s / 60 )) $(( _s % 60 ))
    sleep 1; _s=$(( _s + 1 ))
  done
  wait "$_p" 2>/dev/null; _rc=$?
  printf '\r\033[K\033[?25h'
  if [ "$_rc" = 0 ]; then ok "$_m  (${_s}s)"
  else err "$_m — FALHOU:"; tail -n 12 "$_lg" 2>/dev/null >&2; fi
  rm -f "$_lg"
  return "$_rc"
}

# --------------------------------------------------------------------------
preflight() {
  [ "$(id -u)" = 0 ] || die "rode como root:  sudo sh otguard.sh"
  command -v systemctl >/dev/null 2>&1 || die "OTGuard precisa de systemd."
  command -v iptables  >/dev/null 2>&1 || die "OTGuard precisa de iptables."
  miss=''
  for c in ipset tcpdump curl awk whiptail; do
    command -v "$c" >/dev/null 2>&1 || miss="$miss $c"
  done
  if [ -n "$miss" ]; then
    warn "faltam dependencias:$miss"
    if command -v apt-get >/dev/null 2>&1; then
      ask "instalar agora via apt?" "s"
      case $ANS in
        s|S|y|Y)
          say "  ${CD}pode levar 1-2 min — o Ubuntu faz uma verificacao pos-instalacao; e normal. NAO cancele.${CR}"
          spin "instalando dependencias" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a sh -c "apt-get update -qq && apt-get install -y$miss" \
            || die "falha ao instalar dependencias (veja o erro acima)" ;;
        *) die "instale:$miss e rode de novo" ;;
      esac
    else die "instale manualmente:$miss"; fi
  fi
}

# --------------------------------------------------------------------------
provider_info() {  # $1 = escolha 1..5  -> define PROV_KEY/PROV_NAME/SCRUB/PROV_ASK
  case $1 in
    1) PROV_KEY=neep;    PROV_NAME="NEEP / ShieldM";   SCRUB="ShieldM"
       PROV_ASK="Peca a NEEP scrubbing L4 always-on na porta do jogo, anti-spoofing (uRPF/bogons) e validacao de handshake (SYN-proxy)." ;;
    2) PROV_KEY=ovh;     PROV_NAME="OVH";              SCRUB="VAC (anti-DDoS da OVH)"
       PROV_ASK="O VAC da OVH e always-on. Se o ataque passou, abra ticket pedindo mitigacao permanente no IP e regras no Edge Network Firewall." ;;
    3) PROV_KEY=hetzner; PROV_NAME="Hetzner";          SCRUB="Hetzner DDoS Protection"
       PROV_ASK="A protecao da Hetzner e automatica. Se o ataque passou, abra ticket anexando o pcap e peca ajuste do filtro." ;;
    4) PROV_KEY=outro;   PROV_NAME="provedor";         SCRUB="a protecao do provedor"
       PROV_ASK="Envie o pcap e o relatorio ao suporte do provedor e pergunte se ha scrubbing L4 disponivel para o seu IP." ;;
    *) PROV_KEY=nenhum;  PROV_NAME="provedor";         SCRUB="(sem scrubbing no upstream)"
       PROV_ASK="ATENCAO: seu provedor nao tem scrubbing L4. A mitigacao local NAO impede saturacao de banda/CPU. Considere contratar protecao ou migrar de host." ;;
  esac
}

# --------------------------------------------------------------------------

# wrappers do whiptail — saem com clean-exit se o usuario apertar Cancelar/ESC
WT_BACK="OTGuard $OTG_VER  ·  filtro de pacotes + monitor para Tibia / OT"
wt_cancel() { clear; say "  ${CW}instalacao cancelada pelo usuario.${CR}"; exit 1; }
wt_input()  { # wt_input "titulo" "label" "default" -> ANS
  ANS=$(whiptail --backtitle "$WT_BACK" --title "$1" \
        --inputbox "$2" 12 70 "$3" 3>&1 1>&2 2>&3) || wt_cancel
}
wt_yesno()  { # wt_yesno "titulo" "texto" "default(s|n)" -> 0=sim 1=nao (nunca cancela)
  if [ "${3:-s}" = n ]; then df=--defaultno; else df=''; fi
  whiptail --backtitle "$WT_BACK" --title "$1" $df --yesno "$2" 14 70
}
wt_msg()    { whiptail --backtitle "$WT_BACK" --title "$1" --msgbox "$2" 14 70 || wt_cancel; }

wizard() {
  [ -t 0 ] || die "o assistente e interativo — rode a partir do arquivo (sh otguard.sh), nao por pipe."
  command -v whiptail >/dev/null 2>&1 || die "whiptail nao instalado.  Rode:  sudo apt install whiptail"

  defif=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  sship=$(printf '%s' "${SSH_CLIENT:-}" | awk '{print $1}')

  # boas-vindas
  wt_msg "OTGuard $OTG_VER  ·  Instalador" \
"Bem-vindo!

O OTGuard faz a parte LOCAL da defesa: descarta lixo
de pacotes, limita flood dentro da sua banda, captura
evidencia (pcap) e alerta no Discord.

ELE NAO SUBSTITUI scrubbing upstream (Cloudflare,
OVH VAC, NEEP/ShieldM, Hetzner DDoS Protection).
Ataque maior que sua banda satura na borda do datacenter
antes de chegar aqui — isso so se resolve la fora.

Vou te fazer 8 perguntas rapidas. Use:
  TAB / setas / SPACE / ENTER  para navegar.
A resposta sugerida ja vem preenchida em cada tela."

  # 1) Interface de rede (radio com TODAS as interfaces detectadas)
  iflist=$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /^(lo|docker|veth|br-|virbr)/{print $2}' | cut -d@ -f1)
  set --
  for i in $iflist; do
    if [ "$i" = "$defif" ]; then set -- "$@" "$i" "$i (detectada automaticamente)" on
    else                        set -- "$@" "$i" "$i" off
    fi
  done
  [ "$#" = 0 ] && set -- eth0 "eth0 (padrao)" on
  W_IFACE=$(whiptail --backtitle "$WT_BACK" --title "1/8  Interface de rede" \
    --radiolist "Em qual placa de rede o servidor de OT escuta?\n\n(o OTGuard ja detectou a default da sua VM)" \
    16 70 6 "$@" 3>&1 1>&2 2>&3) || wt_cancel

  # 2) Porta de login
  wt_input "2/8  Porta de login do OT" \
    "Porta de LOGIN do servidor (padrao do Tibia/OT: 7171):" "7171"
  W_PL=$ANS

  # 3) Porta de jogo
  wt_input "3/8  Porta de jogo do OT" \
    "Porta de JOGO do servidor (padrao do Tibia/OT: 7172):" "7172"
  W_PG=$ANS

  # 4) Admin IPs
  wt_input "4/8  Acesso de administrador" \
"IP(s) com acesso livre as portas do jogo (e ao site quando o filtro CF estiver ligado).
Separe com espaco se forem varios.

IP dinamico ou CGNAT?  Deixe vazio e acesse o phpmyadmin pelo dominio
(passa pela Cloudflare).  O SSH nunca e tocado em todo caso." \
    "$sship"
  W_ADM=$ANS

  # 5) Provedor
  W_PROV=$(whiptail --backtitle "$WT_BACK" --title "5/8  Provedor de hospedagem" \
    --radiolist "Onde o servidor esta hospedado?\n\n(o OTGuard usa isso pra te dizer o que pedir ao suporte do provedor quando levar um ataque)" \
    18 70 5 \
    1 "NEEP / ShieldM"              on  \
    2 "OVH (VAC)"                   off \
    3 "Hetzner"                     off \
    4 "Outro provedor"              off \
    5 "VPS sem protecao anti-DDoS"  off \
    3>&1 1>&2 2>&3) || wt_cancel

  # 6) Discord
  wt_input "6/8  Alertas no Discord  (opcional)" \
"Cole a URL do webhook do Discord para receber alerta quando um ataque chegar.

Deixe vazio se nao quiser usar." ""
  W_HOOK=$ANS

  # 7) Cloudflare
  if wt_yesno "7/8  Protecao do site (Cloudflare)" \
"Seu site (portas 80/443) fica atras da Cloudflare NESTA mesma VM?

SIM  →  o OTGuard libera 80/443 so para a Cloudflare e bloqueia o resto.
        Esconde o IP real do servidor; admin com IP fixo passa direto.

NAO  →  o OTGuard nao toca em 80/443.

ATENCAO: marque SIM apenas se o site usa Cloudflare DE VERDADE.
Senao ele sai do ar." "n"; then W_CF=sim; else W_CF=nao; fi

  # 8) Pico de players
  wt_input "8/8  Tamanho do servidor" \
"Pico estimado de players online (serve so para calibrar os limites anti-flood):" \
    "500"
  W_PEAK=$ANS
  case $W_PEAK in *[!0-9]*|'') W_PEAK=500 ;; esac

  provider_info "$W_PROV"

  # confirmacao final
  whiptail --backtitle "$WT_BACK" --title "Confirmar instalacao" \
    --yesno "Resumo das suas escolhas:

  Interface:    $W_IFACE
  Porta login:  $W_PL
  Porta jogo:   $W_PG
  Admin:        ${W_ADM:-(nenhum)}
  Provedor:     $PROV_NAME
  Discord:      $([ -n "$W_HOOK" ] && echo \"configurado\" || echo \"nao configurado\")
  Cloudflare:   $W_CF
  Pico players: $W_PEAK

Confirmar e instalar?" 20 70 || wt_cancel
}

# --------------------------------------------------------------------------
write_config() {
  mkdir -p "$CONF_DIR"
  # calibragem: assume ~50 pkt/s por player (Tibia PvP/PvM ativo).
  # Validado em campo: server de 630 players ~25k pps reais; players*50 ~= 31500.
  norm=$(( W_PEAK * 50 ))                       # trafego "normal de pico" estimado
  # WARNING: 2x normal — algo subindo, fica de olho
  w_pps=$(( norm * 2 ));   [ "$w_pps"   -lt 5000  ] && w_pps=5000
  # ATTACK: 4x normal — quase certeza de flood
  a_pps=$(( norm * 4 ));   [ "$a_pps"   -lt 15000 ] && a_pps=15000
  # captura (watch.sh dispara pcap): 3x normal — entre warning e attack
  pps_lim=$(( norm * 3 )); [ "$pps_lim" -lt 10000 ] && pps_lim=10000
  ( umask 077; cat > "$CONF" <<OTG_CONF
# OTGuard $OTG_VER — gerado em $(date -Is)
IFACE=$W_IFACE
PORTS="$W_PL $W_PG"
PORTS_CSV=$W_PL,$W_PG
ADMIN_IPS="$W_ADM"
PROVIDER=$PROV_KEY
PROVIDER_NAME="$PROV_NAME"
SCRUB_NAME="$SCRUB"
PROVIDER_ASK="$PROV_ASK"
DISCORD_WEBHOOK="$W_HOOK"
CF_FILTER=$W_CF
WEB_PORTS_CSV=80,443
# captura + alerta (tibia-ddos-watch)
PPS_LIMIT=$pps_lim
CT_LIMIT=40000
SYN_LIMIT=300
NEED_HITS=2
COOLDOWN=900
PCAP_MAX=100000
PCAP_SECS=120
PROFILE_SECS=60
DIR_MAX_MB=1024
FREE_MIN_MB=1536
INTERVAL=10
# cores do monitor (otguard-mon)
A_PPS=$a_pps
W_PPS=$w_pps
A_CT=40000
W_CT=8000
A_SYN=400
W_SYN=40
A_HO=300
W_HO=50
OTG_CONF
  )
  chmod 600 "$CONF"
}

# --------------------------------------------------------------------------
emit_scripts() {  # $1 = dir p/ os 3 .sh de sbin   $2 = dir p/ o otguard-mon
  sd=$1; bd=$2

  cat > "$sd/otguard-mitigacao.sh" <<'OTG_MIT'
#!/bin/sh
# OTGuard — mitigacao: ipset blocklist + iptables raw + RPS. Idempotente.
. /etc/otguard/otguard.conf 2>/dev/null
IFACE=${IFACE:-eth0}; PORTS_CSV=${PORTS_CSV:-7171,7172}
BL=/etc/otguard/blocklist.ipset
if [ -f "$BL" ]; then ipset restore -exist -file "$BL"
else ipset create -exist otguard_bl hash:ip timeout 86400 maxelem 262144; fi
iptables -t raw -F PREROUTING
for a in $ADMIN_IPS; do
  [ -n "$a" ] && iptables -t raw -A PREROUTING -s "$a" -p tcp -m multiport --dports "$PORTS_CSV" -j ACCEPT
done
iptables -t raw -A PREROUTING -p tcp -m multiport --dports "$PORTS_CSV" -m set --match-set otguard_bl src -j DROP
iptables -t raw -A PREROUTING -p udp -m multiport --dports "$PORTS_CSV" -j DROP
iptables -t raw -A PREROUTING -p tcp -m multiport --dports "$PORTS_CSV" --syn -m hashlimit \
  --hashlimit-name otg_g --hashlimit-mode dstport --hashlimit-above 150/sec --hashlimit-burst 200 -j DROP
iptables -t raw -A PREROUTING -p tcp -m multiport --dports "$PORTS_CSV" --syn -m hashlimit \
  --hashlimit-name otg_s --hashlimit-mode srcip --hashlimit-srcmask 32 --hashlimit-above 30/min --hashlimit-burst 40 -j DROP
# protecao do site: 80/443 so da Cloudflare (opcional, com fail-safe)
ip6tables -t raw -F PREROUTING 2>/dev/null
if [ "$CF_FILTER" = sim ]; then
  [ -x /usr/local/sbin/otguard-cf-update.sh ] && /usr/local/sbin/otguard-cf-update.sh
  WEB=${WEB_PORTS_CSV:-80,443}
  cf4=$(ipset list otguard_cf 2>/dev/null | awk '/Number of entries/{print $4}')
  if [ "${cf4:-0}" -gt 0 ]; then
    # admin com IP FIXO passa direto em 80/443 — quem tem CGNAT/IP dinamico acessa via dominio
    for a in $ADMIN_IPS; do
      [ -n "$a" ] && iptables -t raw -A PREROUTING -s "$a" -p tcp -m multiport --dports "$WEB" -j ACCEPT
    done
    iptables -t raw -A PREROUTING -p tcp -m multiport --dports "$WEB" -m set --match-set otguard_cf src -j ACCEPT
    iptables -t raw -A PREROUTING -p tcp -m multiport --dports "$WEB" -j DROP
    logger -t otguard-mitigacao "filtragem Cloudflare ativa em $WEB (admin bypass: ${ADMIN_IPS:-nenhum})"
  else
    logger -t otguard-mitigacao "CF ligado mas ipset v4 vazio — site liberado (fail-safe)"
  fi
  cf6=$(ipset list otguard_cf6 2>/dev/null | awk '/Number of entries/{print $4}')
  if [ "${cf6:-0}" -gt 0 ]; then
    ip6tables -t raw -A PREROUTING -p tcp -m multiport --dports "$WEB" -m set --match-set otguard_cf6 src -j ACCEPT 2>/dev/null
    ip6tables -t raw -A PREROUTING -p tcp -m multiport --dports "$WEB" -j DROP 2>/dev/null
  fi
fi
mask=$(printf '%x' $(( (1 << $(nproc)) - 1 )))
for q in /sys/class/net/$IFACE/queues/rx-*/rps_cpus; do [ -e "$q" ] && echo "$mask" > "$q"; done 2>/dev/null
logger -t otguard-mitigacao "regras raw + ipset + RPS aplicados (portas $PORTS_CSV)"
OTG_MIT

  cat > "$sd/otguard-cf-update.sh" <<'OTG_CFU'
#!/bin/sh
# OTGuard — baixa os ranges da Cloudflare e atualiza os ipsets otguard_cf / otguard_cf6.
. /etc/otguard/otguard.conf 2>/dev/null
[ "$CF_FILTER" = sim ] || exit 0
tmp=$(mktemp)
if curl -fsS -m 25 https://www.cloudflare.com/ips-v4 -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  ipset create -exist otguard_cf hash:net
  ipset create -exist otguard_cf_new hash:net
  ipset flush otguard_cf_new
  while read -r n; do [ -n "$n" ] && ipset add -exist otguard_cf_new "$n"; done < "$tmp"
  ipset swap otguard_cf_new otguard_cf
  ipset destroy otguard_cf_new
  logger -t otguard-cf "ranges IPv4 da Cloudflare atualizados"
else
  logger -t otguard-cf "FALHA ao baixar ranges IPv4 da Cloudflare"
fi
if curl -fsS -m 25 https://www.cloudflare.com/ips-v6 -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  ipset create -exist otguard_cf6 hash:net family inet6
  ipset create -exist otguard_cf6_new hash:net family inet6
  ipset flush otguard_cf6_new
  while read -r n; do [ -n "$n" ] && ipset add -exist otguard_cf6_new "$n"; done < "$tmp"
  ipset swap otguard_cf6_new otguard_cf6
  ipset destroy otguard_cf6_new
  logger -t otguard-cf "ranges IPv6 da Cloudflare atualizados"
else
  logger -t otguard-cf "FALHA ao baixar ranges IPv6 da Cloudflare"
fi
rm -f "$tmp"
OTG_CFU

  cat > "$sd/otguard-watch.sh" <<'OTG_WATCH'
#!/bin/sh
# OTGuard — vigia as portas do jogo; ao detectar flood captura evidencia
# (pcap + pps.csv + relatorio) em /var/log/otguard e alerta no Discord.
. /etc/otguard/otguard.conf 2>/dev/null
IFACE=${IFACE:-eth0}; OUTDIR=/var/log/otguard
INTERVAL=${INTERVAL:-10}; PPS_LIMIT=${PPS_LIMIT:-35000}
CT_LIMIT=${CT_LIMIT:-40000}; SYN_LIMIT=${SYN_LIMIT:-300}
NEED_HITS=${NEED_HITS:-2}; COOLDOWN=${COOLDOWN:-900}
PCAP_MAX=${PCAP_MAX:-100000}; PCAP_SECS=${PCAP_SECS:-120}
PROFILE_SECS=${PROFILE_SECS:-60}; DIR_MAX_MB=${DIR_MAX_MB:-1024}
FREE_MIN_MB=${FREE_MIN_MB:-1536}
RXFILE="/sys/class/net/$IFACE/statistics/rx_packets"
CT_COUNT=/proc/sys/net/netfilter/nf_conntrack_count
mkdir -p "$OUTDIR"
pf=''; for p in ${PORTS:-7171 7172}; do pf="${pf:+$pf or }dst port $p"; done
logger -t otguard-watch "armado: pps>$PPS_LIMIT ct>$CT_LIMIT syn>$SYN_LIMIT"

free_mb() { df -P / | awk 'NR==2{print int($4/1024)}'; }
dir_mb()  { du -sm "$OUTDIR" 2>/dev/null | awk '{print $1}'; }
ct_now()  { cat "$CT_COUNT" 2>/dev/null || echo 0; }
syn_now() { iptables -t raw -L PREROUTING -n -v -x 2>/dev/null | awk '/150\/sec/{print $1; exit}'; }

discord_send() {
  [ -z "$DISCORD_WEBHOOK" ] && { logger -t otguard-watch "Discord nao configurado"; return 1; }
  curl -fsS -m 15 -H 'Content-Type: application/json' -X POST -d "$1" "$DISCORD_WEBHOOK" >/dev/null 2>&1
}
notify_discord() {
  r="$1"; p="$2"; c="$3"; s="$4"; rep="$5"
  myip=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  when=$(date '+%d/%m/%Y %H:%M:%S')
  mt="pacotes/s: **${p}**\\nconntrack: **${c}**\\nSYN dropados: **${s}**"
  neep="\`\`\`DDoS no IP ${myip} (servidor de jogo, portas ${PORTS}).\\nInicio: ${when}. Gatilho: ${r}.\\nO ataque chegou na maquina, ou seja passou por ${SCRUB_NAME}.\\n${PROVIDER_ASK}\`\`\`"
  ev="\`${rep}\`\\n(o .pcap e o .csv ficam na mesma pasta)"
  js=$(printf '{"username":"OTGuard","embeds":[{"title":"🚨 Ataque DDoS detectado","description":"Trafego de ataque chegou no servidor de jogo.","color":15158332,"fields":[{"name":"🎯 IP atacado","value":"`%s`","inline":true},{"name":"🕐 Inicio","value":"%s","inline":true},{"name":"🔌 Portas","value":"%s","inline":true},{"name":"💥 Gatilho","value":"%s","inline":false},{"name":"📊 Metricas no disparo","value":"%s","inline":false},{"name":"📋 Resumo para %s (copie e cole)","value":"%s","inline":false},{"name":"💾 Evidencia na VM","value":"%s","inline":false}],"footer":{"text":"OTGuard · captura automatica em andamento"}}]}' \
    "$myip" "$when" "$PORTS" "$r" "$mt" "$PROVIDER_NAME" "$neep" "$ev")
  discord_send "$js" && logger -t otguard-watch "alerta Discord enviado" || logger -t otguard-watch "alerta Discord falhou"
}
prune() {
  while [ "$(dir_mb)" -gt "$DIR_MAX_MB" ]; do
    old=$(ls -1tr "$OUTDIR"/capture-*.pcap 2>/dev/null | head -1)
    [ -z "$old" ] && break
    rm -f "$old"; logger -t otguard-watch "prune: $old"
  done
}
capture() {
  cr="$1"; cp="$2"; cc="$3"; cs="$4"
  ts=$(date +%Y%m%d-%H%M%S)
  rep="$OUTDIR/report-$ts.txt"; pcap="$OUTDIR/capture-$ts.pcap"; csv="$OUTDIR/pps-$ts.csv"
  logger -t otguard-watch "ATAQUE ($cr) -> capturando em $OUTDIR"
  notify_discord "$cr" "$cp" "$cc" "$cs" "$rep" &
  {
    echo "# OTGuard — captura automatica de evidencia de DDoS"
    echo "data       : $(date -Is)"
    echo "servidor   : $(hostname)   IP $(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}')"
    echo "provedor   : $PROVIDER_NAME   (protecao upstream: $SCRUB_NAME)"
    echo "gatilho    : $cr"
    echo "pps eth0   : $cp   (limite $PPS_LIMIT)"
    echo "conntrack  : $cc   (limite $CT_LIMIT)"
    echo "SYN barrados: $cs na janela de ${INTERVAL}s   (limite $SYN_LIMIT)"
    echo
    echo "## ss -s"; ss -s 2>/dev/null
    echo
    echo "## iptables raw PREROUTING"; iptables -t raw -L PREROUTING -n -v 2>/dev/null
    echo
    echo "## top 20 origens em SYN-RECV"
    ss -tn state syn-recv 2>/dev/null | awk 'NR>1{print $4}' | sed 's/:[0-9]*$//' \
      | sort | uniq -c | sort -rn | head -20
    echo
    echo "## o que pedir ao provedor:"; echo "$PROVIDER_ASK"
  } > "$rep" 2>&1
  tcpd=''
  if [ "$(free_mb)" -lt "$FREE_MIN_MB" ]; then
    printf '\n## pcap PULADO: pouco espaco em disco\n' >> "$rep"
  else
    timeout "$PCAP_SECS" tcpdump -i "$IFACE" -s 96 -c "$PCAP_MAX" -nn -w "$pcap" \
      "(tcp or udp) and ($pf)" >/dev/null 2>&1 &
    tcpd=$!
  fi
  echo "epoch,pps_eth0,conntrack" > "$csv"
  n=$(( PROFILE_SECS / 5 )); [ "$n" -lt 1 ] && n=1
  a=$(cat "$RXFILE" 2>/dev/null || echo 0); i=0
  while [ "$i" -lt "$n" ]; do
    sleep 5
    b=$(cat "$RXFILE" 2>/dev/null || echo "$a")
    d=$(( b - a )); [ "$d" -lt 0 ] && d=0
    echo "$(date +%s),$(( d / 5 )),$(ct_now)" >> "$csv"
    a=$b; i=$(( i + 1 ))
  done
  [ -n "$tcpd" ] && { wait "$tcpd" 2>/dev/null; [ -f "$pcap" ] && \
    printf '\n## pcap: %s (%s)\n' "$pcap" "$(du -h "$pcap" | cut -f1)" >> "$rep"; }
  prune
  logger -t otguard-watch "captura concluida: $rep"
}

if [ "$1" = "--test" ]; then
  tj=$(printf '{"username":"OTGuard","embeds":[{"title":"✅ Teste do OTGuard","description":"Se voce ve isto no canal, o alerta de ataque esta funcionando.","color":3066993,"fields":[{"name":"Servidor","value":"`%s`","inline":true},{"name":"Quando","value":"%s","inline":true}],"footer":{"text":"OTGuard · mensagem de teste"}}]}' \
    "$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)" "$(date '+%d/%m/%Y %H:%M:%S')")
  discord_send "$tj" && echo "teste enviado ao Discord" || echo "falha ao enviar (cheque o webhook)"
  exit 0
fi

rx_prev=''; syn_prev=''; hits=0
while :; do
  rx=$(cat "$RXFILE" 2>/dev/null || echo "$rx_prev")
  sc=$(syn_now); [ -z "$sc" ] && sc=0
  ctc=$(ct_now)
  pps=0; synd=0
  [ -n "$rx_prev" ] && [ "$rx" -ge "$rx_prev" ] && pps=$(( (rx - rx_prev) / INTERVAL ))
  [ -n "$syn_prev" ] && [ "$sc" -ge "$syn_prev" ] && synd=$(( sc - syn_prev ))
  rx_prev="$rx"; syn_prev="$sc"
  reason=''
  [ "$pps"  -ge "$PPS_LIMIT" ] && reason="pps eth0 ${pps}/s"
  [ "$ctc"  -ge "$CT_LIMIT"  ] && reason="${reason:+$reason + }conntrack ${ctc}"
  [ "$synd" -ge "$SYN_LIMIT" ] && reason="${reason:+$reason + }SYN-flood ${synd}/janela"
  if [ -n "$reason" ]; then hits=$(( hits + 1 )); else hits=0; fi
  if [ "$hits" -ge "$NEED_HITS" ]; then
    capture "$reason" "$pps" "$ctc" "$synd"
    hits=0; sleep "$COOLDOWN"
    rx_prev=$(cat "$RXFILE" 2>/dev/null || echo ''); syn_prev=$(syn_now)
    continue
  fi
  sleep "$INTERVAL"
done
OTG_WATCH

  cat > "$sd/otguard-live.sh" <<'OTG_LIVE'
#!/bin/sh
# OTGuard — monitor continuo (1 amostra/s) -> /var/log/otguard/live.log
. /etc/otguard/otguard.conf 2>/dev/null
IFACE=${IFACE:-eth0}; LOG=/var/log/otguard/live.log
INTERVAL=1; ROT_MAX=5242880
RXP=/sys/class/net/$IFACE/statistics/rx_packets
RXB=/sys/class/net/$IFACE/statistics/rx_bytes
CT=/proc/sys/net/netfilter/nf_conntrack_count
A_PPS=${A_PPS:-60000}; W_PPS=${W_PPS:-25000}
A_SYN=${A_SYN:-400};   W_SYN=${W_SYN:-40}
A_CT=${A_CT:-40000};   W_CT=${W_CT:-8000}
A_HO=${A_HO:-300};     W_HO=${W_HO:-50}
mkdir -p "$(dirname "$LOG")"; : >> "$LOG"
syn_now() { iptables -w 2 -t raw -L PREROUTING -n -v -x 2>/dev/null | awk '/150\/sec/{print $1; exit}'; }
p_prev=''; b_prev=''; s_prev=''; tick=0
while :; do
  p=$(cat "$RXP" 2>/dev/null || echo 0); b=$(cat "$RXB" 2>/dev/null || echo 0)
  s=$(syn_now); [ -z "$s" ] && s=0
  ct=$(cat "$CT" 2>/dev/null || echo 0)
  ho=$(ss -H -tn state syn-recv 2>/dev/null | wc -l)
  pps=0; mbps=0; sd=0
  [ -n "$p_prev" ] && [ "$p" -ge "$p_prev" ] && pps=$(( (p - p_prev) / INTERVAL ))
  [ -n "$b_prev" ] && [ "$b" -ge "$b_prev" ] && mbps=$(( (b - b_prev) * 8 / 1000000 / INTERVAL ))
  [ -n "$s_prev" ] && [ "$s" -ge "$s_prev" ] && sd=$(( s - s_prev ))
  p_prev=$p; b_prev=$b; s_prev=$s
  st=OK
  { [ "$pps" -ge "$W_PPS" ] || [ "$sd" -ge "$W_SYN" ] || [ "$ct" -ge "$W_CT" ] || [ "$ho" -ge "$W_HO" ]; } && st=ALERTA
  { [ "$pps" -ge "$A_PPS" ] || [ "$sd" -ge "$A_SYN" ] || [ "$ct" -ge "$A_CT" ] || [ "$ho" -ge "$A_HO" ]; } && st=ATAQUE
  printf '%-8s %10s %8s %11s %11s %11s  %s\n' \
    "$(date +%H:%M:%S)" "$pps" "$mbps" "$ct" "$sd" "$ho" "$st" >> "$LOG"
  tick=$(( tick + 1 ))
  if [ "$tick" -ge 120 ]; then
    tick=0
    [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$ROT_MAX" ] && { mv -f "$LOG" "$LOG.1"; : >> "$LOG"; }
  fi
  sleep "$INTERVAL"
done
OTG_LIVE

  cat > "$bd/otguard-mon" <<'OTG_MON'
#!/bin/bash
# OTGuard — painel ao vivo.  [w] envia snapshot ao Discord   [q] sai
LOG=/var/log/otguard/live.log
CONF=/etc/otguard/otguard.conf
[ -f "$CONF" ] && . "$CONF"
A_PPS=${A_PPS:-60000}; W_PPS=${W_PPS:-25000}
A_SYN=${A_SYN:-400};   W_SYN=${W_SYN:-40}
A_CT=${A_CT:-40000};   W_CT=${W_CT:-8000}
A_HO=${A_HO:-300};     W_HO=${W_HO:-50}
IP=$(ip -4 -o addr show "${IFACE:-eth0}" 2>/dev/null | awk '{print $4}')
SPARK_N=50; peak=0; SENT=""; sent_at=-10
[ -t 0 ] && INTERACTIVE=1
BORD='\033[90m'; TITLE='\033[1;36m'; DIM='\033[2m'; SPK='\033[36m'; RST='\033[0m'
cleanup() { printf '\033[?25h\033[0m\n'; exit 0; }
trap cleanup INT TERM
hrule() { _h=''; _n=$2; while [ "$_n" -gt 0 ]; do _h="$_h$1"; _n=$((_n-1)); done; printf '%s' "$_h"; }
bar() {
  bv=$1; bw=$2; ba=$3; bwidth=32
  case $bv in *[!0-9]*|'') bv=0;; esac
  bfill=$(( bv * bwidth / ba )); [ "$bfill" -gt "$bwidth" ] && bfill=$bwidth
  if   [ "$bv" -ge "$ba" ]; then bc='\033[1;31m'
  elif [ "$bv" -ge "$bw" ]; then bc='\033[1;33m'
  else bc='\033[1;32m'; fi
  bf=''; be=''; bi=0
  while [ "$bi" -lt "$bwidth" ]; do
    if [ "$bi" -lt "$bfill" ]; then bf="$bf|"; else be="$be "; fi
    bi=$(( bi + 1 ))
  done
  printf '%b[%b%s%b%s%b]%b' "$BORD" "$bc" "$bf" "$DIM" "$be" "$BORD" "$RST"
}
row() { printf '%b│%b  %s\033[K\033[72G%b│%b\n' "$BORD" "$RST" "$1" "$BORD" "$RST"; }
check_prot() {
  rawp=$(iptables -w 2 -t raw -S PREROUTING 2>/dev/null)
  if [ -z "$rawp" ]; then
    prot=$(printf 'protecao    %b(rode como root para checar as regras)%b' "$DIM" "$RST"); return
  fi
  pg='\033[1;32m'; pr='\033[1;31m'
  case $rawp in *multiport*) fw="${pg}✓${RST}";; *) fw="${pr}✗${RST}";; esac
  case $rawp in *otg_g*)     fl="${pg}✓${RST}";; *) fl="${pr}✗${RST}";; esac
  bn=$(ipset list otguard_bl 2>/dev/null | awk '/Number of entries/{print $4}')
  if [ -n "$bn" ]; then bs="${pg}✓${RST} ${DIM}${bn} IPs${RST}"; else bs="${pr}✗${RST}"; fi
  prot=$(printf 'protecao    firewall %b    anti-flood %b    blocklist %b' "$fw" "$fl" "$bs")
}
send_snapshot() {
  local when js
  if [ -z "$DISCORD_WEBHOOK" ]; then
    SENT=$(printf '%b' '\033[1;31m✗ webhook nao configurado\033[0m'); sent_at=$SECONDS; return
  fi
  when=$(date '+%d/%m/%Y %H:%M:%S')
  js=$(printf '{"username":"OTGuard","embeds":[{"title":"📊 Snapshot do monitor","description":"Envio manual do painel ao vivo.","color":3447003,"fields":[{"name":"🎯 Servidor","value":"`%s`","inline":true},{"name":"🕐 Quando","value":"%s","inline":true},{"name":"Estado","value":"**%s**","inline":true},{"name":"📊 Agora","value":"pacotes/s: **%s**  ·  banda: **%s Mb/s**\\nconntrack: **%s**  ·  SYN drop/s: **%s**  ·  half-open: **%s**","inline":false},{"name":"📈 Pico de pkt/s na sessao","value":"%s","inline":false}],"footer":{"text":"enviado manualmente via otguard-mon"}}]}' \
    "${IP:-?}" "$when" "$est" "$pps" "$mbps" "$ct" "$syn" "$ho" "$peak")
  if curl -fsS -m 15 -H 'Content-Type: application/json' -X POST -d "$js" "$DISCORD_WEBHOOK" >/dev/null 2>&1; then
    SENT=$(printf '%b' "\033[1;32m✓ snapshot enviado ao Discord — $(date '+%H:%M:%S')\033[0m")
  else
    SENT=$(printf '%b' '\033[1;31m✗ falha ao enviar (curl/webhook)\033[0m')
  fi
  sent_at=$SECONDS
}
TOP=$(printf '%b┌─ %b%s %b%s┐%b' "$BORD" "$TITLE" 'OTGuard · monitor de trafego' "$BORD" "$(hrule ─ 39)" "$RST")
SEP=$(printf '%b├%s┤%b' "$BORD" "$(hrule ─ 70)" "$RST")
BOT=$(printf '%b└%s┘%b' "$BORD" "$(hrule ─ 70)" "$RST")
printf '\033[2J\033[?25l'
ptick=0; check_prot
while :; do
  set -- $(tail -n 1 "$LOG" 2>/dev/null)
  hora=$1; pps=$2; mbps=$3; ct=$4; syn=$5; ho=$6; est=$7
  case $pps in *[!0-9]*|'') pps=0;; esac
  case $mbps in *[!0-9]*|'') mbps=0;; esac
  [ "$pps" -gt "$peak" ] && peak=$pps
  case $est in
    ATAQUE) badge='\033[1;5;37;41m  ATAQUE  \033[0m'; desc='ataque em andamento';;
    ALERTA) badge='\033[1;30;43m  ALERTA  \033[0m';   desc='trafego elevado, de olho';;
    *)      badge='\033[1;30;42m    OK    \033[0m';   desc='trafego normal';;
  esac
  spark=$(tail -n "$SPARK_N" "$LOG" 2>/dev/null | awk '
    { v[NR]=$2+0; if(NR==1||v[NR]<mn)mn=v[NR]; if(NR==1||v[NR]>mx)mx=v[NR] }
    END { b[0]="▁";b[1]="▂";b[2]="▃";b[3]="▄";b[4]="▅";b[5]="▆";b[6]="▇";b[7]="█"
          r=mx-mn; if(r<=0)r=1; s=""
          for(i=1;i<=NR;i++){ l=int((v[i]-mn)*7/r); if(l<0)l=0; if(l>7)l=7; s=s b[l] }
          print s }')
  if [ -n "$SENT" ] && [ $((SECONDS - sent_at)) -lt 6 ]; then foot="$SENT"
  else foot=$(printf '%b[w]%b enviar snapshot ao Discord     %b[q]%b sair     %batualiza 1x/s%b' "$RST" "$DIM" "$RST" "$DIM" "$DIM" "$RST"); fi
  ptick=$((ptick+1)); [ "$ptick" -ge 15 ] && { ptick=0; check_prot; }
  printf '\033[H'
  printf '%s\033[K\n' "$TOP"
  row "$(printf '%b%-30s%30s%b' "$DIM" "${IP:-?}" "$(date '+%d/%m  %H:%M:%S')" "$RST")"
  row ''
  row "$(printf 'estado   %b   %b%s%b' "$badge" "$DIM" "$desc" "$RST")"
  row "$prot"
  row ''
  row "$(printf '%-11s %s  %7s %b/ %s%b' 'pacotes/s'  "$(bar "$pps" "$W_PPS" "$A_PPS")" "$pps" "$DIM" "$A_PPS" "$RST")"
  row "$(printf '%-11s %s  %7s %b/ %s%b' 'conntrack'  "$(bar "$ct"  "$W_CT"  "$A_CT")"  "$ct"  "$DIM" "$A_CT"  "$RST")"
  row "$(printf '%-11s %s  %7s %b/ %s%b' 'SYN drop/s' "$(bar "$syn" "$W_SYN" "$A_SYN")" "$syn" "$DIM" "$A_SYN" "$RST")"
  row "$(printf '%-11s %s  %7s %b/ %s%b' 'half-open'  "$(bar "$ho"  "$W_HO"  "$A_HO")"  "$ho"  "$DIM" "$A_HO"  "$RST")"
  row ''
  row "$(printf '%-11s %b%s%b' 'tendencia' "$SPK" "$spark" "$RST")"
  row ''
  printf '%s\033[K\n' "$SEP"
  row "$foot"
  printf '%s\033[K\n' "$BOT"
  printf '\033[J'
  if [ -n "$INTERACTIVE" ]; then
    if read -rsn1 -t 1 key; then
      case "$key" in
        w|W) [ $((SECONDS - sent_at)) -ge 5 ] && send_snapshot ;;
        q|Q) cleanup ;;
      esac
    fi
  else sleep 1; fi
done
OTG_MON
  chmod +x "$sd/otguard-mitigacao.sh" "$sd/otguard-cf-update.sh" "$sd/otguard-watch.sh" "$sd/otguard-live.sh" "$bd/otguard-mon"
}

emit_units() {
  cat > /etc/systemd/system/otguard-mitigacao.service <<'OTG_U1'
[Unit]
Description=OTGuard: mitigacao (iptables raw + ipset + RPS)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/otguard-mitigacao.sh
[Install]
WantedBy=multi-user.target
OTG_U1
  cat > /etc/systemd/system/otguard-watch.service <<'OTG_U2'
[Unit]
Description=OTGuard: captura de evidencia + alerta Discord
After=network-online.target otguard-mitigacao.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/sbin/otguard-watch.sh
Restart=always
RestartSec=5
Nice=10
[Install]
WantedBy=multi-user.target
OTG_U2
  cat > /etc/systemd/system/otguard-live.service <<'OTG_U3'
[Unit]
Description=OTGuard: monitor continuo (1 amostra/s)
After=network-online.target otguard-mitigacao.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/sbin/otguard-live.sh
Restart=always
RestartSec=3
Nice=10
[Install]
WantedBy=multi-user.target
OTG_U3
  cat > /etc/systemd/system/otguard-cfupdate.service <<'OTG_U4'
[Unit]
Description=OTGuard: atualiza os ranges da Cloudflare
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/otguard-cf-update.sh
OTG_U4
  cat > /etc/systemd/system/otguard-cfupdate.timer <<'OTG_U5'
[Unit]
Description=OTGuard: atualizacao semanal dos ranges da Cloudflare
[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h
[Install]
WantedBy=timers.target
OTG_U5
}

# --------------------------------------------------------------------------
apply() {
  cat > /etc/sysctl.d/99-otguard.conf <<'OTG_SYS'
# OTGuard — tuning anti-DDoS
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 8192
net.netfilter.nf_conntrack_max = 2097152
OTG_SYS
  sysctl -q -p /etc/sysctl.d/99-otguard.conf >/dev/null 2>&1
  ok "ajustes de rede (sysctl) aplicados"
  mkdir -p "$LOGDIR"
  emit_scripts /usr/local/sbin /usr/local/bin
  emit_units
  systemctl daemon-reload
  ok "componentes e units instalados"
  for s in otguard-mitigacao otguard-watch otguard-live; do
    say "  ${CD}subindo $s ...${CR}"
    systemctl enable "$s" >/dev/null 2>&1
    systemctl restart "$s"
  done
  ok "servicos no ar"
  if grep -q '^CF_FILTER=sim' "$CONF" 2>/dev/null; then
    systemctl enable --now otguard-cfupdate.timer >/dev/null 2>&1
    ok "filtragem Cloudflare ativada"
  else
    systemctl disable --now otguard-cfupdate.timer >/dev/null 2>&1
  fi
  # instala o proprio script como comando global "otguard" (qualquer pasta)
  if [ -f "$0" ]; then
    cp -f "$0" /usr/local/sbin/otguard 2>/dev/null
    chmod 0755 /usr/local/sbin/otguard 2>/dev/null
    ln -sf /usr/local/sbin/otguard /usr/local/bin/otguard
    ok 'comando global: digite "otguard" em qualquer lugar'
  fi
}

status() {
  [ -f "$CONF" ] || die "OTGuard nao esta instalado."
  . "$CONF"
  say ""
  say "  ${CT}OTGuard $OTG_VER${CR}  ·  $PROVIDER_NAME  ·  portas $PORTS"
  hr
  for s in otguard-mitigacao otguard-watch otguard-live; do
    en=$(systemctl is-enabled "$s" 2>/dev/null)
    ac=$(systemctl is-active  "$s" 2>/dev/null)
    if [ "$ac" = active ]; then ok "$s  ($en / $ac)"; else err "$s  ($en / $ac)"; fi
  done
  n=$(ipset list otguard_bl 2>/dev/null | awk '/Number of entries/{print $4}')
  say "  ${CD}ipset blocklist: ${n:-0} IPs  ·  webhook: $( [ -n "$DISCORD_WEBHOOK" ] && echo configurado || echo nao )${CR}"
  if [ "$CF_FILTER" = sim ]; then
    cfn=$(ipset list otguard_cf 2>/dev/null | awk '/Number of entries/{print $4}')
    say "  ${CD}filtragem Cloudflare: ATIVA — ${cfn:-0} ranges no allowlist do site (80/443)${CR}"
  fi
  say "  ${CD}painel ao vivo:  otguard mon${CR}"
  say ""
}

# --------------------------------------------------------------------------
# Menu principal — chamado quando o usuario digita "otguard" sem argumento
helper() {
  [ -f "$CONF" ] || die "OTGuard nao instalado. Rode:  sudo sh otguard.sh"
  . "$CONF"
  say ""
  say "  ${CT}OTGuard $OTG_VER${CR}  ·  $PROVIDER_NAME  ·  portas $PORTS"
  hr
  for s in otguard-mitigacao otguard-watch otguard-live; do
    ac=$(systemctl is-active "$s" 2>/dev/null)
    if [ "$ac" = active ]; then ok "$s"; else err "$s ($ac)"; fi
  done
  n=$(ipset list otguard_bl 2>/dev/null | awk '/Number of entries/{print $4}')
  say "  ${CD}blocklist: ${n:-0} IP(s) bloqueado(s)  ·  webhook: $( [ -n "$DISCORD_WEBHOOK" ] && echo configurado || echo nao )${CR}"
  if [ "$CF_FILTER" = sim ]; then
    cfn=$(ipset list otguard_cf 2>/dev/null | awk '/Number of entries/{print $4}')
    say "  ${CD}Cloudflare 80/443: ATIVA — ${cfn:-0} ranges no allowlist${CR}"
  fi
  say ""
  say "  ${CT}Comandos disponiveis:${CR}"
  say "    ${CT}otguard mon${CR}            painel ao vivo (graficos + alertas)"
  say "    ${CT}otguard status${CR}         este resumo"
  say "    ${CT}otguard ban${CR} <ip>       bloqueia IP nas portas do jogo (sobrevive reboot)"
  say "    ${CT}otguard unban${CR} <ip>     libera um IP"
  say "    ${CT}otguard banlist${CR}        lista os IPs bloqueados"
  say "    ${CT}otguard test${CR}           envia mensagem de teste ao Discord"
  say "    ${CT}otguard reconfig${CR}       refaz o assistente de instalacao"
  say "    ${CT}otguard uninstall${CR}      remove o OTGuard"
  say ""
  say "  ${CD}dica: digite ${CR}${CT}ot${CR}${CD} e TAB pra ver tudo (otguard / otguard-mon).${CR}"
  say ""
}

# --------------------------------------------------------------------------
# Persistencia da blocklist — sobrevive ao reboot
BL_FILE=/etc/otguard/blocklist.ipset

bl_save() {
  mkdir -p /etc/otguard
  if ipset save otguard_bl > "$BL_FILE.tmp" 2>/dev/null; then
    mv -f "$BL_FILE.tmp" "$BL_FILE"
    chmod 600 "$BL_FILE"
    return 0
  fi
  rm -f "$BL_FILE.tmp"
  return 1
}

# valida IPv4 simples: 4 octetos 0-255
_valid_ip4() {
  case "$1" in *[!0-9.]*|'') return 1 ;; esac
  _OIFS=$IFS; IFS=.
  set -- $1
  IFS=$_OIFS
  [ "$#" = 4 ] || return 1
  for o in "$1" "$2" "$3" "$4"; do
    case "$o" in *[!0-9]*|'') return 1 ;; esac
    [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] || return 1
  done
  return 0
}

ban_ip() {
  [ "$(id -u)" = 0 ] || die "rode como root (sudo otguard ban $1)"
  [ -f "$CONF" ]    || die "OTGuard nao instalado."
  [ -n "$1" ]       || die "uso: otguard ban <IP>"
  _valid_ip4 "$1"   || die "IP invalido: $1"
  ipset create -exist otguard_bl hash:ip timeout 86400 maxelem 262144
  ipset add -exist otguard_bl "$1" timeout 0   # timeout 0 = permanente
  if bl_save; then
    ok "IP $1 bloqueado (permanente — sobrevive reboot)"
  else
    warn "IP $1 bloqueado em memoria, MAS falhou em salvar em $BL_FILE"
  fi
}

unban_ip() {
  [ "$(id -u)" = 0 ] || die "rode como root (sudo otguard unban $1)"
  [ -f "$CONF" ]    || die "OTGuard nao instalado."
  [ -n "$1" ]       || die "uso: otguard unban <IP>"
  if ipset del otguard_bl "$1" 2>/dev/null; then
    bl_save && ok "IP $1 liberado" || warn "liberado em memoria, mas falhou em salvar"
  else
    warn "IP $1 nao estava na blocklist"
  fi
}

banlist() {
  [ "$(id -u)" = 0 ] || die "rode como root (sudo otguard banlist)"
  if ! ipset list otguard_bl >/dev/null 2>&1; then
    say ""
    say "  ${CD}blocklist vazia (ipset ainda nao foi criada).${CR}"
    say ""
    return
  fi
  n=$(ipset list otguard_bl | awk '/Number of entries/{print $4}')
  say ""
  say "  ${CT}Blocklist OTGuard${CR}  —  ${n:-0} IP(s)"
  hr
  if [ "${n:-0}" = 0 ]; then
    say "  ${CD}(nenhum IP bloqueado)${CR}"
  else
    ipset list otguard_bl | awk '
      /^Members:/{p=1; next}
      p && NF{
        ip=$1; t=""
        for(i=1;i<=NF;i++) if($i=="timeout") t=$(i+1)
        if(t==""||t==0) lbl="permanente"
        else { h=int(t/3600); m=int((t%3600)/60); lbl="expira em " h "h" m "m" }
        printf "    %-18s  %s\n", ip, lbl
      }'
  fi
  say ""
  say "  ${CD}arquivo persistido: $BL_FILE${CR}"
  say ""
}

uninstall() {
  ask "remover OTGuard por completo?" "n"
  case $ANS in s|S|y|Y) ;; *) say "  cancelado."; exit 0;; esac
  for s in otguard-mitigacao otguard-watch otguard-live; do
    systemctl disable --now "$s" >/dev/null 2>&1
    rm -f "/etc/systemd/system/$s.service"
  done
  systemctl daemon-reload
  systemctl disable --now otguard-cfupdate.timer >/dev/null 2>&1
  rm -f /etc/systemd/system/otguard-cfupdate.service /etc/systemd/system/otguard-cfupdate.timer
  iptables -t raw -F PREROUTING 2>/dev/null
  ip6tables -t raw -F PREROUTING 2>/dev/null
  ipset destroy otguard_bl  2>/dev/null
  ipset destroy otguard_cf  2>/dev/null
  ipset destroy otguard_cf6 2>/dev/null
  rm -f /usr/local/sbin/otguard-mitigacao.sh /usr/local/sbin/otguard-cf-update.sh \
        /usr/local/sbin/otguard-watch.sh /usr/local/sbin/otguard-live.sh \
        /usr/local/bin/otguard-mon /etc/sysctl.d/99-otguard.conf \
        /usr/local/bin/otguard /usr/local/sbin/otguard
  rm -rf "$CONF_DIR"
  ok "OTGuard removido.  (logs em $LOGDIR foram mantidos)"
}

selftest() {
  d=$(mktemp -d)
  emit_scripts "$d" "$d"
  fail=0
  for f in otguard-mitigacao.sh otguard-cf-update.sh otguard-watch.sh otguard-live.sh; do
    if sh -n "$d/$f" 2>/dev/null; then ok "$f"; else err "$f — erro de sintaxe"; fail=1; fi
  done
  if command -v bash >/dev/null 2>&1; then
    if bash -n "$d/otguard-mon" 2>/dev/null; then ok "otguard-mon"; else err "otguard-mon — erro"; fail=1; fi
  else warn "bash ausente — otguard-mon nao checado"; fi
  rm -rf "$d"
  say ""
  [ "$fail" = 0 ] && ok "pacote OTGuard integro." || die "pacote com erro de sintaxe."
}

# --------------------------------------------------------------------------
# build_deb — empacota o proprio script num .deb (Architecture: all).
# Uso:  sh otguard.sh --build-deb [versao]
build_deb() {
  command -v dpkg-deb >/dev/null 2>&1 || die "precisa de dpkg-deb (apt install dpkg)"
  [ -f "$0" ] || die "nao consigo localizar o proprio script ($0)"
  ver=${1:-$OTG_VER}
  pkg="otguard_${ver}_all"
  out="${PWD}/${pkg}.deb"
  tmp=$(mktemp -d) || die "mktemp falhou"
  mkdir -p "$tmp/$pkg/DEBIAN" "$tmp/$pkg/usr/sbin"
  cp "$0" "$tmp/$pkg/usr/sbin/otguard"
  chmod 0755 "$tmp/$pkg/usr/sbin/otguard"
  cat > "$tmp/$pkg/DEBIAN/control" <<CTRL
Package: otguard
Version: $ver
Section: net
Priority: optional
Architecture: all
Depends: iptables, ipset, tcpdump, curl, gawk, whiptail, systemd
Maintainer: OTGuard <noreply@otguard.local>
Description: packet filter, traffic monitor and attack alert for Tibia/OT servers
 OTGuard does the LOCAL half of DDoS mitigation for Tibia / Open Tibia
 game servers: drops junk packets (iptables raw + ipset), throttles
 SYN-floods within link capacity (hashlimit), detects attacks via pps /
 conntrack / SYN-RECV thresholds, captures pcap + technical report for
 forensics, and sends Discord alerts with a ready-to-paste message for
 the hosting provider's support ticket. Includes a live TUI monitor
 and a persistent blocklist.
 .
 IT DOES NOT REPLACE upstream scrubbing (Cloudflare, OVH VAC, NEEP,
 Hetzner DDoS Protection): volumetric attacks larger than the server's
 bandwidth saturate the datacenter edge before reaching this host and
 must be mitigated upstream.
 .
 First run:  sudo otguard
CTRL
  cat > "$tmp/$pkg/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
case "$1" in
  configure)
    cat <<MSG

  OTGuard instalado.  Para configurar (wizard interativo):

      sudo otguard

  Outros comandos:  otguard help

MSG
    ;;
esac
exit 0
POST
  cat > "$tmp/$pkg/DEBIAN/prerm" <<'PRER'
#!/bin/sh
set -e
case "$1" in
  remove|upgrade|deconfigure)
    for s in otguard-watch otguard-live otguard-mitigacao otguard-cfupdate.timer; do
      systemctl is-enabled "$s" >/dev/null 2>&1 && systemctl disable --now "$s" >/dev/null 2>&1 || true
    done
    ;;
esac
exit 0
PRER
  chmod 0755 "$tmp/$pkg/DEBIAN/postinst" "$tmp/$pkg/DEBIAN/prerm"
  dpkg-deb --build --root-owner-group "$tmp/$pkg" "$out" >/dev/null \
    || { rm -rf "$tmp"; die "dpkg-deb falhou"; }
  rm -rf "$tmp"
  ok "pacote gerado: $out"
  ls -lh "$out" 2>/dev/null | awk '{printf "  %s  %s\n", $5, $9}'
  say "  ${CD}instalar localmente:  sudo apt install $out${CR}"
}

do_install() {
  if [ -f "$CONF" ]; then helper; exit 0; fi
  preflight
  wizard
  write_config
  say "  instalando componentes..."
  apply
  ok "OTGuard instalado."
  if [ -n "$W_HOOK" ]; then
    /usr/local/sbin/otguard-watch.sh --test >/dev/null 2>&1 \
      && ok "teste enviado ao Discord" || warn "nao consegui enviar o teste ao Discord"
  fi
  say ""
  helper
  say "  ${CO}Pronto.${CR}  Em qualquer pasta:  ${CT}otguard${CR}  (menu)  ou  ${CT}otguard mon${CR}  (painel)"
  say ""
}

# --------------------------------------------------------------------------
case "${1:-}" in
  status|--status)       status ;;
  mon|--mon)             [ -x /usr/local/bin/otguard-mon ] || die "OTGuard nao instalado"
                         exec /usr/local/bin/otguard-mon ;;
  ban|--ban)             shift; ban_ip "$1" ;;
  unban|--unban)         shift; unban_ip "$1" ;;
  banlist|--banlist|bans) banlist ;;
  test|--test)           [ -f "$CONF" ] || die "OTGuard nao instalado"
                         /usr/local/sbin/otguard-watch.sh --test ;;
  reconfig|--reconfig)   [ "$(id -u)" = 0 ] || die "rode como root"
                         [ -f "$CONF" ] || die "OTGuard nao instalado"
                         . "$CONF"; wizard; write_config; apply; ok "reconfigurado." ;;
  uninstall|--uninstall) [ "$(id -u)" = 0 ] || die "rode como root"; uninstall ;;
  selftest|--selftest)   selftest ;;
  build-deb|--build-deb) shift; build_deb "$@" ;;
  --help|-h|help)        awk '/^# =/{c++;next} c==1{sub(/^# ?/,"");print}' "$0" ;;
  '')                    do_install ;;
  *)                     die "opcao desconhecida: $1   (use:  otguard help)" ;;
esac

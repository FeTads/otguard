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
#    otguard upgrade         redeploya componentes + recalibra thresholds
#                            (chamado sozinho pelo postinst em upgrades de .deb)
#    otguard uninstall       remove tudo
#    otguard --selftest      valida o pacote sem instalar nada
#
#  Empacotamento (para mantenedores):
#    sh otguard.sh --build-deb [versao]    gera otguard_<ver>_all.deb
#
#  Dica: digite "ot" e TAB para autocompletar (otguard / otguard-mon).
# ==========================================================================
OTG_VER=1.6
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

  WZ_N=9
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

Vou te fazer 9 perguntas rapidas. Use:
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
  W_IFACE=$(whiptail --backtitle "$WT_BACK" --title "1/9  Interface de rede" \
    --radiolist "Em qual placa de rede o servidor de OT escuta?\n\n(o OTGuard ja detectou a default da sua VM)" \
    16 70 6 "$@" 3>&1 1>&2 2>&3) || wt_cancel

  # 2) Porta de login
  wt_input "2/9  Porta de login do OT" \
    "Porta de LOGIN do servidor (padrao do Tibia/OT: 7171):" "7171"
  W_PL=$ANS

  # 3) Porta de jogo
  wt_input "3/9  Porta de jogo do OT" \
    "Porta de JOGO do servidor (padrao do Tibia/OT: 7172):" "7172"
  W_PG=$ANS

  # 4) Admin IPs
  wt_input "4/9  Acesso de administrador" \
"IP(s) com acesso livre as portas do jogo (e ao site quando o filtro CF estiver ligado).
Separe com espaco se forem varios.

IP dinamico ou CGNAT?  Deixe vazio e acesse o phpmyadmin pelo dominio
(passa pela Cloudflare).  O SSH nunca e tocado em todo caso." \
    "$sship"
  W_ADM=$ANS

  # 5) Provedor
  W_PROV=$(whiptail --backtitle "$WT_BACK" --title "5/9  Provedor de hospedagem" \
    --radiolist "Onde o servidor esta hospedado?\n\n(o OTGuard usa isso pra te dizer o que pedir ao suporte do provedor quando levar um ataque)" \
    18 70 5 \
    1 "NEEP / ShieldM"              on  \
    2 "OVH (VAC)"                   off \
    3 "Hetzner"                     off \
    4 "Outro provedor"              off \
    5 "VPS sem protecao anti-DDoS"  off \
    3>&1 1>&2 2>&3) || wt_cancel

  # 6) Discord
  wt_input "6/9  Alertas no Discord  (opcional)" \
"Cole a URL do webhook do Discord para receber alerta quando um ataque chegar.

Deixe vazio se nao quiser usar." ""
  W_HOOK=$ANS

  # 7) Cloudflare
  if wt_yesno "7/9  Protecao do site (Cloudflare)" \
"Seu site (portas 80/443) fica atras da Cloudflare NESTA mesma VM?

SIM  →  o OTGuard libera 80/443 so para a Cloudflare e bloqueia o resto.
        Esconde o IP real do servidor; admin com IP fixo passa direto.

NAO  →  o OTGuard nao toca em 80/443.

ATENCAO: marque SIM apenas se o site usa Cloudflare DE VERDADE.
Senao ele sai do ar." "n"; then W_CF=sim; else W_CF=nao; fi

  # 8) Pico de chars online (total — calibra PPS / conntrack globais)
  wt_input "8/9  Tamanho do servidor" \
"Pico estimado de PERSONAGENS online (numero que aparece em
'online' no server, contando todos os chars de todos os players).

Calibra os limites globais de pps e conntrack." \
    "500"
  W_PEAK=$ANS
  case $W_PEAK in *[!0-9]*|'') W_PEAK=500 ;; esac

  # 9) Chars por IP (calibra limites por origem)
  wt_input "9/9  Chars por IP" \
"Quantos personagens 1 jogador pode logar do MESMO IP simultaneamente?

  Tibia oficial:  1
  OT comum:       2 - 4
  OT permissivo:  10 - 50+

Calibra o anti-SYN-flood por origem. Sem isso, um jogador
legitimo logando muitos chars seria barrado como atacante." \
    "4"
  W_CHARS_PER_IP=$ANS
  case $W_CHARS_PER_IP in *[!0-9]*|'') W_CHARS_PER_IP=4 ;; esac
  [ "$W_CHARS_PER_IP" -lt 1 ] && W_CHARS_PER_IP=1

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
  Pico chars:   $W_PEAK
  Chars/IP:     $W_CHARS_PER_IP

Confirmar e instalar?" 22 70 || wt_cancel
}

# --------------------------------------------------------------------------
write_config() {
  mkdir -p "$CONF_DIR"
  # calibragem PPS: assume ~50 pkt/s por player (Tibia PvP/PvM ativo).
  # Validado em campo: server de 630 players ~25k pps reais; players*50 ~= 31500.
  norm=$(( W_PEAK * 50 ))                       # trafego "normal de pico" estimado
  w_pps=$(( norm * 2 ));   [ "$w_pps"   -lt 5000  ] && w_pps=5000     # WARN: 2x normal (amarelo mon)
  a_pps=$(( norm * 4 ));   [ "$a_pps"   -lt 15000 ] && a_pps=15000    # ATAQUE: 4x normal (vermelho mon)
  # captura + auto-lockdown: 10% acima do vermelho do mon (so dispara apos zona de ataque sustentada)
  pps_lim=$(( a_pps + a_pps / 10 )); [ "$pps_lim" -lt 16500 ] && pps_lim=16500
  # calibragem CONNTRACK: ~3 conexoes TCP por char (login + jogo + buffer).
  ct_norm=$(( W_PEAK * 3 ))
  w_ct=$(( ct_norm * 5  )); [ "$w_ct"   -lt 1000 ] && w_ct=1000       # WARN:  5x normal
  a_ct=$(( ct_norm * 10 )); [ "$a_ct"   -lt 5000 ] && a_ct=5000       # ATAQUE: 10x normal
  ct_lim=$(( ct_norm * 7 )); [ "$ct_lim" -lt 4000 ] && ct_lim=4000    # captura: 7x normal
  # SYN-flood GLOBAL (dst port): pico de logins simultaneos depende dos chars totais.
  # Estimativa: pico de logins ~= chars/2 por segundo (server reabrindo, evento etc.)
  syn_g_rate=$(( W_PEAK / 2 ));  [ "$syn_g_rate"  -lt 150 ] && syn_g_rate=150
  syn_g_burst=$(( syn_g_rate * 2 ))
  # SYN-flood POR IP (srcip): depende de chars_per_ip — 1 jogador pode logar varios chars do mesmo IP.
  # Rate sustentada: chars_per_ip * 10/min (reconnects normais).
  # Burst: chars_per_ip * 3 (margem p/ login em rajada de todos os chars de uma vez).
  syn_p_rate=$(( W_CHARS_PER_IP * 10 ));  [ "$syn_p_rate"  -lt 30 ] && syn_p_rate=30
  syn_p_burst=$(( W_CHARS_PER_IP * 3 ));  [ "$syn_p_burst" -lt 20 ] && syn_p_burst=20
  # cores do monitor (em /s, batendo com os limites reais):
  #  A_SYN_RECV = SGR  -> recv/s atingiu o teto da rate-limit (a partir daqui ja dropa)
  #  A_SYN      = SGR  -> drops/s sustained ~ SGR ja dispara SYN_LIMIT em 1 janela
  a_syn_recv=$syn_g_rate;  w_syn_recv=$(( a_syn_recv / 10 )); [ "$w_syn_recv" -lt 5 ] && w_syn_recv=5
  a_syn=$syn_g_rate;       w_syn=$(( a_syn / 10 ));           [ "$w_syn"      -lt 5 ] && w_syn=5
  # SYN_LIMIT (drops/janela 10s) = SGR sustentado por uma janela inteira => trigger
  syn_lim=$(( syn_g_rate * 10 ))
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
# guardado p/ futuras upgrades recalibrarem thresholds sem refazer o wizard
PEAK_PLAYERS=$W_PEAK
CHARS_PER_IP=$W_CHARS_PER_IP
# limites de SYN-flood (calculados a partir de PEAK_PLAYERS + CHARS_PER_IP)
SYN_GLOBAL_RATE=$syn_g_rate
SYN_GLOBAL_BURST=$syn_g_burst
SYN_PER_IP_RATE=$syn_p_rate
SYN_PER_IP_BURST=$syn_p_burst
# DATA-flood por IP (apos handshake): pega flood PSH/ACK que vaza por ESTABLISHED.
# Tibia legitimo: ~50 pps casual, bot "auto 1 xxx" em farm intenso pode atingir ~1000 pps.
# Burst em entrada de cidade/batalha: ate ~2000 pps por uns segundos.
# Acima de PKT_PER_IP_RATE sustentado = atacante: ban automatico no otguard_bl por BAN_SECS.
PKT_PER_IP_RATE=1500
PKT_PER_IP_BURST=2500
BAN_SECS=3600
# === SLOWREAD KILLER (otguard-slowread.service) — v2 janela rolante ===
SLOWREAD_INTERVAL=15
SLOWREAD_MIN_CONNS=8
SLOWREAD_TOTAL_SENDQ=800
# v2 elimina o bug do oscilador (v1 deletava seen ao perder hit): agora conta
# hits na janela. >= SLOWREAD_BAN_HITS dentro de SLOWREAD_HITS_WINDOW = ban.
SLOWREAD_HITS_WINDOW=1800
SLOWREAD_BAN_HITS=3
SLOWREAD_BAN_SECS=86400
SLOWREAD_LOG_ONLY=nao
# === SHADOW (otguard-shadow.service) — ShieldM-local via auth.log ===
# Requer hook em login.lua escrevendo em /var/log/otguard/auth.log
# (formato tab: ts ip name accid level voc os). Sem hook = daemon inerte.
SHADOW_INTERVAL=60
SHADOW_WINDOW=3600
SHADOW_A_IPS_PER_CHAR=5
SHADOW_A_HIGH_LVL=300
SHADOW_A_LOW_LVL=50
SHADOW_B_CHARS_PER_IP=5
SHADOW_B_LEVEL_MAX=20
SHADOW_SAFE_HIGH_LVL=50
SHADOW_DB_HIGH_LVL=100
SHADOW_BAN_SECS=86400
# === UNBAN (otguard-unban.service) — self-service via accountmanagement.php ===
# Player loga no site, ve seus IPs banidos, clica "solicitar desban" -> insere
# em otguard_unban_requests. Daemon polla a cada UNBAN_INTERVAL e processa.
# Rate limit por account previne abuso por bot.
UNBAN_INTERVAL=30
UNBAN_MAX_PER_HOUR=1
UNBAN_MAX_PER_DAY=5
# Caminho do config.lua do TFS (deixa vazio pra autodetectar /home/otserv/*/config.lua).
OTG_TFS_CONFIG=
# === PANIC MODE (otguard-live.sh) ===
PPS_PANIC=180000
PANIC_TRIGGER_SECS=3
PANIC_HOLD_SECS=15
PANIC_HYSTERESIS_PCT=50
# auto-lockdown quando watch dispara ataque: pausa novos logins por LOCKDOWN_SECS
# (players ESTABLISHED nao sao afetados — sobem pela regra ctstate ACCEPT)
AUTO_LOCKDOWN=sim
LOCKDOWN_SECS=300
# captura + alerta (watch.sh)
PPS_LIMIT=$pps_lim
CT_LIMIT=$ct_lim
SYN_LIMIT=$syn_lim
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
A_CT=$a_ct
W_CT=$w_ct
A_SYN=$a_syn
W_SYN=$w_syn
A_SYN_RECV=$a_syn_recv
W_SYN_RECV=$w_syn_recv
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
# Preserva estado do panic (se estava ativo) — flush apaga, vamos recriar abaixo
PANIC_WAS_ACTIVE=0
iptables -t raw -C PREROUTING -p tcp --syn -m multiport --dports "$PORTS_CSV" \
  -m comment --comment "otg_panic" -j DROP 2>/dev/null && PANIC_WAS_ACTIVE=1
iptables -t raw -F PREROUTING
# loopback sempre bypass: senao curl/healthcheck/self-call do nginx/php travam
iptables -t raw -A PREROUTING -i lo -j ACCEPT
# Counter de SYNs recebidos nas portas do jogo. Chain vazia: --jump cai nela,
# incrementa o contador da regra e volta (chain vazia -> RETURN implicito).
# Usado por otguard-live pra reportar SYN recv/s no monitor.
iptables -t raw -N otg_syn_recv 2>/dev/null || true
iptables -t raw -F otg_syn_recv
iptables -t raw -A PREROUTING -p tcp -m multiport --dports "$PORTS_CSV" --syn \
  -m comment --comment "otg_syn_recv" -j otg_syn_recv
# Se panic estava ativo antes do flush, restaurar (otguard-live vai eventualmente
# reativar tambem, mas evita janela de "descoberto").
[ "$PANIC_WAS_ACTIVE" = 1 ] && iptables -t raw -A PREROUTING -p tcp --syn \
  -m multiport --dports "$PORTS_CSV" -m comment --comment "otg_panic" -j DROP
# whitelist dinamica de players: marca IPs com conexao ESTABLISHED no recent list "otg_players"
# (timeout via xt_recent). Usado por otguard-lockdown pra nao dropar quem ja jogou recentemente.
# Idempotente: -C primeiro, so insere se nao existir.
TR="-p tcp -m multiport --dports $PORTS_CSV -m conntrack --ctstate ESTABLISHED -m recent --set --name otg_players --rsource"
iptables -t mangle -C PREROUTING $TR 2>/dev/null || iptables -t mangle -I PREROUTING 1 $TR
for a in $ADMIN_IPS; do
  [ -n "$a" ] && iptables -t raw -A PREROUTING -s "$a" -p tcp -m multiport --dports "$PORTS_CSV" -j ACCEPT
done
iptables -t raw -A PREROUTING -p tcp -m multiport --dports "$PORTS_CSV" -m set --match-set otguard_bl src -j DROP
iptables -t raw -A PREROUTING -p udp -m multiport --dports "$PORTS_CSV" -j DROP
# Anti-spoof: SYN com source port reservada (80/443/53/25/22) indo pras portas do jogo
# eh spoofing claro — portas <1024 sao reservadas pra servicos, nao pra clientes
# random gerando conexoes outbound. Esses ataques sao comuns com SPORT=80.
for SPF in 80 443 53 25 22 21 3306; do
  iptables -t raw -A PREROUTING -p tcp --sport "$SPF" --syn -m multiport --dports "$PORTS_CSV" -j DROP
done
# limites SYN — calculados em write_config a partir de PEAK_PLAYERS e CHARS_PER_IP
SGR=${SYN_GLOBAL_RATE:-150};  SGB=${SYN_GLOBAL_BURST:-300}
SPR=${SYN_PER_IP_RATE:-30};   SPB=${SYN_PER_IP_BURST:-40}
iptables -t raw -A PREROUTING -p tcp -m multiport --dports "$PORTS_CSV" --syn -m hashlimit \
  --hashlimit-name otg_g --hashlimit-mode dstport --hashlimit-above "${SGR}/sec" --hashlimit-burst "$SGB" \
  -m comment --comment "otg_syn_drop_global" -j DROP
iptables -t raw -A PREROUTING -p tcp -m multiport --dports "$PORTS_CSV" --syn -m hashlimit \
  --hashlimit-name otg_s --hashlimit-mode srcip --hashlimit-srcmask 32 --hashlimit-above "${SPR}/min" --hashlimit-burst "$SPB" \
  -m comment --comment "otg_syn_drop_perip" -j DROP
# data-flood por IP: IP que excede PKT_PER_IP_RATE pps -> auto-ban no otguard_bl por BAN_SECS.
# Proximos pacotes dele caem na regra DROP otguard_bl acima (O(1), antes do conntrack).
PPR=${PKT_PER_IP_RATE:-500}; PPB=${PKT_PER_IP_BURST:-1000}; BS=${BAN_SECS:-3600}
iptables -t raw -A PREROUTING -p tcp -m multiport --dports "$PORTS_CSV" -m hashlimit \
  --hashlimit-name otg_pkt --hashlimit-mode srcip --hashlimit-srcmask 32 \
  --hashlimit-above "${PPR}/sec" --hashlimit-burst "$PPB" \
  -j SET --add-set otguard_bl src --exist --timeout "$BS"
# e dropa o pacote atual que disparou (senao o primeiro "vaza" antes do bl pegar)
iptables -t raw -A PREROUTING -p tcp -m multiport --dports "$PORTS_CSV" -m hashlimit \
  --hashlimit-name otg_pkt2 --hashlimit-mode srcip --hashlimit-srcmask 32 \
  --hashlimit-above "${PPR}/sec" --hashlimit-burst "$PPB" -j DROP
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
  # IFS= e "|| [ -n "$n" ]" garantem ler a ULTIMA linha mesmo sem \n final (CF retorna sem)
  while IFS= read -r n || [ -n "$n" ]; do [ -n "$n" ] && ipset add -exist otguard_cf_new "$n"; done < "$tmp"
  ipset swap otguard_cf_new otguard_cf
  ipset destroy otguard_cf_new
  n4=$(ipset list otguard_cf 2>/dev/null | awk '/Number of entries/{print $4}')
  logger -t otguard-cf "ranges IPv4 da Cloudflare atualizados ($n4 ranges)"
else
  logger -t otguard-cf "FALHA ao baixar ranges IPv4 da Cloudflare"
fi
if curl -fsS -m 25 https://www.cloudflare.com/ips-v6 -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  ipset create -exist otguard_cf6 hash:net family inet6
  ipset create -exist otguard_cf6_new hash:net family inet6
  ipset flush otguard_cf6_new
  while IFS= read -r n || [ -n "$n" ]; do [ -n "$n" ] && ipset add -exist otguard_cf6_new "$n"; done < "$tmp"
  ipset swap otguard_cf6_new otguard_cf6
  ipset destroy otguard_cf6_new
  n6=$(ipset list otguard_cf6 2>/dev/null | awk '/Number of entries/{print $4}')
  logger -t otguard-cf "ranges IPv6 da Cloudflare atualizados ($n6 ranges)"
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
syn_now() { iptables -t raw -L PREROUTING -n -v -x 2>/dev/null | awk '/otg_syn_drop_global/{print $1; exit}'; }

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
  # auto-lockdown: pausa NOVAS conexoes em 7171/7172 durante o ataque
  # (players ja ESTABLISHED seguem normais pela regra ctstate ACCEPT)
  if [ "$AUTO_LOCKDOWN" = sim ] && [ -x /usr/local/sbin/otguard-lockdown ]; then
    /usr/local/sbin/otguard-lockdown on "${LOCKDOWN_SECS:-300}" >/dev/null 2>&1 \
      && logger -t otguard-watch "auto-lockdown ativado por ${LOCKDOWN_SECS:-300}s"
  fi
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
A_SYN_RECV=${A_SYN_RECV:-150}; W_SYN_RECV=${W_SYN_RECV:-15}
A_CT=${A_CT:-40000};   W_CT=${W_CT:-8000}
A_HO=${A_HO:-300};     W_HO=${W_HO:-50}
# --- PANIC: stop responding mode ---
PPS_PANIC=${PPS_PANIC:-180000}
PANIC_TRIGGER_SECS=${PANIC_TRIGGER_SECS:-3}
PANIC_HOLD_SECS=${PANIC_HOLD_SECS:-15}
PANIC_HYSTERESIS_PCT=${PANIC_HYSTERESIS_PCT:-50}
PANIC_LOW=$(( PPS_PANIC * PANIC_HYSTERESIS_PCT / 100 ))
mkdir -p "$(dirname "$LOG")"; : >> "$LOG"
syn_now() { iptables -w 2 -t raw -L PREROUTING -n -v -x 2>/dev/null | awk '/otg_syn_drop_global/{print $1; exit}'; }
syn_recv_now() { iptables -w 2 -t raw -L PREROUTING -n -v -x 2>/dev/null | awk '/otg_syn_recv/{print $1; exit}'; }
panic_active() { iptables -w 2 -t raw -C PREROUTING -p tcp --syn -m multiport --dports "${PORTS_CSV:-7171,7172}" -m comment --comment "otg_panic" -j DROP 2>/dev/null; }
panic_on()  { [ -x /usr/local/sbin/otguard-panic ] && /usr/local/sbin/otguard-panic on  >/dev/null 2>&1 && logger -t otguard-live "PANIC ATIVADO (pps>=$PPS_PANIC)"; }
panic_off() { [ -x /usr/local/sbin/otguard-panic ] && /usr/local/sbin/otguard-panic off >/dev/null 2>&1 && logger -t otguard-live "PANIC DESATIVADO (pps voltou a normal por ${PANIC_HOLD_SECS}s)"; }
p_prev=''; b_prev=''; s_prev=''; sr_prev=''; tick=0
high_count=0; low_count=0
while :; do
  p=$(cat "$RXP" 2>/dev/null || echo 0); b=$(cat "$RXB" 2>/dev/null || echo 0)
  s=$(syn_now); [ -z "$s" ] && s=0
  sr=$(syn_recv_now); [ -z "$sr" ] && sr=0
  ct=$(cat "$CT" 2>/dev/null || echo 0)
  ho=$(ss -H -tn state syn-recv 2>/dev/null | wc -l)
  pps=0; mbps=0; sd=0; srecv=0
  [ -n "$p_prev" ] && [ "$p" -ge "$p_prev" ] && pps=$(( (p - p_prev) / INTERVAL ))
  [ -n "$b_prev" ] && [ "$b" -ge "$b_prev" ] && mbps=$(( (b - b_prev) * 8 / 1000000 / INTERVAL ))
  [ -n "$s_prev" ] && [ "$s" -ge "$s_prev" ] && sd=$(( s - s_prev ))
  [ -n "$sr_prev" ] && [ "$sr" -ge "$sr_prev" ] && srecv=$(( sr - sr_prev ))
  p_prev=$p; b_prev=$b; s_prev=$s; sr_prev=$sr
  # --- PANIC: state machine ---
  # ON: pps >= PPS_PANIC por PANIC_TRIGGER_SECS amostras seguidas
  # OFF: pps <  PANIC_LOW por PANIC_HOLD_SECS amostras seguidas
  if panic_active; then
    if [ "$pps" -lt "$PANIC_LOW" ]; then
      low_count=$(( low_count + 1 ))
      if [ "$low_count" -ge "$PANIC_HOLD_SECS" ]; then
        panic_off; low_count=0; high_count=0
      fi
    else
      low_count=0
    fi
  else
    if [ "$pps" -ge "$PPS_PANIC" ]; then
      high_count=$(( high_count + 1 ))
      if [ "$high_count" -ge "$PANIC_TRIGGER_SECS" ]; then
        panic_on; high_count=0; low_count=0
      fi
    else
      high_count=0
    fi
  fi
  st=OK
  { [ "$pps" -ge "$W_PPS" ] || [ "$sd" -ge "$W_SYN" ] || [ "$ct" -ge "$W_CT" ] || [ "$ho" -ge "$W_HO" ]; } && st=ALERTA
  { [ "$pps" -ge "$A_PPS" ] || [ "$sd" -ge "$A_SYN" ] || [ "$ct" -ge "$A_CT" ] || [ "$ho" -ge "$A_HO" ]; } && st=ATAQUE
  panic_active && st="${st}+PANIC"
  printf '%-8s %10s %8s %11s %11s %11s %11s  %s\n' \
    "$(date +%H:%M:%S)" "$pps" "$mbps" "$ct" "$sd" "$srecv" "$ho" "$st" >> "$LOG"
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
# OTGuard — painel ao vivo + controles dinamicos
#
# Teclas:
#   [w] envia snapshot ao Discord       [q] sai
#   [p] toggle PANIC manual              [l] toggle LOCKDOWN manual
#   [s] toggle SLOWREAD_LOG_ONLY         [a] toggle AUTO_LOCKDOWN
#   [b] banlist (visualiza)              [u] unban (prompt IP)
#   [e] edit config (nano /etc/otguard/otguard.conf + reload)
#   [r] reload (reaplica otguard-mitigacao + restart daemons)
#   [5] auth-check (panel: padroes A/B + cobertura via auth.log)
#   [6] sweep full (audit 24h + cross-ban + alerta Discord agregado)
#
LOG=/var/log/otguard/live.log
CONF=/etc/otguard/otguard.conf
[ -f "$CONF" ] && . "$CONF"
A_PPS=${A_PPS:-60000}; W_PPS=${W_PPS:-25000}
A_SYN=${A_SYN:-400};   W_SYN=${W_SYN:-40}
A_SYN_RECV=${A_SYN_RECV:-150}; W_SYN_RECV=${W_SYN_RECV:-15}
A_CT=${A_CT:-40000};   W_CT=${W_CT:-8000}
A_HO=${A_HO:-300};     W_HO=${W_HO:-50}
IP=$(ip -4 -o addr show "${IFACE:-eth0}" 2>/dev/null | awk '{print $4}')
SPARK_N=50; peak=0; SENT=""; sent_at=-10
LAST_ACTION=""; action_at=-10
[ -t 0 ] && INTERACTIVE=1
BORD=$'\033[90m'; TITLE=$'\033[1;36m'; DIM=$'\033[2m'; SPK=$'\033[36m'
RST=$'\033[0m'; OK_C=$'\033[1;32m'; ALERT_C=$'\033[1;33m'; ERR_C=$'\033[1;31m'
cleanup() { printf '\033[?25h\033[0m\n'; exit 0; }
trap cleanup INT TERM
hrule() { _h=''; _n=$2; while [ "$_n" -gt 0 ]; do _h="$_h$1"; _n=$((_n-1)); done; printf '%s' "$_h"; }
bar() {
  bv=$1; bw=$2; ba=$3; bwidth=28
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
row() { printf '%b│%b  %s\033[K\033[78G%b│%b\n' "$BORD" "$RST" "$1" "$BORD" "$RST"; }

# ------- ESTADO DINAMICO -------
check_panic()   { iptables -w 2 -t raw -C PREROUTING -p tcp --syn -m multiport --dports "${PORTS_CSV:-7171,7172}" -m comment --comment "otg_panic" -j DROP 2>/dev/null && echo ATIVO || echo INATIVO; }
check_lockdwn() { iptables -w 2 -C ufw-before-input -p tcp -m multiport --dports "${PORTS_CSV:-7171,7172}" --syn -m recent ! --rcheck --seconds "${WHITELIST_SECS:-3600}" --name otg_players --rsource -m comment --comment "otguard-lockdown" -j DROP 2>/dev/null && echo ATIVO || echo INATIVO; }
get_slowread()  { . "$CONF" 2>/dev/null; if [ "$SLOWREAD_LOG_ONLY" = "sim" ]; then echo "LOG-ONLY"; else echo "BAN-AUTO"; fi; }
get_autolock()  { . "$CONF" 2>/dev/null; if [ "$AUTO_LOCKDOWN" = "sim" ]; then echo "ON"; else echo "OFF"; fi; }
check_prot() {
  rawp=$(iptables -w 2 -t raw -S PREROUTING 2>/dev/null)
  if [ -z "$rawp" ]; then prot="${DIM}(rode como root pra checar regras)${RST}"; return; fi
  case $rawp in *multiport*) fw="${OK_C}✓${RST}";; *) fw="${ERR_C}✗${RST}";; esac
  case $rawp in *otg_g*)     fl="${OK_C}✓${RST}";; *) fl="${ERR_C}✗${RST}";; esac
  bn=$(ipset list otguard_bl 2>/dev/null | awk '/Number of entries/{print $4}')
  if [ -n "$bn" ]; then bs="${OK_C}✓${RST} ${DIM}${bn} IPs${RST}"; else bs="${ERR_C}✗${RST}"; fi
  wn=$(wc -l < /proc/net/xt_recent/otg_players 2>/dev/null || echo 0)
  prot=$(printf 'firewall %b    anti-flood %b    blocklist %b    whitelist %b%d players%b' "$fw" "$fl" "$bs" "$DIM" "$wn" "$RST")
}
config_set() {
  # config_set KEY VALUE — substitui ou adiciona KEY=VALUE no CONF
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$CONF" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$CONF"
  else
    echo "${key}=${val}" >> "$CONF"
  fi
}
toast() { LAST_ACTION="$1"; action_at=$SECONDS; }

# ------- ACOES -------
send_snapshot() {
  local when js
  if [ -z "$DISCORD_WEBHOOK" ]; then toast "${ERR_C}✗ webhook nao configurado${RST}"; return; fi
  when=$(date '+%d/%m/%Y %H:%M:%S')
  js=$(printf '{"username":"OTGuard","embeds":[{"title":"📊 Snapshot do monitor","color":3447003,"fields":[{"name":"🎯 Servidor","value":"`%s`","inline":true},{"name":"🕐 Quando","value":"%s","inline":true},{"name":"Estado","value":"**%s**","inline":true},{"name":"📊 Agora","value":"pps **%s**  ·  banda **%s Mb/s**\\nct **%s**  ·  SYN drop **%s**  ·  HO **%s**","inline":false},{"name":"📈 Pico","value":"%s pps","inline":false}],"footer":{"text":"enviado manualmente"}}]}' \
    "${IP:-?}" "$when" "$est" "$pps" "$mbps" "$ct" "$syn" "$ho" "$peak")
  curl -fsS -m 15 -H 'Content-Type: application/json' -X POST -d "$js" "$DISCORD_WEBHOOK" >/dev/null 2>&1 \
    && toast "${OK_C}✓ snapshot enviado${RST}" || toast "${ERR_C}✗ falha ao enviar${RST}"
}
toggle_panic()    { if [ "$(check_panic)" = ATIVO ]; then /usr/local/sbin/otguard-panic off >/dev/null 2>&1; toast "${OK_C}panic OFF${RST}"; else /usr/local/sbin/otguard-panic on >/dev/null 2>&1; toast "${ERR_C}panic ON${RST}"; fi; }
toggle_lockdown() { if [ "$(check_lockdwn)" = ATIVO ]; then /usr/local/sbin/otguard-lockdown off >/dev/null 2>&1; toast "${OK_C}lockdown OFF${RST}"; else /usr/local/sbin/otguard-lockdown on 600 >/dev/null 2>&1; toast "${ALERT_C}lockdown ON (600s)${RST}"; fi; }
toggle_slowread() {
  . "$CONF" 2>/dev/null
  if [ "$SLOWREAD_LOG_ONLY" = "sim" ]; then
    config_set SLOWREAD_LOG_ONLY nao; toast "${ERR_C}slowread BAN-AUTO ativado${RST}"
  else
    config_set SLOWREAD_LOG_ONLY sim; toast "${OK_C}slowread LOG-ONLY ativado${RST}"
  fi
  systemctl restart otguard-slowread >/dev/null 2>&1
}
toggle_autolock() {
  . "$CONF" 2>/dev/null
  if [ "$AUTO_LOCKDOWN" = "sim" ]; then
    config_set AUTO_LOCKDOWN nao; toast "${ALERT_C}auto-lockdown OFF${RST}"
  else
    config_set AUTO_LOCKDOWN sim; toast "${OK_C}auto-lockdown ON${RST}"
  fi
}
banlist_show() {
  printf '\033[2J\033[H'
  echo "─── BANLIST (otguard_bl) ───"
  ipset list otguard_bl 2>&1 | awk '/^Members:/{p=1;next} p && NF{ip=$1; t=""; for(i=1;i<=NF;i++) if($i=="timeout") t=$(i+1); if(t==""||t==0) lbl="permanente"; else { h=int(t/3600); m=int((t%3600)/60); lbl=sprintf("%dh%02dm restante", h, m) } printf "  %-18s  %s\n", ip, lbl }'
  echo ""; read -p "[ENTER pra voltar] " _; printf '\033[2J'
}
unban_prompt() {
  printf '\033[2J\033[H'
  read -p "IP pra desbanir (vazio = cancela): " ip
  if [ -n "$ip" ]; then
    if ipset del otguard_bl "$ip" 2>/dev/null; then
      ipset save otguard_bl > /etc/otguard/blocklist.ipset 2>/dev/null
      toast "${OK_C}$ip desbanido${RST}"
    else
      toast "${ERR_C}$ip nao estava banido${RST}"
    fi
  fi
  printf '\033[2J'
}
edit_config() {
  cleanup_noexit() { printf '\033[?25h'; }
  cleanup_noexit
  ${EDITOR:-nano} "$CONF"
  /usr/local/sbin/otguard-mitigacao.sh >/dev/null 2>&1
  systemctl restart otguard-live otguard-slowread otguard-watch >/dev/null 2>&1
  printf '\033[?25l\033[2J'
  toast "${OK_C}config recarregada${RST}"
}
show_help() {
  local nbl nwl
  nbl=$(ipset list otguard_bl 2>/dev/null | awk '/Number of entries/{print $4}')
  nwl=$(wc -l < /proc/net/xt_recent/otg_players 2>/dev/null)
  printf '\033[?25l\033[2J\033[H\n'
  printf '  %bOTGuard — ajuda rapida%b\n' "$TITLE" "$RST"
  printf '  %b=======================================================%b\n\n' "$BORD" "$RST"

  printf '  %b[p] PANIC%b\n' "$TITLE" "$RST"
  printf '    Modo "fecha tudo". Ninguem novo entra no server.\n'
  printf '    Quem JA esta jogando continua normal — so os logins\n'
  printf '    NOVOS sao bloqueados. Liga sozinho quando o trafego\n'
  printf '    explode (sinal de ataque). Aperta [p] pra forcar.\n\n'

  printf '  %b[l] LOCKDOWN%b\n' "$TITLE" "$RST"
  printf '    Mais brando que panic: bloqueia logins novos, MAS\n'
  printf '    deixa passar quem ja jogou aqui na ultima hora\n'
  printf '    (esses ficam numa whitelist temporaria). Quem cai\n'
  printf '    consegue reconectar. Bom contra atacante novo que\n'
  printf '    nunca esteve aqui antes.\n\n'

  printf '  %b[s] SLOWREAD%b\n' "$TITLE" "$RST"
  printf '    Pega atacante "quieto": aquele que abre varias\n'
  printf '    conexoes e fica parado pra travar o server (igual\n'
  printf '    encher fila no Subway sem comprar nada). Hoje so\n'
  printf '    LOGA suspeitos (nao bane). Aperta [s] pra ele\n'
  printf '    BANIR sozinho da proxima.\n\n'

  printf '  %b[a] AUTO-LOCK%b\n' "$TITLE" "$RST"
  printf '    Liga/desliga o LOCKDOWN automatico. ON = o\n'
  printf '    sistema ativa lockdown sozinho quando detecta\n'
  printf '    ataque. OFF = so liga se VOCE apertar [l].\n\n'

  printf '  %b[b] BANLIST  [u] UNBAN%b\n' "$TITLE" "$RST"
  printf '    [b] mostra os IPs banidos (%s agora) com tempo\n' "$nbl"
  printf '    restante de cada um. [u] te pede um IP pra\n'
  printf '    desbanir (se um amigo tomou ban sem querer).\n\n'

  printf '  %bWHITELIST (automatica)%b\n' "$TITLE" "$RST"
  printf '    Toda vez que um jogador conecta, o IP dele entra\n'
  printf '    numa lista de "amigos" por 1 hora. Hoje tem %s\n' "$nwl"
  printf '    IPs ai. Eles tem passe livre no lockdown.\n\n'

  printf '  %b[e] EDIT CONF%b\n' "$TITLE" "$RST"
  printf '    Abre o arquivo de configuracoes pra editar\n'
  printf '    (limites, thresholds, etc). Quando voce salva e\n'
  printf '    sai, o sistema aplica tudo sozinho.\n\n'

  printf '  %b[r] RELOAD%b\n' "$TITLE" "$RST"
  printf '    Reaplica as configuracoes SEM abrir o editor.\n'
  printf '    Util se voce mexeu no arquivo de outra forma.\n\n'

  printf '  %b[5] AUTH-CHECK%b\n' "$TITLE" "$RST"
  printf '    Abre painel com auditoria do auth.log: quantos\n'
  printf '    logins reais autenticaram, cobertura vs conn ESTAB,\n'
  printf '    distribuicao de level (bot tipico fica em lvl 7-10),\n'
  printf '    padrao A (char usado de muitos IPs) e padrao B (IP\n'
  printf '    com muitos chars low-level). Janela 2h.\n\n'

  printf '  %b[6] SWEEP FULL%b\n' "$TITLE" "$RST"
  printf '    Audit 24h, lista candidatos, pede confirmacao e BANA\n'
  printf '    em massa todos os IPs casando Padrao A ou B (com\n'
  printf '    safety: skip se IP tem main lvl>=50 na janela).\n'
  printf '    Depois manda 1 alerta agregado no Discord.\n\n'

  printf '  %b[w] DISCORD  [q] sair%b\n' "$TITLE" "$RST"
  printf '    [w] manda um snapshot do painel pro seu Discord.\n'
  printf '    [q] fecha o monitor.\n\n'

  printf '  %b---%b\n' "$DIM" "$RST"
  printf '  %bResumo simples: %s%b\n' "$DIM" "PANIC > LOCKDOWN > SLOWREAD" "$RST"
  printf '  %b(do mais agressivo pro mais cirurgico)%b\n\n' "$DIM" "$RST"

  printf '  %b=======================================================%b\n' "$BORD" "$RST"
  printf '  %b[ENTER pra voltar ao monitor]%b\n\n' "$DIM" "$RST"
  read -r _ 2>/dev/null
  printf '\033[2J'
}
reload_all() {
  /usr/local/sbin/otguard-mitigacao.sh >/dev/null 2>&1
  systemctl restart otguard-live otguard-slowread otguard-watch otguard-shadow >/dev/null 2>&1
  toast "${OK_C}daemons reiniciados${RST}"
}

# [5] painel auth-check: roda otguard-auth-check 7200 e mostra inline
show_authcheck() {
  if ! command -v otguard-auth-check >/dev/null 2>&1; then
    toast "${ERR_C}otguard-auth-check nao instalado${RST}"
    return
  fi
  printf '\033[?25l\033[2J\033[H\n'
  printf '  %bOTGuard — Auth Check (janela 2h)%b\n' "$TITLE" "$RST"
  printf '  %b=======================================================%b\n\n' "$BORD" "$RST"
  otguard-auth-check 7200 2>&1
  printf '\n  %b=======================================================%b\n' "$BORD" "$RST"
  printf '  %b[ENTER pra voltar ao monitor]%b\n\n' "$DIM" "$RST"
  read -r _ 2>/dev/null
  printf '\033[2J'
}

# [6] sweep: audit 24h + lista candidatos + confirma + ban cruzado + Discord
run_sweep() {
  if [ ! -f /var/log/otguard/auth.log ]; then
    toast "${ERR_C}/var/log/otguard/auth.log nao existe${RST}"
    return
  fi
  printf '\033[?25l\033[2J\033[H\n'
  printf '  %bOTGuard — Sweep Full (janela 24h)%b\n' "$TITLE" "$RST"
  printf '  %b=======================================================%b\n\n' "$BORD" "$RST"

  local now cut tmp
  now=$(date +%s); cut=$(( now - 86400 ))
  tmp=$(mktemp -d); trap "rm -rf $tmp" RETURN

  awk -F'\t' -v cut="$cut" '$1>=cut{print $3"\t"$2"\t"$5+0}' /var/log/otguard/auth.log | sort -u | \
    awk -F'\t' '
      {cnt[$1]++; if($3+0>max[$1]) max[$1]=$3+0; ips[$1]=(ips[$1]?ips[$1]","$2:$2)}
      END{for(c in cnt) if(cnt[c]>=5) printf "%s\t%d\t%d\t%s\n", c, cnt[c], max[c], ips[c]}
    ' | sort -t$'\t' -k2 -rn > "$tmp/A"

  awk -F'\t' -v cut="$cut" '$1>=cut{print $2"\t"$3"\t"$4"\t"$5+0}' /var/log/otguard/auth.log | sort -u > "$tmp/Brows"
  awk -F'\t' '$4<=20{cnt[$1]++; chars[$1]=(chars[$1]?chars[$1]"|"$2:$2)} END{for(ip in cnt) if(cnt[ip]>=5) printf "%s\t%d\t%s\n", ip, cnt[ip], chars[ip]}' "$tmp/Brows" | \
  while IFS=$'\t' read -r ip n charlist; do
    has_high=$(awk -F'\t' -v ip="$ip" '$1==ip && $4>=50' "$tmp/Brows" | wc -l)
    [ "$has_high" -gt 0 ] && continue
    printf "%s\t%d\t%s\n" "$ip" "$n" "$charlist"
  done > "$tmp/B"

  na=$(wc -l < "$tmp/A"); nb=$(wc -l < "$tmp/B")
  printf '  %bPadrao A%b (char com 5+ IPs em 24h): %s candidatos\n' "$TITLE" "$RST" "$na"
  if [ "$na" -gt 0 ]; then
    awk -F'\t' '{printf "    %-30s lvl=%d  ips=%d\n", $1, $3, $2}' "$tmp/A" | head -15
    [ "$na" -gt 15 ] && printf '    %b...(+%d)%b\n' "$DIM" "$((na-15))" "$RST"
  fi
  printf '\n  %bPadrao B%b (IP com 5+ chars lvl<=20 sem main na janela): %s candidatos\n' "$TITLE" "$RST" "$nb"
  if [ "$nb" -gt 0 ]; then
    awk -F'\t' '{printf "    %-18s chars=%d\n", $1, $2}' "$tmp/B" | head -15
    [ "$nb" -gt 15 ] && printf '    %b...(+%d)%b\n' "$DIM" "$((nb-15))" "$RST"
  fi

  ips_to_ban=$( { awk -F'\t' '{n=split($4,a,",");for(i=1;i<=n;i++) print a[i]}' "$tmp/A"; awk -F'\t' '{print $1}' "$tmp/B"; } | sort -u | grep -E '^[0-9.]+$')
  total=$(printf '%s\n' "$ips_to_ban" | grep -c .)
  printf '\n  %bTotal de IPs unicos para banir: %d%b\n' "$TITLE" "$total" "$RST"

  if [ "$total" -eq 0 ]; then
    printf '\n  %bNada para banir.  [ENTER pra voltar]%b\n' "$DIM" "$RST"
    read -r _ 2>/dev/null
    printf '\033[2J'; return
  fi

  printf '\n  %bConfirma BAN de %d IPs + alerta Discord?  [y/N]:%b ' "$ALERT_C" "$total" "$RST"
  read -r ans
  if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
    toast "${DIM}sweep cancelado${RST}"
    printf '\033[2J'; return
  fi

  banned=0
  printf '%s\n' "$ips_to_ban" | while read -r ip; do
    [ -z "$ip" ] && continue
    if ! ipset test otguard_bl "$ip" 2>/dev/null; then
      ipset add -exist otguard_bl "$ip" timeout 86400 2>/dev/null
      ss -K dst "$ip" >/dev/null 2>&1 || true
      banned=$((banned+1))
    fi
  done
  ipset save otguard_bl > /etc/otguard/blocklist.ipset 2>/dev/null
  logger -t otguard-mon "sweep manual: $total IPs banidos (A=$na, B=$nb)"

  if [ -n "$DISCORD_WEBHOOK" ]; then
    body=$(printf 'Sweep manual via otguard mon\\n**Padrao A:** %d candidatos\\n**Padrao B:** %d candidatos\\n**IPs banidos:** %d (24h)' "$na" "$nb" "$total")
    payload=$(printf '{"username":"OTGuard Sweep","embeds":[{"title":"🧹 Sweep manual executado","description":"%s","color":15158332}]}' "$body")
    curl -s -m 5 -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
  fi
  toast "${OK_C}sweep: $total IPs banidos${RST}"
  printf '\033[2J'
}

# ------- LOG BOX -------
recent_log() {
  # ultimas 5 linhas RELEVANTES dos daemons (so as vindas via 'logger -t tag',
  # nao mensagens de systemd como "Started" / "Stopping").
  # SYSLOG_IDENTIFIER=otguard-* captura todos os tags do projeto.
  journalctl --no-pager -n 30 -o cat \
    SYSLOG_IDENTIFIER=otguard-mitigacao \
    SYSLOG_IDENTIFIER=otguard-watch \
    SYSLOG_IDENTIFIER=otguard-live \
    SYSLOG_IDENTIFIER=otguard-slowread \
    SYSLOG_IDENTIFIER=otguard-panic \
    SYSLOG_IDENTIFIER=otguard-lockdown \
    SYSLOG_IDENTIFIER=otguard-shadow \
    SYSLOG_IDENTIFIER=otguard-unban \
    SYSLOG_IDENTIFIER=otguard-mon \
    SYSLOG_IDENTIFIER=otguard-cf 2>/dev/null | \
    grep -vE '^(Started|Stopping|Stopped|Succeeded|Reloaded|signal process)' | \
    tail -5 | while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in
        *UNBAN*)                             c="\033[1;36m" ;;
        *ATIVADO*|*PANIC*|*ATAQUE*|*BANIDO*|*PADRAO_B:*|*PADRAO_A_LOW*) c="\033[1;31m" ;;
        *PADRAO_A_HIGH*|*PADRAO_A_MID*|*SKIP_safety*|*REJEITADO*|*suspeito*|*armado*|*CANDIDATO*) c="\033[1;33m" ;;
        *)                                   c="\033[0;37m" ;;
      esac
      printf "${c}%.72s${RST}\n" "$line"
    done
}

# ------- VERSAO -------
OTG_VER=__OTG_VER__
[ "$OTG_VER" = "__OTG_VER__" ] && OTG_VER=1.6
title="OTGuard v${OTG_VER} · monitor interativo"
dashes=$(( 73 - ${#title} )); [ "$dashes" -lt 4 ] && dashes=4
TOP=$(printf '%b┌─ %b%s %b%s┐%b' "$BORD" "$TITLE" "$title" "$BORD" "$(hrule ─ "$dashes")" "$RST")
SEP=$(printf '%b├%s┤%b' "$BORD" "$(hrule ─ 76)" "$RST")
BOT=$(printf '%b└%s┘%b' "$BORD" "$(hrule ─ 76)" "$RST")
printf '\033[2J\033[?25l'
ptick=0; check_prot
while :; do
  set -- $(tail -n 1 "$LOG" 2>/dev/null)
  # formato novo (8 cols): hora pps mbps ct syn_drop syn_recv ho est
  # formato antigo (7 cols): hora pps mbps ct syn_drop ho est — fallback automatico
  if [ $# -ge 8 ]; then
    hora=$1; pps=$2; mbps=$3; ct=$4; syn=$5; srecv=$6; ho=$7; est=$8
  else
    hora=$1; pps=$2; mbps=$3; ct=$4; syn=$5; srecv=0; ho=$6; est=$7
  fi
  case $pps in *[!0-9]*|'') pps=0;; esac
  case $srecv in *[!0-9]*|'') srecv=0;; esac
  case $mbps in *[!0-9]*|'') mbps=0;; esac
  [ "$pps" -gt "$peak" ] && peak=$pps
  # est pode vir "ATAQUE+PANIC"
  case "$est" in
    *ATAQUE*) badge='\033[1;5;37;41m  ATAQUE  \033[0m'; desc="$est";;
    *ALERTA*) badge='\033[1;30;43m  ALERTA  \033[0m'; desc="$est";;
    *)        badge='\033[1;30;42m    OK    \033[0m'; desc='trafego normal';;
  esac
  panic_st=$(check_panic); lock_st=$(check_lockdwn)
  slow_st=$(get_slowread); auto_st=$(get_autolock)
  spark=$(tail -n "$SPARK_N" "$LOG" 2>/dev/null | awk '
    { v[NR]=$2+0; if(NR==1||v[NR]<mn)mn=v[NR]; if(NR==1||v[NR]>mx)mx=v[NR] }
    END { b[0]="▁";b[1]="▂";b[2]="▃";b[3]="▄";b[4]="▅";b[5]="▆";b[6]="▇";b[7]="█"
          r=mx-mn; if(r<=0)r=1; s=""
          for(i=1;i<=NR;i++){ l=int((v[i]-mn)*7/r); if(l<0)l=0; if(l>7)l=7; s=s b[l] }
          print s }')
  ptick=$((ptick+1)); [ "$ptick" -ge 15 ] && { ptick=0; check_prot; }

  # Cor pros toggles
  [ "$panic_st" = ATIVO ]   && pcol="$ERR_C" || pcol="$DIM"
  [ "$lock_st"  = ATIVO ]   && lcol="$ALERT_C" || lcol="$DIM"
  [ "$slow_st"  = BAN-AUTO ] && scol="$ALERT_C" || scol="$OK_C"
  [ "$auto_st"  = ON ]      && acol="$OK_C" || acol="$DIM"

  printf '\033[H'
  printf '%s\033[K\n' "$TOP"
  row "$(printf '%b%-30s%36s%b' "$DIM" "${IP:-?}" "$(date '+%d/%m  %H:%M:%S')" "$RST")"
  row ''
  row "$(printf 'estado    %b   %b%s%b' "$badge" "$DIM" "$desc" "$RST")"
  row "$(printf 'protecao  %s' "$prot")"
  row ''
  row "$(printf '%-11s %s  %7s %b/ %s%b' 'pacotes/s'  "$(bar "$pps"  "$W_PPS"      "$A_PPS")"      "$pps"   "$DIM" "$A_PPS"      "$RST")"
  row "$(printf '%-11s %s  %7s %b/ %s%b' 'conntrack'  "$(bar "$ct"   "$W_CT"       "$A_CT")"       "$ct"    "$DIM" "$A_CT"       "$RST")"
  row "$(printf '%-11s %s  %7s %b/ %s%b' 'SYN recv/s' "$(bar "$srecv" "$W_SYN_RECV" "$A_SYN_RECV")" "$srecv" "$DIM" "$A_SYN_RECV" "$RST")"
  row "$(printf '%-11s %s  %7s %b/ %s%b' 'SYN drop/s' "$(bar "$syn"  "$W_SYN"      "$A_SYN")"      "$syn"   "$DIM" "$A_SYN"      "$RST")"
  row "$(printf '%-11s %s  %7s %b/ %s%b' 'half-open'  "$(bar "$ho"   "$W_HO"       "$A_HO")"       "$ho"    "$DIM" "$A_HO"       "$RST")"
  row "$(printf '%-11s %b%s%b' 'tendencia' "$SPK" "$spark" "$RST")"
  row ''
  printf '%s\033[K\n' "$SEP"
  row "$(printf '%bcontroles dinamicos%b' "$TITLE" "$RST")"
  row "$(printf '  panic      %b%-8s%b [p] toggle    %bauto via pps>=%s%b' "$pcol" "$panic_st" "$RST" "$DIM" "${PPS_PANIC:-180000}" "$RST")"
  row "$(printf '  lockdown   %b%-8s%b [l] toggle    %bxt_recent whitelist filtra%b' "$lcol" "$lock_st" "$RST" "$DIM" "$RST")"
  row "$(printf '  slowread   %b%-8s%b [s] toggle    %bbase: %s conn, %sB SQ, %ss%b' "$scol" "$slow_st" "$RST" "$DIM" "${SLOWREAD_MIN_CONNS:-10}" "${SLOWREAD_TOTAL_SENDQ:-800}" "${SLOWREAD_GRACE_SECS:-180}" "$RST")"
  row "$(printf '  auto-lock  %b%-8s%b [a] toggle    %bwatch dispara lockdown se ataque%b' "$acol" "$auto_st" "$RST" "$DIM" "$RST")"
  row ''
  printf '%s\033[K\n' "$SEP"
  row "$(printf '%blog ao vivo (5 ultimas)%b' "$TITLE" "$RST")"
  recent_log | while IFS= read -r line; do row "  $line"; done
  printf '%s\033[K\n' "$SEP"
  if [ -n "$LAST_ACTION" ] && [ $((SECONDS - action_at)) -lt 5 ]; then
    row "$LAST_ACTION"
  else
    row "$(printf '%b[w]%b discord  %b[p]%b panic  %b[l]%b lockdown  %b[s]%b slowread  %b[a]%b auto-lock' "$RST" "$DIM" "$RST" "$DIM" "$RST" "$DIM" "$RST" "$DIM" "$RST" "$DIM")"
    row "$(printf '%b[b]%b banlist  %b[u]%b unban  %b[e]%b edit  %b[r]%b reload  %b[5]%b auth-chk  %b[6]%b sweep  %b[h]%b ajuda  %b[q]%b sair' "$RST" "$DIM" "$RST" "$DIM" "$RST" "$DIM" "$RST" "$DIM" "$RST" "$DIM" "$RST" "$DIM" "$RST" "$DIM" "$RST" "$DIM")"
  fi
  printf '%s\033[K\n' "$BOT"
  printf '\033[J'
  if [ -n "$INTERACTIVE" ]; then
    if read -rsn1 -t 1 key; then
      case "$key" in
        w|W) [ $((SECONDS - sent_at)) -ge 5 ] && { send_snapshot; sent_at=$SECONDS; } ;;
        p|P) toggle_panic ;;
        l|L) toggle_lockdown ;;
        s|S) toggle_slowread ;;
        a|A) toggle_autolock ;;
        b|B) banlist_show ;;
        u|U) unban_prompt ;;
        e|E) edit_config ;;
        r|R) reload_all ;;
        5)   show_authcheck ;;
        6)   run_sweep ;;
        h|H|'?') show_help ;;
        q|Q) cleanup ;;
      esac
    fi
  else sleep 1; fi
done
OTG_MON
  cat > "$sd/otguard-lockdown" <<'OTG_LOCK'
#!/bin/bash
# otguard-lockdown — durante ataque, dropa SYN novos de IPs DESCONHECIDOS.
# IPs que tiveram conexao ESTABLISHED nas portas do jogo nos ultimos
# WHITELIST_SECS (default 3600s = 1h) estao no recent list "otg_players"
# e PASSAM normalmente. Conexoes ja ESTABLISHED tambem nao sao afetadas
# (regra "ctstate RELATED,ESTABLISHED -j ACCEPT" vem antes na chain).
#
# Auto-ban data-flood (raw PREROUTING) continua ativo: IP whitelisted que
# flodar +PKT_PER_IP_RATE pps cai no otguard_bl e e dropado mesmo assim.
#
# uso:
#   otguard-lockdown on [segundos]   liga (padrao 300s); auto-off via systemd-run
#   otguard-lockdown off             desliga
#   otguard-lockdown status          mostra estado + tamanho do whitelist

set -e
. /etc/otguard/otguard.conf 2>/dev/null
PORTS_CSV="${PORTS_CSV:-7171,7172}"
WHITELIST_SECS="${WHITELIST_SECS:-3600}"

CHAIN="ufw-before-input"
COMMENT="otguard-lockdown"
POS=7
AUTOFF_UNIT="otguard-lockdown-autoff.timer"

active() {
  iptables -C "$CHAIN" -p tcp -m multiport --dports "$PORTS_CSV" --syn \
    -m recent ! --rcheck --seconds "$WHITELIST_SECS" --name otg_players --rsource \
    -m comment --comment "$COMMENT" -j DROP 2>/dev/null
}

case "${1:-}" in
  on)
    DURATION="${2:-300}"
    if active; then
      echo "lockdown ja estava ATIVO"
    else
      iptables -I "$CHAIN" "$POS" -p tcp -m multiport --dports "$PORTS_CSV" --syn \
        -m recent ! --rcheck --seconds "$WHITELIST_SECS" --name otg_players --rsource \
        -m comment --comment "$COMMENT" -j DROP
      n=$(wc -l < /proc/net/xt_recent/otg_players 2>/dev/null || echo 0)
      logger -t otguard-lockdown "ATIVADO (duracao ${DURATION}s, whitelist=$n IPs em otg_players)"
      echo "lockdown ATIVO — SYN de IPs nunca vistos nos ultimos ${WHITELIST_SECS}s sao dropados"
      echo "whitelist atual: $n IPs (players com ESTAB recente)"
    fi
    systemctl stop "$AUTOFF_UNIT" 2>/dev/null || true
    systemd-run --quiet --on-active="${DURATION}s" \
      --unit="otguard-lockdown-autoff" \
      /usr/local/sbin/otguard-lockdown off >/dev/null
    echo "auto-desativa em ${DURATION}s (systemd timer: otguard-lockdown-autoff)"
    echo "para desativar antes: otguard-lockdown off"
    ;;
  off)
    if active; then
      iptables -D "$CHAIN" -p tcp -m multiport --dports "$PORTS_CSV" --syn \
        -m recent ! --rcheck --seconds "$WHITELIST_SECS" --name otg_players --rsource \
        -m comment --comment "$COMMENT" -j DROP
      logger -t otguard-lockdown "DESATIVADO"
      echo "lockdown DESATIVADO"
    else
      echo "lockdown ja estava inativo"
    fi
    systemctl stop "$AUTOFF_UNIT" 2>/dev/null || true
    ;;
  status)
    if active; then
      echo "ATIVO"
      iptables -L "$CHAIN" -n -v --line-numbers 2>/dev/null | grep -E "otguard-lockdown|^Chain" | head -3
      n=$(wc -l < /proc/net/xt_recent/otg_players 2>/dev/null || echo 0)
      echo "whitelist: $n IPs no otg_players (timeout ${WHITELIST_SECS}s)"
      systemctl list-timers otguard-lockdown-autoff --no-pager 2>/dev/null | head -3
    else
      echo "INATIVO"
      n=$(wc -l < /proc/net/xt_recent/otg_players 2>/dev/null || echo 0)
      echo "whitelist: $n IPs no otg_players (pre-marcados pra um eventual lockdown)"
    fi
    ;;
  *)
    echo "uso: $0 {on [segundos]|off|status}"
    echo "  on  — drop SYN novos de IPs fora do otg_players (default 300s, auto-off)"
    echo "  off — remove o lockdown"
    exit 1
    ;;
esac
OTG_LOCK

  cat > "$sd/otguard-panic" <<'OTG_PANIC'
#!/bin/bash
# otguard-panic — "stop responding" mode pra ataques globais.
#
# A regra: passou de PPS_PANIC pps total no eth0, o server PARA de responder
# QUALQUER SYN novo nas portas do jogo. NAO ha whitelist aqui — diferente
# do otguard-lockdown que deixa "IPs conhecidos" passarem, o panic DROPA
# TUDO em raw PREROUTING (antes do conntrack), entao o kernel nem chega
# a gerar SYN-ACK. ShieldM/scrubber upstream consegue identificar que
# nao estamos respondendo e dropa o flood antes da nossa banda.
#
# Conexoes ja ESTABLISHED nao sao afetadas (regra so casa --syn).
# Auto-acionado pelo otguard-live.sh quando pps > PPS_PANIC sustentado.
# Auto-removido quando pps cai e fica baixo por PANIC_HOLD_SECS.
#
# uso:
#   otguard-panic on        liga (drop SYN total em 7171/7172)
#   otguard-panic off       desliga
#   otguard-panic status    mostra estado

set -e
. /etc/otguard/otguard.conf 2>/dev/null
PORTS_CSV="${PORTS_CSV:-7171,7172}"
COMMENT="otg_panic"
# Posicao na raw PREROUTING: depois do bypass loopback+admin (1,2), antes
# da blocklist (3+). Garante drop mais barato possivel pra ataque.
POS=3

active() {
  iptables -t raw -C PREROUTING -p tcp --syn -m multiport --dports "$PORTS_CSV" \
    -m comment --comment "$COMMENT" -j DROP 2>/dev/null
}

case "${1:-}" in
  on)
    if active; then
      echo "panic ja estava ATIVO"
    else
      iptables -t raw -I PREROUTING "$POS" -p tcp --syn -m multiport --dports "$PORTS_CSV" \
        -m comment --comment "$COMMENT" -j DROP
      logger -t otguard-panic "ATIVADO — todo SYN novo em $PORTS_CSV sera dropado em raw PREROUTING (sem SYN-ACK)"
      echo "panic ATIVO — server nao responde mais novos SYN em $PORTS_CSV"
    fi
    ;;
  off)
    if active; then
      iptables -t raw -D PREROUTING -p tcp --syn -m multiport --dports "$PORTS_CSV" \
        -m comment --comment "$COMMENT" -j DROP
      logger -t otguard-panic "DESATIVADO"
      echo "panic DESATIVADO"
    else
      echo "panic ja estava inativo"
    fi
    ;;
  status)
    if active; then
      echo "ATIVO"
      iptables -t raw -L PREROUTING -n -v --line-numbers 2>/dev/null | grep -E "$COMMENT|^Chain" | head -3
    else
      echo "INATIVO"
    fi
    ;;
  *)
    echo "uso: $0 {on|off|status}"
    echo "  on  — drop TOTAL de SYN novo em $PORTS_CSV (mesmo IPs conhecidos)"
    echo "  off — remove o panic"
    exit 1
    ;;
esac
OTG_PANIC

  cat > "$sd/otguard-slowread" <<'OTG_SLOWREAD'
#!/bin/bash
# otguard-slowread v2 — detector de slowread per-IP com janela rolante.
#
# v1 bug: deletava seen.<ip> a cada scan em que o IP nao aparecia como
# suspeito. Atacante esperto contornava abrindo N conn, segurando ~30-45s
# (abaixo do GRACE de 60s), fechando tudo e repetindo. O timer resetava.
#
# v2: para cada scan em que o IP eh suspeito, append do timestamp em
# hits.<ip>. A cada ciclo poda entradas mais antigas que SLOWREAD_HITS_WINDOW.
# Se o numero de hits dentro da janela >= SLOWREAD_BAN_HITS, bane.
# Pega tanto sustentado quanto oscilador (3 reaparicoes em 30min = ban).
#
# Roda como daemon via systemd (otguard-slowread.service).

set -e
. /etc/otguard/otguard.conf 2>/dev/null
PORTS_CSV="${PORTS_CSV:-7171,7172}"
INTERVAL="${SLOWREAD_INTERVAL:-15}"
MIN_CONNS="${SLOWREAD_MIN_CONNS:-5}"
TOTAL_SENDQ="${SLOWREAD_TOTAL_SENDQ:-300}"
WINDOW="${SLOWREAD_HITS_WINDOW:-1800}"
BAN_HITS="${SLOWREAD_BAN_HITS:-3}"
BAN_SECS="${SLOWREAD_BAN_SECS:-${BAN_SECS:-86400}}"
LOG_ONLY="${SLOWREAD_LOG_ONLY:-nao}"

STATE_DIR=/run/otguard/slowread
mkdir -p "$STATE_DIR"

pred=""
IFS=','
for p in $PORTS_CSV; do
  [ -n "$pred" ] && pred="$pred or "
  pred="${pred}sport = :$p"
done
unset IFS
PORTS_PRED="( $pred )"

if [ "$LOG_ONLY" = "sim" ]; then
  logger -t otguard-slowread "armado v2 (janela rolante) MODO LOG-ONLY: >=${MIN_CONNS} conn + Send-Q total >=${TOTAL_SENDQ}B; ${BAN_HITS} hits/${WINDOW}s -> CANDIDATO"
else
  logger -t otguard-slowread "armado v2 (janela rolante): >=${MIN_CONNS} conn + Send-Q total >=${TOTAL_SENDQ}B; ${BAN_HITS} hits/${WINDOW}s -> ban ${BAN_SECS}s"
fi

while :; do
  NOW=$(date +%s)
  CUTOFF=$(( NOW - WINDOW ))

  ss -tnH state established "$PORTS_PRED" 2>/dev/null | \
    awk -v minc="$MIN_CONNS" -v mins="$TOTAL_SENDQ" '
      {
        peer = $4;
        n = split(peer, a, ":");
        ip = a[1];
        for (i = 2; i < n; i++) ip = ip ":" a[i];
        sumq[ip] += $2 + 0;
        cnt[ip]++;
      }
      END {
        for (ip in cnt) {
          if (cnt[ip] >= minc && sumq[ip] >= mins) {
            printf "%s %d %d\n", ip, cnt[ip], sumq[ip];
          }
        }
      }' > "$STATE_DIR/current"

  while IFS=' ' read -r ip conns sumq; do
    [ -z "$ip" ] && continue
    # Skip whitelist do conf (ADMIN_IPS, lista separada por espaco)
    case " $ADMIN_IPS " in *" $ip "*) continue ;; esac
    ipset test otguard_bl "$ip" 2>/dev/null && continue

    f="$STATE_DIR/hits.$ip"
    echo "$NOW $conns $sumq" >> "$f"
    hits=$(awk -v cut="$CUTOFF" '$1 >= cut { n++ } END { print n+0 }' "$f")

    if [ "$hits" -ge "$BAN_HITS" ]; then
      if [ "$LOG_ONLY" = "sim" ]; then
        logger -t otguard-slowread "CANDIDATO-A-BAN $ip — ${hits} hits/${WINDOW}s (atual: ${conns} conn, ${sumq}B) [LOG-ONLY]"
      else
        ipset add -exist otguard_bl "$ip" timeout "$BAN_SECS" 2>/dev/null
        ipset save otguard_bl > /etc/otguard/blocklist.ipset 2>/dev/null
        ss -K dst "$ip" >/dev/null 2>&1 || true
        logger -t otguard-slowread "BANIDO $ip — slowread ciclico: ${hits} hits em ${WINDOW}s (atual: ${conns} conn, ${sumq}B Send-Q)"
        rm -f "$f"
      fi
    elif [ "$hits" -eq 1 ]; then
      logger -t otguard-slowread "suspeito $ip (${conns} conn, Send-Q total ${sumq}B) — 1/${BAN_HITS} hits, janela ${WINDOW}s"
    else
      logger -t otguard-slowread "suspeito $ip (${conns} conn, Send-Q total ${sumq}B) — ${hits}/${BAN_HITS} hits"
    fi
  done < "$STATE_DIR/current"

  for f in "$STATE_DIR"/hits.*; do
    [ -e "$f" ] || continue
    awk -v cut="$CUTOFF" '$1 >= cut' "$f" > "$f.tmp" 2>/dev/null
    if [ -s "$f.tmp" ]; then
      mv -f "$f.tmp" "$f"
    else
      rm -f "$f.tmp" "$f"
    fi
  done

  sleep "$INTERVAL"
done
OTG_SLOWREAD

  cat > "$sd/otguard-shadow" <<'OTG_SHADOW'
#!/bin/bash
# otguard-shadow — ShieldM local: detector de padroes de attack via auth.log
#
# Le /var/log/otguard/auth.log (alimentado por hook em login.lua do TFS)
# a cada SHADOW_INTERVAL e detecta:
#
# PADRAO A — char usado de muitos IPs (botnet usando 1 conta de acesso):
#   - char autenticando de >= SHADOW_A_IPS_PER_CHAR IPs distintos / janela
#   - Escala por level:
#       lvl >= A_HIGH_LVL  : alerta amarelo Discord (NAO bane)
#       lvl A_LOW..A_HIGH  : alerta amarelo (NAO bane sem confirm)
#       lvl <  A_LOW_LVL   : BAN automatico de todos os IPs
#
# PADRAO B — IP com varios chars low-level (botnet stuffing throwaway):
#   - IP com >= SHADOW_B_CHARS_PER_IP chars lvl <= SHADOW_B_LEVEL_MAX
#   - SAFETY 1: mesmo IP tem char lvl >= SAFE_HIGH_LVL na janela? -> SKIP (casa MC legit)
#   - SAFETY 2: alguma account envolvida tem char lvl >= DB_HIGH_LVL no DB? -> SKIP + alerta
#   - Caso contrario: BAN o IP
#
# Alertas Discord usam DISCORD_WEBHOOK do otguard.conf.
# DB queries usam sqlPass de /home/otserv/*/config.lua (configuravel via OTG_TFS_DIR).

set -u
. /etc/otguard/otguard.conf 2>/dev/null

AUTH_LOG=/var/log/otguard/auth.log
STATE_DIR=/run/otguard/shadow

WINDOW="${SHADOW_WINDOW:-3600}"
A_IPS="${SHADOW_A_IPS_PER_CHAR:-5}"
A_HIGH_LVL="${SHADOW_A_HIGH_LVL:-300}"
A_LOW_LVL="${SHADOW_A_LOW_LVL:-50}"
B_CHARS="${SHADOW_B_CHARS_PER_IP:-5}"
B_LVL_MAX="${SHADOW_B_LEVEL_MAX:-20}"
SAFE_HIGH_LVL="${SHADOW_SAFE_HIGH_LVL:-50}"
DB_HIGH_LVL="${SHADOW_DB_HIGH_LVL:-100}"
INTERVAL="${SHADOW_INTERVAL:-60}"
BAN_SECS="${SHADOW_BAN_SECS:-86400}"
DISCORD="${DISCORD_WEBHOOK:-}"

# Encontra config.lua do TFS (default: 1o em /home/otserv/*/config.lua)
TFS_CFG="${OTG_TFS_CONFIG:-}"
[ -z "$TFS_CFG" ] && TFS_CFG=$(ls /home/otserv/*/config.lua 2>/dev/null | head -1)
DBPASS=""; DBNAME=""
if [ -n "$TFS_CFG" ] && [ -f "$TFS_CFG" ]; then
  DBPASS=$(grep -E "^[[:space:]]*sqlPass" "$TFS_CFG" 2>/dev/null | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
  DBNAME=$(grep -E "^[[:space:]]*sqlDatabase" "$TFS_CFG" 2>/dev/null | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
fi

mkdir -p "$STATE_DIR"
touch "$STATE_DIR/alerted_chars" "$STATE_DIR/alerted_ips"
chmod 600 "$STATE_DIR/alerted_chars" "$STATE_DIR/alerted_ips"

logger -t otguard-shadow "armado: A>=${A_IPS}IPs/char (low<${A_LOW_LVL}=ban, ${A_LOW_LVL}-${A_HIGH_LVL}=alerta, >=${A_HIGH_LVL}=alerta); B>=${B_CHARS}chars(lvl<=${B_LVL_MAX})/IP com safety(main lvl>=${SAFE_HIGH_LVL} | DB lvl>=${DB_HIGH_LVL}); scan=${INTERVAL}s"

send_discord() {
  local title="$1" desc="$2" color="${3:-15158332}"
  [ -z "$DISCORD" ] && return 0
  local payload
  payload=$(printf '{"username":"OTGuard Shadow","embeds":[{"title":%s,"description":%s,"color":%d}]}' \
    "$(printf '%s' "$title" | jq -Rs . 2>/dev/null || printf '"%s"' "$title")" \
    "$(printf '%s' "$desc"  | jq -Rs . 2>/dev/null || printf '"%s"' "$desc")" \
    "$color")
  curl -s -m 5 -H "Content-Type: application/json" -d "$payload" "$DISCORD" >/dev/null 2>&1 || true
}

ban_ip_silent() {
  local ip="$1" reason="$2"
  ipset test otguard_bl "$ip" 2>/dev/null && return 0
  ipset add -exist otguard_bl "$ip" timeout "$BAN_SECS" 2>/dev/null
  ipset save otguard_bl > /etc/otguard/blocklist.ipset 2>/dev/null
  ss -K dst "$ip" >/dev/null 2>&1 || true
  logger -t otguard-shadow "BANIDO $ip — $reason"
}

# fail-safe: erro de DB ou ausencia retorna "tem main" (skip ban)
account_has_high_lvl() {
  local accid="$1" min_lvl="${2:-$DB_HIGH_LVL}"
  [ -z "$DBPASS" ] && return 0
  local n
  n=$(mysql -u root -p"$DBPASS" "$DBNAME" -Nse "SELECT COUNT(*) FROM players WHERE account_id=$accid AND level>=$min_lvl" 2>/dev/null)
  if [ -z "$n" ]; then
    logger -t otguard-shadow "WARN: db query failed pra acc=$accid — assumindo legit (fail-safe)"
    return 0
  fi
  [ "$n" -gt 0 ]
}

scan_pattern_A() {
  local now="$1"
  local cut=$(( now - WINDOW ))

  awk -F'\t' -v cut="$cut" '$1 >= cut {print $3 "\t" $2 "\t" $5+0}' "$AUTH_LOG" | sort -u > "$STATE_DIR/a_rows.tmp"

  awk -F'\t' '
    { cnt[$1]++; if($3+0>(max[$1]+0)) max[$1]=$3+0; ips[$1]=(ips[$1]?ips[$1]","$2:$2) }
    END { for(c in cnt) if(cnt[c]>='"$A_IPS"') printf "%s\t%d\t%d\t%s\n", c, cnt[c], max[c], ips[c] }
  ' "$STATE_DIR/a_rows.tmp" | \
  while IFS=$'\t' read -r char n maxlvl iplist; do
    grep -qFx "$char" "$STATE_DIR/alerted_chars" && continue
    echo "$char" >> "$STATE_DIR/alerted_chars"

    if [ "$maxlvl" -ge "$A_HIGH_LVL" ]; then
      logger -t otguard-shadow "PADRAO_A_HIGH: char=\"$char\" lvl=$maxlvl logou de $n IPs — alerta, NAO bane"
      send_discord "⚠️ Char veterano com IP rotativo" "**Char:** $char (lvl $maxlvl)\\n**IPs:** $n distintos em ${WINDOW}s\\n$iplist\\n_NAO banido — revisar se conta roubada_" 16776960
    elif [ "$maxlvl" -ge "$A_LOW_LVL" ]; then
      logger -t otguard-shadow "PADRAO_A_MID: char=\"$char\" lvl=$maxlvl logou de $n IPs — alerta, requer confirm"
      send_discord "⚠️ Padrão A mid-level (precisa review)" "**Char:** $char (lvl $maxlvl)\\n**IPs:** $n distintos\\n$iplist\\n_NAO banido sem confirmacao_" 16776960
    else
      logger -t otguard-shadow "PADRAO_A_LOW: char=\"$char\" lvl=$maxlvl logou de $n IPs — banindo todos"
      send_discord "🚫 Padrão A (low-level): ban automático" "**Char:** $char (lvl $maxlvl)\\n**IPs banidos:** $n\\n$iplist" 15158332
      IFS=',' read -ra arr <<< "$iplist"
      for ip in "${arr[@]}"; do
        [ -n "$ip" ] && ban_ip_silent "$ip" "padrao A: char $char lvl=$maxlvl usou $n IPs"
      done
    fi
  done
}

scan_pattern_B() {
  local now="$1"
  local cut=$(( now - WINDOW ))

  awk -F'\t' -v cut="$cut" '$1 >= cut {print $2 "\t" $3 "\t" $4 "\t" $5+0}' "$AUTH_LOG" | sort -u > "$STATE_DIR/b_rows.tmp"

  awk -F'\t' -v maxlvl="$B_LVL_MAX" '
    $4+0 <= maxlvl {
      cnt[$1]++;
      seen_acc[$1","$3]=1;
      chars[$1] = (chars[$1] ? chars[$1] "|" $2 : $2)
    }
    END {
      for(ip in cnt) if(cnt[ip] >= '"$B_CHARS"') {
        accs = "";
        for(k in seen_acc) {
          split(k, a, ",");
          if(a[1]==ip) accs = (accs ? accs "," a[2] : a[2]);
        }
        printf "%s\t%d\t%s\t%s\n", ip, cnt[ip], accs, chars[ip]
      }
    }
  ' "$STATE_DIR/b_rows.tmp" | \
  while IFS=$'\t' read -r ip n acclist charlist; do
    grep -qFx "$ip" "$STATE_DIR/alerted_ips" && continue

    local has_high
    has_high=$(awk -F'\t' -v ip="$ip" -v safe="$SAFE_HIGH_LVL" 'BEGIN{n=0} $1==ip && $4+0>=safe {n++} END{print n}' "$STATE_DIR/b_rows.tmp")
    if [ "${has_high:-0}" -gt 0 ]; then
      logger -t otguard-shadow "PADRAO_B_SKIP_safety1: ip=$ip tem $n chars low + $has_high char(s) lvl>=$SAFE_HIGH_LVL (casa MC) — NAO bane"
      echo "$ip" >> "$STATE_DIR/alerted_ips"
      continue
    fi

    local legit_acc=""
    IFS=',' read -ra accs_arr <<< "$acclist"
    for acc in "${accs_arr[@]}"; do
      [ -z "$acc" ] && continue
      if account_has_high_lvl "$acc" "$DB_HIGH_LVL"; then
        legit_acc="$acc"
        break
      fi
    done

    if [ -n "$legit_acc" ]; then
      logger -t otguard-shadow "PADRAO_B_SKIP_safety2: ip=$ip mas acc $legit_acc tem char lvl>=$DB_HIGH_LVL no DB — NAO bane"
      send_discord "🟨 Padrão B com main no DB (não banido)" "IP \`$ip\` com $n chars low-level.\\n**Account** \`$legit_acc\` tem char lvl>=$DB_HIGH_LVL no DB.\\n_Pode ser farmer legit ou conta comprometida._" 16776960
      echo "$ip" >> "$STATE_DIR/alerted_ips"
      continue
    fi

    echo "$ip" >> "$STATE_DIR/alerted_ips"
    logger -t otguard-shadow "PADRAO_B: ip=$ip teve $n chars low-level (accs=$acclist) sem main — BAN"
    send_discord "🚫 Padrão B: ban automático" "**IP:** \`$ip\`\\n**Chars low-level:** $n\\n**Chars:** $charlist\\n**Accounts:** $acclist\\n_Nenhuma com main detectado_" 15158332
    ban_ip_silent "$ip" "padrao B: $n chars lvl<=$B_LVL_MAX accs=$acclist"
  done
}

while :; do
  NOW=$(date +%s)
  if [ -f "$AUTH_LOG" ]; then
    scan_pattern_A "$NOW"
    scan_pattern_B "$NOW"
  fi
  sleep "$INTERVAL"
done
OTG_SHADOW

  cat > "$bd/otguard-auth-check" <<'OTG_AUTHCHECK'
#!/bin/bash
# otguard-auth-check — analisa /var/log/otguard/auth.log e cruza com conn ESTAB.
# Schema auth.log (tab-separated): ts ip name accid level voc os
#
# Uso: otguard-auth-check [janela_secs]   default 1800 (30min)

set -e
. /etc/otguard/otguard.conf 2>/dev/null
PORTS_CSV="${PORTS_CSV:-7171,7172}"
AUTH_LOG=/var/log/otguard/auth.log
WINDOW="${1:-1800}"
LOWLVL_MAX="${2:-20}"
MIN_IPS_PER_CHAR=3
MIN_CHARS_PER_IP=3

[ -f "$AUTH_LOG" ] || { echo "ERRO: $AUTH_LOG nao existe"; exit 1; }

NOW=$(date +%s)
CUT=$(( NOW - WINDOW ))

pred=""
IFS=','; for p in $PORTS_CSV; do
  [ -n "$pred" ] && pred="$pred or "
  pred="${pred}sport = :$p"
done; unset IFS
PORTS_PRED="( $pred )"

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

awk -F'\t' -v cut="$CUT" '$1 >= cut {print}' "$AUTH_LOG" > "$TMP/auth_window"
N_LOGINS=$(wc -l < "$TMP/auth_window")

awk -F'\t' '{print $2}' "$TMP/auth_window" | sort -u > "$TMP/auth_ips"
N_AUTH_IPS=$(wc -l < "$TMP/auth_ips")

ss -tnH state established "$PORTS_PRED" 2>/dev/null | \
  awk '{n=split($4,a,":"); ip=a[1]; for(i=2;i<n;i++) ip=ip":"a[i]; print ip}' | \
  sort -u > "$TMP/conn_ips"
N_CONN=$(wc -l < "$TMP/conn_ips")

comm -23 "$TMP/conn_ips" "$TMP/auth_ips" > "$TMP/suspect_ips"
N_SUSPECT=$(wc -l < "$TMP/suspect_ips")

comm -12 "$TMP/conn_ips" "$TMP/auth_ips" > "$TMP/legit_ips"
N_LEGIT=$(wc -l < "$TMP/legit_ips")

echo "============================================================"
echo "OTGuard Auth-Check  janela=${WINDOW}s  low_lvl=<=${LOWLVL_MAX}"
echo "============================================================"
printf "Logins na janela        : %d\n" "$N_LOGINS"
printf "IPs unicos autenticados : %d\n" "$N_AUTH_IPS"
printf "IPs com conn ESTAB agora: %d\n" "$N_CONN"
printf "Legit (auth + conn)     : %d\n" "$N_LEGIT"
printf "Suspeitos (conn s/ auth): %d\n" "$N_SUSPECT"
pct=0; [ "$N_CONN" -gt 0 ] && pct=$(( N_LEGIT * 100 / N_CONN ))
printf "Cobertura auth/conn     : %d%%\n" "$pct"

echo
echo "=== Distribuicao de level (logins na janela) ==="
awk -F'\t' '{
  lvl=$5+0;
  if(lvl<=10) c1++;
  else if(lvl<=30) c2++;
  else if(lvl<=100) c3++;
  else if(lvl<=300) c4++;
  else c5++;
  tot++
} END {
  if(tot==0){print "(sem dados)"; exit}
  printf "  lvl 1-10  : %d (%d%%)  <- bot/farmar IP\n", c1, c1*100/tot
  printf "  lvl 11-30 : %d (%d%%)\n", c2, c2*100/tot
  printf "  lvl 31-100: %d (%d%%)\n", c3, c3*100/tot
  printf "  lvl 101-300:%d (%d%%)\n", c4, c4*100/tot
  printf "  lvl 300+  : %d (%d%%)\n", c5, c5*100/tot
}' "$TMP/auth_window"

echo
echo "=== Distribuicao de OS do client (logins na janela) ==="
awk -F'\t' '{print $7}' "$TMP/auth_window" | sort | uniq -c | sort -rn | \
  awk '{
    os=$2+0;
    name="?"
    if(os==0)name="WIN_TIBIA"
    else if(os==1)name="GTK"
    else if(os==2)name="OSX"
    else if(os==10)name="OTCLIENT_LIN"
    else if(os==11)name="OTCLIENT_WIN"
    else if(os==12)name="OTCLIENT_MAC"
    else if(os==20)name="OTCLIENT_AND"
    else if(os>=100)name="CUSTOM/SUSPEITO"
    printf "  %-20s code=%d  count=%d\n", name, os, $1
  }'

echo
echo "=== PADRAO A: chars com >=${MIN_IPS_PER_CHAR} IPs distintos ==="
awk -F'\t' '{print $3"\t"$2}' "$TMP/auth_window" | sort -u | \
  awk -F'\t' '{cnt[$1]++} END{for(c in cnt) if(cnt[c]>='"$MIN_IPS_PER_CHAR"') print cnt[c]"\t"c}' | \
  sort -rn | head -20 | awk -F'\t' '{printf "  %3d IPs   char=\"%s\"\n", $1, $2}'

echo
echo "=== PADRAO B: IPs com >=${MIN_CHARS_PER_IP} chars distintos ==="
awk -F'\t' '{print $2"\t"$3"\t"$5}' "$TMP/auth_window" | sort -u | \
  awk -F'\t' '
    {chars[$1]++; lvls[$1]+=$3; minlvl[$1]=(minlvl[$1]==""||$3<minlvl[$1])?$3:minlvl[$1]; maxlvl[$1]=(maxlvl[$1]==""||$3>maxlvl[$1])?$3:maxlvl[$1]}
    END {
      for(ip in chars) if(chars[ip]>='"$MIN_CHARS_PER_IP"')
        printf "%d\t%s\tchars=%d  lvls=%d..%d  avg=%.0f\n", chars[ip], ip, chars[ip], minlvl[ip], maxlvl[ip], lvls[ip]/chars[ip]
    }' | sort -rn | head -20 | awk -F'\t' '{print "  "$2"  "$3}'

echo
echo "=== TOP 15 SUSPEITOS (conn ESTAB sem auth na janela) ==="
[ -s "$TMP/suspect_ips" ] && while read ip; do
  nconn=$(ss -tnH state established "$PORTS_PRED" 2>/dev/null | \
    awk -v ip="$ip" '{n=split($4,a,":"); pip=a[1]; for(i=2;i<n;i++) pip=pip":"a[i]; if(pip==ip) c++} END{print c+0}')
  printf "%d\t%s\n" "$nconn" "$ip"
done < "$TMP/suspect_ips" | sort -rn | head -15 | awk -F'\t' '{printf "  %s  %d conn\n", $2, $1}'

echo
echo "(rode com janela maior pra mais sinal: otguard-auth-check 7200)"
OTG_AUTHCHECK

  cat > "$sd/otguard-unban-watcher" <<'OTG_UNBAN'
#!/bin/bash
# otguard-unban-watcher — processa pedidos self-service de desban via DB.
#
# Pollagem da tabela otguard_unban_requests onde status='pending'.
# Pro cada pedido valido:
#   - rate limit: max UNBAN_MAX_PER_HOUR/h e _PER_DAY/dia por account
#   - IP precisa estar atualmente no otguard_bl
#   - aceita: ipset del + status=done + log + Discord
#   - rejeita: status=rejected + reason
#
# Asimetria contra atacante: legit loga no site (auth com conta valida) e
# clica unban. Atacante teria que fazer isso por IP — escala impossivel
# pra botnet de centenas de IPs.

set -u
. /etc/otguard/otguard.conf 2>/dev/null

INTERVAL="${UNBAN_INTERVAL:-30}"
MAX_PER_HOUR="${UNBAN_MAX_PER_HOUR:-1}"
MAX_PER_DAY="${UNBAN_MAX_PER_DAY:-5}"
DISCORD="${DISCORD_WEBHOOK:-}"

TFS_CFG="${OTG_TFS_CONFIG:-}"
[ -z "$TFS_CFG" ] && TFS_CFG=$(ls /home/otserv/*/config.lua 2>/dev/null | head -1)
DBPASS=""; DBNAME=""
if [ -n "$TFS_CFG" ] && [ -f "$TFS_CFG" ]; then
  DBPASS=$(grep -E "^[[:space:]]*sqlPass" "$TFS_CFG" 2>/dev/null | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
  DBNAME=$(grep -E "^[[:space:]]*sqlDatabase" "$TFS_CFG" 2>/dev/null | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
fi

if [ -z "$DBPASS" ] || [ -z "$DBNAME" ]; then
  logger -t otguard-unban "ERRO: sem credenciais DB (config.lua nao encontrado)"
  exit 1
fi

logger -t otguard-unban "armado: poll ${INTERVAL}s, rate=${MAX_PER_HOUR}/h ${MAX_PER_DAY}/dia por account"

send_discord() {
  local title="$1" desc="$2" color="${3:-3066993}"
  [ -z "$DISCORD" ] && return 0
  local payload
  payload=$(printf '{"username":"OTGuard Unban","embeds":[{"title":%s,"description":%s,"color":%d}]}' \
    "$(printf '%s' "$title" | jq -Rs . 2>/dev/null || printf '"%s"' "$title")" \
    "$(printf '%s' "$desc"  | jq -Rs . 2>/dev/null || printf '"%s"' "$desc")" \
    "$color")
  curl -s -m 5 -H "Content-Type: application/json" -d "$payload" "$DISCORD" >/dev/null 2>&1 || true
}

mysql_q() {
  mysql -u root -p"$DBPASS" "$DBNAME" -Nse "$1" 2>/dev/null
}
mysql_x() {
  mysql -u root -p"$DBPASS" "$DBNAME" -e "$1" 2>/dev/null
}

reject() {
  local id="$1" reason="$2"
  mysql_x "UPDATE otguard_unban_requests SET status='rejected', reason='$(printf '%s' "$reason" | sed "s/'/''/g")', processed_at=UNIX_TIMESTAMP() WHERE id=$id"
  logger -t otguard-unban "REJEITADO request#$id — $reason"
}

while :; do
  pending=$(mysql_q "SELECT CONCAT_WS('|', id, account_id, IFNULL(account_name,''), ip, IFNULL(remote_ip,'')) FROM otguard_unban_requests WHERE status='pending' ORDER BY id LIMIT 50")

  while IFS='|' read -r id accid accname ip remote_ip; do
    [ -z "$id" ] && continue

    if ! printf '%s' "$ip" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
      reject "$id" "IP invalido: $ip"
      continue
    fi

    hour_count=$(mysql_q "SELECT COUNT(*) FROM otguard_unban_requests WHERE account_id=$accid AND status='done' AND processed_at > UNIX_TIMESTAMP() - 3600")
    if [ "${hour_count:-0}" -ge "$MAX_PER_HOUR" ]; then
      reject "$id" "rate limit: ${MAX_PER_HOUR}/h excedido"
      continue
    fi

    day_count=$(mysql_q "SELECT COUNT(*) FROM otguard_unban_requests WHERE account_id=$accid AND status='done' AND processed_at > UNIX_TIMESTAMP() - 86400")
    if [ "${day_count:-0}" -ge "$MAX_PER_DAY" ]; then
      reject "$id" "rate limit: ${MAX_PER_DAY}/dia excedido"
      continue
    fi

    if ! ipset test otguard_bl "$ip" 2>/dev/null; then
      reject "$id" "IP nao esta na blocklist"
      continue
    fi

    if ipset del otguard_bl "$ip" 2>/dev/null; then
      ipset save otguard_bl > /etc/otguard/blocklist.ipset 2>/dev/null
      mysql_x "UPDATE otguard_unban_requests SET status='done', processed_at=UNIX_TIMESTAMP() WHERE id=$id"
      logger -t otguard-unban "UNBAN $ip (account=$accname id=$accid request=$id remote=$remote_ip)"
      send_discord "🔓 Self-service unban" "**IP:** \`$ip\`\\n**Account:** $accname (id=$accid)\\n**Remote (site):** $remote_ip\\n**Request:** #$id" 3066993
    else
      reject "$id" "ipset del falhou"
    fi
  done <<< "$pending"

  sleep "$INTERVAL"
done
OTG_UNBAN

  # substitui placeholders dependentes da versao em runtime (heredoc 'quoted' nao expande)
  sed -i "s/__OTG_VER__/$OTG_VER/g" "$bd/otguard-mon"
  chmod +x "$sd/otguard-mitigacao.sh" "$sd/otguard-cf-update.sh" "$sd/otguard-watch.sh" \
           "$sd/otguard-live.sh" "$sd/otguard-lockdown" "$sd/otguard-panic" \
           "$sd/otguard-slowread" "$sd/otguard-shadow" "$sd/otguard-unban-watcher" \
           "$bd/otguard-mon" "$bd/otguard-auth-check"
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

  cat > /etc/systemd/system/otguard-slowread.service <<'OTG_USL'
[Unit]
Description=OTGuard: detector de slowread (sockets idle drenando recursos)
After=network-online.target otguard-mitigacao.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/otguard-slowread
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
OTG_USL
  cat > /etc/systemd/system/otguard-shadow.service <<'OTG_USHA'
[Unit]
Description=OTGuard Shadow: ShieldM local + auto-ban via auth.log
After=network.target mysql.service mariadb.service
Wants=mysql.service mariadb.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/otguard-shadow
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
OTG_USHA
  cat > /etc/systemd/system/otguard-unban.service <<'OTG_UUNB'
[Unit]
Description=OTGuard Unban: processa pedidos self-service de desban
After=network.target mysql.service mariadb.service
Wants=mysql.service mariadb.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/otguard-unban-watcher
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
OTG_UUNB
  cat > /etc/tmpfiles.d/otguard.conf <<'OTG_TMPF'
d /var/log/otguard 0755 root root -
f /var/log/otguard/auth.log 0666 root root -
OTG_TMPF
  systemd-tmpfiles --create /etc/tmpfiles.d/otguard.conf 2>/dev/null || true
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
Description=OTGuard: atualizacao diaria dos ranges da Cloudflare
[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h
[Install]
WantedBy=timers.target
OTG_U5
}

# --------------------------------------------------------------------------
apply() {
  # xt_recent default ip_list_tot=100 e baixo demais p/ peak de centenas de players.
  # Persistir 4096 via modprobe.d garante o limite no boot.
  if [ ! -f /etc/modprobe.d/xt_recent.conf ] || ! grep -q 'ip_list_tot=4096' /etc/modprobe.d/xt_recent.conf; then
    echo "options xt_recent ip_list_tot=4096" > /etc/modprobe.d/xt_recent.conf
    # recarrega o modulo p/ pegar o novo limite (nao quebra: nao ha regras usando antes do otguard-mitigacao rodar)
    modprobe -r xt_recent 2>/dev/null && modprobe xt_recent 2>/dev/null || true
    ok "xt_recent: ip_list_tot=4096 (suporta peak de centenas de players no whitelist)"
  fi
  cat > /etc/sysctl.d/99-otguard.conf <<'OTG_SYS'
# OTGuard — tuning anti-DDoS
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_retries2 = 10
net.ipv4.tcp_abort_on_overflow = 1
net.netfilter.nf_conntrack_max = 2097152
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_loose = 0
OTG_SYS
  sysctl -q -p /etc/sysctl.d/99-otguard.conf >/dev/null 2>&1
  ok "ajustes de rede (sysctl) aplicados"
  mkdir -p "$LOGDIR"
  emit_scripts /usr/local/sbin /usr/local/bin
  emit_units
  systemctl daemon-reload
  ok "componentes e units instalados"
  for s in otguard-mitigacao otguard-watch otguard-live otguard-slowread otguard-shadow otguard-unban; do
    say "  ${CD}subindo $s ...${CR}"
    systemctl enable "$s" >/dev/null 2>&1
    systemctl restart "$s"
  done
  ok "servicos no ar"
  # Cria schema do self-service unban se TFS configurado (idempotente)
  _tfs_cfg="${OTG_TFS_CONFIG:-$(ls /home/otserv/*/config.lua 2>/dev/null | head -1)}"
  if [ -n "$_tfs_cfg" ] && [ -f "$_tfs_cfg" ]; then
    _dbpass=$(grep -E "^[[:space:]]*sqlPass" "$_tfs_cfg" 2>/dev/null | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
    _dbname=$(grep -E "^[[:space:]]*sqlDatabase" "$_tfs_cfg" 2>/dev/null | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
    if [ -n "$_dbpass" ] && [ -n "$_dbname" ]; then
      mysql -u root -p"$_dbpass" "$_dbname" -e "
        CREATE TABLE IF NOT EXISTS otguard_unban_requests (
          id INT AUTO_INCREMENT PRIMARY KEY,
          account_id INT NOT NULL,
          account_name VARCHAR(64) DEFAULT NULL,
          ip VARCHAR(45) NOT NULL,
          remote_ip VARCHAR(45) DEFAULT NULL,
          requested_at INT NOT NULL,
          processed_at INT DEFAULT NULL,
          status ENUM('pending','done','rejected') DEFAULT 'pending',
          reason VARCHAR(255) DEFAULT NULL,
          INDEX idx_status_id (status, id),
          INDEX idx_account_time (account_id, requested_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;" 2>/dev/null \
        && ok "tabela otguard_unban_requests garantida (DB $_dbname)" \
        || warn "nao consegui criar tabela otguard_unban_requests no DB $_dbname"
    fi
  else
    warn "TFS config.lua nao encontrado — self-service unban precisa de hook no PHP (ver README) + tabela criada manualmente"
  fi
  if grep -q '^CF_FILTER=sim' "$CONF" 2>/dev/null; then
    systemctl enable --now otguard-cfupdate.timer >/dev/null 2>&1
    ok "filtragem Cloudflare ativada"
  else
    systemctl disable --now otguard-cfupdate.timer >/dev/null 2>&1
  fi
  # instala o proprio script como comando global "otguard" em qualquer PATH.
  #
  # Caso A: existe /usr/sbin/otguard (instalado via .deb) — esse e o canonico.
  #   Removemos /usr/local/sbin/otguard se ele existir (raw install antigo),
  #   porque PATH coloca /usr/local/sbin antes e ele eclipsaria o .deb.
  #   Criamos um symlink em /usr/local/bin pra "otguard" funcionar pra usuario
  #   normal tambem (alguns Ubuntu nao botam /usr/sbin no PATH de user comum).
  #
  # Caso B: nao existe /usr/sbin/otguard — instalacao via raw 'sh otguard.sh'.
  #   Copiamos $0 pra /usr/local/sbin/otguard.
  if [ -x /usr/sbin/otguard ]; then
    if [ -e /usr/local/sbin/otguard ] && [ "$(readlink -f /usr/local/sbin/otguard 2>/dev/null)" != "/usr/sbin/otguard" ]; then
      rm -f /usr/local/sbin/otguard
      ok 'limpou /usr/local/sbin/otguard antigo (cano canonico agora e /usr/sbin/otguard do .deb)'
    fi
    ln -sf /usr/sbin/otguard /usr/local/bin/otguard
  elif [ -f "$0" ]; then
    # comparar inodes p/ evitar cp 'X X' quando $0 ja e o destino
    src_i=$(stat -c %i "$0" 2>/dev/null)
    dst_i=$(stat -c %i /usr/local/sbin/otguard 2>/dev/null)
    if [ -n "$src_i" ] && [ "$src_i" != "$dst_i" ]; then
      cp -f "$0" /usr/local/sbin/otguard
      chmod 0755 /usr/local/sbin/otguard
      ok 'comando global: digite "otguard" em qualquer lugar'
    fi
    ln -sf /usr/local/sbin/otguard /usr/local/bin/otguard
  fi
}

status() {
  [ -f "$CONF" ] || die "OTGuard nao esta instalado."
  . "$CONF"
  say ""
  say "  ${CT}OTGuard $OTG_VER${CR}  ·  $PROVIDER_NAME  ·  portas $PORTS"
  hr
  for s in otguard-mitigacao otguard-watch otguard-live otguard-slowread; do
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
  for s in otguard-mitigacao otguard-watch otguard-live otguard-slowread; do
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
  for s in otguard-mitigacao otguard-watch otguard-live otguard-slowread otguard-shadow otguard-unban; do
    systemctl disable --now "$s" >/dev/null 2>&1
    rm -f "/etc/systemd/system/$s.service"
  done
  systemctl daemon-reload
  systemctl disable --now otguard-cfupdate.timer >/dev/null 2>&1
  rm -f /etc/systemd/system/otguard-cfupdate.service /etc/systemd/system/otguard-cfupdate.timer
  iptables -t raw -F PREROUTING 2>/dev/null
  ip6tables -t raw -F PREROUTING 2>/dev/null
  # remove regra mangle do whitelist (--set otg_players) — idempotente
  iptables -t mangle -D PREROUTING -p tcp -m multiport --dports 7171,7172 -m conntrack --ctstate ESTABLISHED -m recent --set --name otg_players --rsource 2>/dev/null || true
  rm -f /etc/modprobe.d/xt_recent.conf
  ipset destroy otguard_bl  2>/dev/null
  ipset destroy otguard_cf  2>/dev/null
  ipset destroy otguard_cf6 2>/dev/null
  # garante que lockdown nao fique pendurado no iptables ao remover
  [ -x /usr/local/sbin/otguard-lockdown ] && /usr/local/sbin/otguard-lockdown off >/dev/null 2>&1 || true
  [ -x /usr/local/sbin/otguard-panic    ] && /usr/local/sbin/otguard-panic    off >/dev/null 2>&1 || true
  systemctl stop otguard-slowread >/dev/null 2>&1 || true
  rm -rf /run/otguard
  systemctl stop otguard-lockdown-autoff.timer otguard-lockdown-autoff.service >/dev/null 2>&1 || true
  rm -f /usr/local/sbin/otguard-mitigacao.sh /usr/local/sbin/otguard-cf-update.sh \
        /usr/local/sbin/otguard-watch.sh /usr/local/sbin/otguard-live.sh \
        /usr/local/sbin/otguard-lockdown /usr/local/sbin/otguard-panic \
        /usr/local/sbin/otguard-slowread /usr/local/sbin/otguard-shadow \
        /usr/local/sbin/otguard-unban-watcher \
        /etc/systemd/system/otguard-slowread.service \
        /etc/systemd/system/otguard-shadow.service \
        /etc/systemd/system/otguard-unban.service \
        /etc/tmpfiles.d/otguard.conf \
        /usr/local/bin/otguard-mon /usr/local/bin/otguard-auth-check \
        /etc/sysctl.d/99-otguard.conf \
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
    if bash -n "$d/otguard-lockdown" 2>/dev/null; then ok "otguard-lockdown"; else err "otguard-lockdown — erro"; fail=1; fi
    if bash -n "$d/otguard-panic" 2>/dev/null; then ok "otguard-panic"; else err "otguard-panic — erro"; fail=1; fi
    if bash -n "$d/otguard-slowread" 2>/dev/null; then ok "otguard-slowread"; else err "otguard-slowread — erro"; fail=1; fi
    if bash -n "$d/otguard-shadow" 2>/dev/null; then ok "otguard-shadow"; else err "otguard-shadow — erro"; fail=1; fi
    if bash -n "$d/otguard-unban-watcher" 2>/dev/null; then ok "otguard-unban-watcher"; else err "otguard-unban-watcher — erro"; fail=1; fi
    if bash -n "$d/otguard-auth-check" 2>/dev/null; then ok "otguard-auth-check"; else err "otguard-auth-check — erro"; fail=1; fi
  else warn "bash ausente — otguard-mon/otguard-lockdown nao checados"; fi
  rm -rf "$d"
  say ""
  [ "$fail" = 0 ] && ok "pacote OTGuard integro." || die "pacote com erro de sintaxe."
}

# --------------------------------------------------------------------------
# upgrade — redeploya os componentes (e recalcula thresholds se houver
# PEAK_PLAYERS no config). Chamado automaticamente pelo postinst do .deb
# em upgrades, ou manualmente: `sudo otguard upgrade`.
upgrade() {
  [ "$(id -u)" = 0 ] || die "rode como root"
  [ -f "$CONF" ]    || die "OTGuard nao instalado ainda — use 'sudo otguard' pra primeira vez"
  . "$CONF"
  say ""
  say "  ${CT}OTGuard upgrade${CR} -> versao $OTG_VER"
  hr
  if [ -n "${PEAK_PLAYERS:-}" ]; then
    say "  ${CD}recomputando thresholds (PEAK_PLAYERS=$PEAK_PLAYERS, CHARS_PER_IP=${CHARS_PER_IP:-4})${CR}"
    # remonta os W_* a partir do config — write_config precisa deles
    W_IFACE=$IFACE
    W_PL=$(printf '%s' "$PORTS" | awk '{print $1}')
    W_PG=$(printf '%s' "$PORTS" | awk '{print $2}')
    W_ADM=$ADMIN_IPS
    W_HOOK=$DISCORD_WEBHOOK
    W_CF=$CF_FILTER
    W_PEAK=$PEAK_PLAYERS
    W_CHARS_PER_IP=${CHARS_PER_IP:-4}    # fallback p/ configs antigas (pre-1.2)
    PROV_KEY=$PROVIDER; PROV_NAME=$PROVIDER_NAME
    SCRUB=$SCRUB_NAME;  PROV_ASK=$PROVIDER_ASK
    write_config
    ok "config regenerada com thresholds da v$OTG_VER"
  else
    warn "config sem PEAK_PLAYERS (instalada antes da v1.1)"
    warn "vou apenas redeployar os componentes."
    warn "rode  ${CT}sudo otguard reconfig${CR}  ${CW}depois${CR} para recalibrar os limites com a formula nova."
  fi
  say "  ${CD}redeployando componentes (scripts em /usr/local/sbin, units systemd)...${CR}"
  apply
  ok "OTGuard atualizado para v$OTG_VER."
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
  # substitui OTG_VER no script empacotado pela versao real do .deb
  # (assim 'otguard' / 'otguard help' / status banner mostram a versao certa)
  sed -i "s/^OTG_VER=.*/OTG_VER=$ver/" "$tmp/$pkg/usr/sbin/otguard"
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
# $1 = "configure"
# $2 = versao ANTIGA quando e upgrade; vazio em primeira instalacao
case "$1" in
  configure)
    if [ -n "$2" ] && [ -f /etc/otguard/otguard.conf ]; then
      # upgrade: redeploya componentes e recalcula thresholds (se PEAK_PLAYERS presente)
      echo
      echo "  detectado upgrade de v${2} -> nova versao"
      echo "  rodando 'otguard upgrade' automaticamente..."
      /usr/sbin/otguard upgrade || {
        echo "  (falhou — rode manualmente: sudo otguard upgrade)"
        exit 0   # nao bloqueia o upgrade do .deb
      }
    else
      cat <<MSG

  OTGuard instalado.  Para configurar (wizard interativo):

      sudo otguard

  Outros comandos:  otguard help

MSG
    fi
    ;;
esac
exit 0
POST
  cat > "$tmp/$pkg/DEBIAN/prerm" <<'PRER'
#!/bin/sh
set -e
case "$1" in
  remove|upgrade|deconfigure)
    for s in otguard-watch otguard-live otguard-slowread otguard-mitigacao otguard-cfupdate.timer; do
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
  upgrade|--upgrade)     upgrade ;;
  uninstall|--uninstall) [ "$(id -u)" = 0 ] || die "rode como root"; uninstall ;;
  selftest|--selftest)   selftest ;;
  build-deb|--build-deb) shift; build_deb "$@" ;;
  --help|-h|help)        awk '/^# =/{c++;next} c==1{sub(/^# ?/,"");print}' "$0" ;;
  '')                    do_install ;;
  *)                     die "opcao desconhecida: $1   (use:  otguard help)" ;;
esac

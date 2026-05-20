#!/bin/sh
# ==========================================================================
#  OTGuard — instalador one-liner
#
#  Uso (na maquina do servidor):
#    curl -fsSL https://raw.githubusercontent.com/FeTads/otguard/main/install.sh | sudo sh
#
#  O que faz:
#    1. checa que voce esta no Debian/Ubuntu como root
#    2. baixa o .deb da release mais recente do GitHub
#    3. instala via apt (resolve as dependencias automaticamente)
#    4. te diz para rodar  `sudo otguard`  pra abrir o wizard.
# ==========================================================================
set -e

GH_USER="FeTads"
GH_REPO="otguard"

API="https://api.github.com/repos/${GH_USER}/${GH_REPO}/releases/latest"

# cores se houver TTY
if [ -t 1 ]; then T='\033[1;36m'; O='\033[1;32m'; E='\033[1;31m'; D='\033[2m'; R='\033[0m'
else T=''; O=''; E=''; D=''; R=''; fi
say()  { printf '%b\n' "$*"; }
ok()   { printf '%b\n' "  ${O}✓${R} $*"; }
err()  { printf '%b\n' "  ${E}✗${R} $*" >&2; }
die()  { err "$*"; exit 1; }

say ""
say "  ${T}OTGuard${R}  ${D}—${R}  ${T}instalador automatico${R}"
say "  ${D}────────────────────────────────────────────${R}"

[ "$(id -u)" = 0 ]                       || die "rode como root:  curl ... | sudo sh"
command -v apt-get >/dev/null 2>&1       || die "este instalador e para Debian/Ubuntu (apt)."

ok "ambiente ok (Debian/Ubuntu + root)"

say "  ${D}atualizando indice e instalando ferramentas auxiliares...${R}"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates jq >/dev/null

say "  ${D}consultando ultima release no GitHub...${R}"
url=$(curl -fsSL "$API" 2>/dev/null | jq -r '.assets[] | select(.name | endswith(".deb")) | .browser_download_url' | head -1)
[ -n "$url" ] || die "nao encontrei .deb nas releases de ${GH_USER}/${GH_REPO} (rede? repo privado?)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
deb="$tmp/otguard.deb"

ok "baixando: $url"
curl -fsSL -o "$deb" "$url" || die "falha ao baixar o .deb"

ok "instalando via apt (resolve dependencias automaticamente)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb" >/dev/null

say ""
ok "OTGuard instalado."
say ""
say "  ${T}Proximo passo:${R}  rode o wizard com:"
say ""
say "      ${O}sudo otguard${R}"
say ""
say "  ${D}Outros comandos:  sudo otguard help${R}"
say ""

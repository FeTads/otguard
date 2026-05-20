#!/bin/sh
# ==========================================================================
#  OTGuard — instalador one-liner com verificacao de SHA256
#
#  Modo "release"  (recomendado — mais robusto e nao precisa de jq):
#    curl -fsSL https://github.com/FeTads/otguard/releases/latest/download/install.sh | sudo sh
#
#  Modo "main branch"  (fallback — funciona se o Actions ainda nao rodou):
#    curl -fsSL https://raw.githubusercontent.com/FeTads/otguard/main/install.sh | sudo sh
#
#  O que faz:
#    1. checa que voce esta no Debian/Ubuntu como root
#    2. baixa o .deb da release especificada (ou da ultima)
#    3. confere o SHA256 — se nao bater, ABORTA antes de instalar
#    4. instala via apt (resolve as dependencias automaticamente)
# ==========================================================================
set -e

GH_USER="FeTads"
GH_REPO="otguard"

# Estes dois sao substituidos pelo GitHub Actions ao gerar o install.sh
# que vai junto com cada release.  Se ainda forem os placeholders literais
# (ex: voce baixou direto do main), o instalador cai no modo API + .sha256.
VERSION="__VERSION__"
SHA256="__SHA256__"

# Fingerprint da chave GPG que assina TODAS as releases — gravado no install.sh
# pra detectar troca de chave (TOFU mitigado). Pode conferir manualmente em:
#   https://github.com/FeTads/otguard/blob/main/otguard-public.gpg
GPG_FINGERPRINT="C35758008A4DEB52EC996C785A7E6EADE40BB4A0"
GPG_KEY_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/otguard-public.gpg"

# ---- ui helpers ----------------------------------------------------------
if [ -t 1 ]; then T='\033[1;36m'; O='\033[1;32m'; E='\033[1;31m'; W='\033[1;33m'; D='\033[2m'; R='\033[0m'
else T=''; O=''; E=''; W=''; D=''; R=''; fi
say()  { printf '%b\n' "$*"; }
ok()   { printf '%b\n' "  ${O}✓${R} $*"; }
warn() { printf '%b\n' "  ${W}!${R} $*"; }
err()  { printf '%b\n' "  ${E}✗${R} $*" >&2; }
die()  { err "$*"; exit 1; }

say ""
say "  ${T}OTGuard${R}  ${D}—${R}  ${T}instalador automatico${R}"
say "  ${D}────────────────────────────────────────────${R}"

[ "$(id -u)" = 0 ]                 || die "rode como root:  curl ... | sudo sh"
command -v apt-get >/dev/null 2>&1 || die "este instalador e para Debian/Ubuntu (apt)."
ok "ambiente ok (Debian/Ubuntu + root)"

# ---- modo: release (substituido pelo Actions) ou bootstrap (main) --------
if [ "$VERSION" != "__VERSION__" ] && [ "$SHA256" != "__SHA256__" ]; then
  MODE=release
  ok "modo: release v${VERSION}  ${D}(hash + GPG baked-in)${R}"
  deb_url="https://github.com/${GH_USER}/${GH_REPO}/releases/download/v${VERSION}/otguard_${VERSION}_all.deb"
  sha_url=""
  EXPECTED_SHA="$SHA256"
  needs="curl ca-certificates gnupg"
else
  MODE=bootstrap
  warn "modo: bootstrap (rodando do main branch — vou olhar a ultima release via API)"
  needs="curl ca-certificates gnupg jq"
fi

# ---- deps minimas pro instalador -----------------------------------------
say "  ${D}atualizando indice e instalando ferramentas auxiliares...${R}"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $needs >/dev/null

# ---- descobrir URLs no modo bootstrap ------------------------------------
if [ "$MODE" = bootstrap ]; then
  say "  ${D}consultando ultima release no GitHub...${R}"
  api=$(curl -fsSL "https://api.github.com/repos/${GH_USER}/${GH_REPO}/releases/latest" 2>/dev/null) \
    || die "falha ao falar com a API do GitHub (rede? rate-limit?)"
  deb_url=$(printf '%s' "$api" | jq -r '.assets[] | select(.name|endswith(".deb")) | .browser_download_url' | head -1)
  sha_url=$(printf '%s' "$api" | jq -r '.assets[] | select(.name|endswith(".deb.sha256")) | .browser_download_url' | head -1)
  [ -n "$deb_url" ] || die "nao encontrei .deb nas releases de ${GH_USER}/${GH_REPO}"
  [ -n "$sha_url" ] || warn "release sem .deb.sha256 (versao antiga) — vou pular verificacao do hash"
fi

# ---- download ------------------------------------------------------------
tmp=$(mktemp -d) || die "mktemp falhou"
trap 'rm -rf "$tmp"' EXIT
deb="$tmp/otguard.deb"

ok "baixando .deb"
say "  ${D}  $deb_url${R}"
curl -fsSL -o "$deb" "$deb_url" || die "falha ao baixar o .deb"

# ---- verificacao GPG (camada criptografica forte) ------------------------
sig_url="${deb_url}.sig"
if curl -fsSL -o "$tmp/deb.sig" "$sig_url" 2>/dev/null && [ -s "$tmp/deb.sig" ]; then
  curl -fsSL -o "$tmp/pubkey.gpg" "$GPG_KEY_URL" 2>/dev/null && [ -s "$tmp/pubkey.gpg" ] \
    || die "falha ao baixar chave publica GPG ($GPG_KEY_URL)"
  GNUPGHOME=$(mktemp -d -p "$tmp" gnupg.XXXXXX); chmod 700 "$GNUPGHOME"; export GNUPGHOME
  gpg --batch --import "$tmp/pubkey.gpg" 2>/dev/null \
    || die "falha ao importar chave publica GPG"
  actual_fp=$(gpg --batch --list-keys --with-colons 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')
  if [ "$actual_fp" != "$GPG_FINGERPRINT" ]; then
    err "fingerprint GPG inesperado!"
    err "  esperado: $GPG_FINGERPRINT"
    err "  obtido:   $actual_fp"
    die "abortando — alguem trocou a chave publica no repo"
  fi
  if gpg --batch --verify "$tmp/deb.sig" "$deb" 2>/dev/null; then
    ok "assinatura GPG verificada  ${D}(chave ${GPG_FINGERPRINT%????????????????????????????????}...)${R}"
  else
    die "ASSINATURA GPG INVALIDA — o .deb nao foi assinado por essa chave"
  fi
  unset GNUPGHOME
else
  warn "release sem .deb.sig (versao antiga?) — vou usar so SHA256"
fi

# ---- verificacao do SHA256 ----------------------------------------------
if [ "$MODE" = bootstrap ] && [ -n "$sha_url" ]; then
  curl -fsSL -o "$tmp/sha" "$sha_url" || die "falha ao baixar .deb.sha256"
  EXPECTED_SHA=$(awk '{print $1}' "$tmp/sha" | head -1)
fi

if [ -n "${EXPECTED_SHA:-}" ]; then
  actual=$(sha256sum "$deb" | awk '{print $1}')
  if [ "$EXPECTED_SHA" = "$actual" ]; then
    ok "sha256 verificado  ${D}(${actual%????????????????????????????????????????})...${R}"
  else
    err "SHA256 NAO bate!"
    err "  esperado:  $EXPECTED_SHA"
    err "  obtido:    $actual"
    die "abortando — alguem mexeu no arquivo OU houve corrupcao na transferencia"
  fi
fi

# ---- instala -------------------------------------------------------------
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

#!/bin/bash
# =============================================================================
#  SYNAPSE + LYRA CENTRAL + SEMAPHORE — INSTALAÇÃO COMPLETA NA VPS DA NOMEN
#  Script único: sobe, numa VPS só, TODO o ecossistema (Ritmo/Harmonia/Harpa/
#  Eco/Acorde) + a Lyra Central (multi-tenant) + a Lyra "atendente" da
#  própria Nomen (tenant onboardado automaticamente, sem copiar/colar chave
#  nenhuma entre passos) + Semaphore (Ansible) + o módulo fiscal Brazil NF.
#
#  Uso:
#    export GITHUB_TOKEN=ghp_xxxxx     # PAT com acesso de leitura aos repos privados nomen-me
#    export GEMINI_API_KEY=xxxxx       # chave real do Google AI Studio / Vertex AI
#    sudo -E bash -c "$(curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
#      https://raw.githubusercontent.com/nomen-me/synapse/main/instalar_nomen_completo.sh)" \
#      -- nomen.me "Nomen" "" /root/synapse_painel.html /root/home-site
#
#  Argumentos: <dominio-base> ["Nome da Loja"] [pasta-workflows-opcional] [arquivo-html-do-painel-opcional] [pasta-ou-arquivo-da-home-opcional]
#  O 4º argumento é o caminho LOCAL (já copiado pra VPS) do index.html do
#  Painel — arquivo único, sem assets (ver seção 9.5). Se omitido, o script
#  procura /root/synapse_painel.html e, por último, tenta clonar
#  github.com/nomen-me/painel; se nenhuma das três fontes existir, o passo
#  do Painel é pulado (não-fatal) e some do resumo final, sem travar o resto.
#
#  O 5º argumento é a Home (raiz do domínio — ex: nomen.me, sem subdomínio) —
#  ver seção 9.6. Pode ser uma PASTA (index.html + páginas irmãs tipo
#  como-funciona.html + subpasta assets/, tudo copiado como está) ou um
#  arquivo único. Se omitido, o script procura /root/home-site (pasta) e
#  depois /root/index.html (arquivo). Sem nenhuma das duas, o passo da Home
#  é pulado (não-fatal, mesmo padrão do Painel).
#
#  (dominio-base "nomen.me" vira: nomen.me (raiz), lyra.nomen.me,
#   ritmo.nomen.me, harmonia.nomen.me, harpa.nomen.me, eco.nomen.me,
#   acorde.nomen.me, painel.nomen.me — os 8 registros DNS tipo A precisam
#   existir antes, incluindo o apex/raiz)
#
#  Depois de rodar, você tem: Lyra Central (multi-tenant) + a própria Nomen
#  já como tenant dela (LYRA_ATENDENTE_TENANT_ID no resumo final) + o
#  ecossistema Synapse rodando com Brazil NF instalado + o Painel de
#  operações já publicado (se a fonte do HTML estava disponível) + Semaphore
#  acessível só via túnel SSH. Tudo numa credencial só: /root/nomen_credentials.txt
#
#  ⚠️ Recomendado rodar dentro de tmux/screen (script de 20-30min):
#    apt install -y tmux && tmux new -s instalacao
#    (depois cole o comando acima dentro da sessão)
# =============================================================================
set -uo pipefail
# (sem -e de propósito: uma falha num passo não-crítico não deve abortar o
#  resto da instalação — cada passo crítico tem sua própria checagem/fatal)

# Todo o corpo do script fica dentro de main(), chamada só na ÚLTIMA linha
# do arquivo — necessário pra rodar via "curl | bash" sem risco de um
# comando interno (docker exec, docker compose exec/run) roubar bytes do
# restante do script ainda não lido pelo bash (bug real, já reproduzido e
# corrigido nos scripts individuais; ver histórico).
main() {

# =============================================================================
# 0. ARGUMENTOS, VARIÁVEIS DERIVADAS E HELPERS
# =============================================================================
DOMINIO_BASE="${1:?Uso: sudo -E bash instalar_nomen_completo.sh <dominio-base> [\"Nome\"] [pasta-workflows-opcional] [arquivo-html-do-painel-opcional] [pasta-ou-arquivo-da-home-opcional]}"
NOME_LOJA="${2:-Nomen}"
WORKFLOWS_DIR_OVERRIDE="${3:-}"
PAINEL_HTML_OVERRIDE="${4:-}"
HOME_SRC_OVERRIDE="${5:-}"

GITHUB_TOKEN="${GITHUB_TOKEN:?Exporte GITHUB_TOKEN antes de rodar (PAT com acesso de leitura aos repos privados nomen-me)}"
GEMINI_API_KEY="${GEMINI_API_KEY:?Exporte GEMINI_API_KEY antes de rodar (chave real do Google AI Studio / Vertex AI)}"
# =============================================================================
# SYNAPSE BASELINE — única fonte de verdade de versões. Nomen e Cliente usam
# exatamente os mesmos valores (exceto o que é exclusivo da Nomen, ex. Lyra).
# Toda mudança de versão passa por aqui, nunca solta pelo script.
# =============================================================================
SYNAPSE_UBUNTU_MAJOR="24.04"

SYNAPSE_ERPNEXT_VERSION="v15.121.4"
# frappe/erpnext:${SYNAPSE_ERPNEXT_VERSION} é a imagem oficial pré-construída do
# frappe_docker — ela já embute o Frappe correspondente (v15.121.1, o release
# v15 mais recente do Frappe na data do release do ERPNext v15.121.4). Não há
# bench/branch separado pra pinar aqui: o par Frappe/ERPNext vem fixado dentro
# da própria imagem publicada pelo frappe_docker.
SYNAPSE_FRAPPE_VERSION_REF="v15.121.1"  # só para o relatório — não usado em nenhum pull

SYNAPSE_N8N_VERSION="2.40.7"
SYNAPSE_CHATWOOT_VERSION="v4.18.0"
SYNAPSE_CHATWOOT_POSTGRES_VERSION="pg16"
# Escolha deliberada, não default de fallback: a linha 8.2 é documentada como
# uma das linhas "LTS" que o Redis mantém em paralelo à mais nova (8.10.x),
# validada contra Chatwoot/filas simples sem precisar do salto de major mais
# recente. O sufixo "-alpine" aqui é parte da tag testada e fixada — não é
# a tag "alpine" solta (sem versão) que a baseline proíbe.
SYNAPSE_CHATWOOT_REDIS_VERSION="8.2.10-alpine"

SYNAPSE_TRAEFIK_VERSION="v3.6.25"
SYNAPSE_UPTIME_KUMA_VERSION="2.5.5"
SYNAPSE_NETDATA_VERSION="v2.11.1"
SYNAPSE_SEMAPHORE_VERSION="v2.19.12"
# 1.30.5 corrige CVE-2026-90439 (heap buffer overflow em HTTP/3 com OpenSSL
# <=3.5.0) — release de segurança de 15/set/2026 na própria série "stable"
# que já estava em uso (não é salto de minor). Mesma lógica do Redis acima:
# "-alpine" é parte da tag fixada, não a tag solta.
SYNAPSE_NGINX_VERSION="1.30.5-alpine"

SYNAPSE_META_GRAPH_API_VERSION="v26.0"

SYNAPSE_GEMINI_MODEL="gemini-3.8-flash"

# brazil-nf é repositório público (github.com/${GITHUB_ORG}/brazil-nf), mas sem
# release/tag — só 3 commits na main. SHA confirmado via "git ls-remote" em
# 29/set/2026 (HEAD == refs/heads/main nesse momento). Continua sobrescrevível
# por variável de ambiente se a Nomen cortar um commit novo depois.
SYNAPSE_BRAZIL_NF_REF="${SYNAPSE_BRAZIL_NF_REF:-cd1efcac6b62e70f55c6ae9cb95a6d22d16678d4}"

GEMINI_MODEL="${GEMINI_MODEL:-${SYNAPSE_GEMINI_MODEL}}"
GITHUB_ORG="nomen-me"


AUTO_REBOOT="${AUTO_REBOOT:-nao}"
APP_USER="${APP_USER:-ubuntu}"
LYRA_APP_DIR="${LYRA_APP_DIR:-/home/${APP_USER}/lyra-central-api}"
SEMAPHORE_PORT="${SEMAPHORE_PORT:-3001}"
SEMAPHORE_ADMIN_USER="${SEMAPHORE_ADMIN_USER:-synapse-ops}"
SEMAPHORE_ADMIN_EMAIL="${SEMAPHORE_ADMIN_EMAIL:-ops@${DOMINIO_BASE}}"

DOMINIO_LYRA="lyra.${DOMINIO_BASE}"
DOMINIO_ERP="ritmo.${DOMINIO_BASE}"
DOMINIO_N8N="harmonia.${DOMINIO_BASE}"
DOMINIO_CHAT="harpa.${DOMINIO_BASE}"
DOMINIO_NETDATA="acorde.${DOMINIO_BASE}"
DOMINIO_UPTIME="eco.${DOMINIO_BASE}"
DOMINIO_PAINEL="painel.${DOMINIO_BASE}"
ORIGEM_PAINEL="https://${DOMINIO_PAINEL}"

CRED_FILE="/root/nomen_credentials.txt"
ler_credencial_existente() {
  # Lê uma chave de uma instalação anterior, se o arquivo já existir — usado
  # abaixo pra NÃO regenerar senha/segredo que já está em uso de verdade
  # (ver comentário junto de SENHA/SECRET_KEY logo abaixo).
  local chave="$1"
  [ -f "$CRED_FILE" ] && grep "^${chave}=" "$CRED_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2-
}

EMAIL="admin@${DOMINIO_BASE}"
# Reaproveita SENHA/SECRET_KEY de uma instalação anterior, se existirem, em
# vez de gerar valores novos a cada rerun. MariaDB root, admin do ERPNext e
# Postgres do Chatwoot só usam SENHA no momento em que o container/site é
# CRIADO (num rerun eles continuam existindo, com a senha ORIGINAL) — gerar
# uma SENHA nova em todo rerun deixava o arquivo de credenciais mostrando
# uma senha que já não abria mais nada, sem nenhum erro visível na hora
# (mesma categoria de bug do TENANT_ID, só que silenciosa). SECRET_KEY é
# ainda mais sensível: é o SECRET_KEY_BASE do Rails/Chatwoot — trocá-lo
# depois que o Chatwoot já está de pé invalida sessões e pode quebrar a
# leitura de colunas criptografadas no banco dele.
SENHA="$(ler_credencial_existente SENHA)"
SENHA="${SENHA:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)}"
SECRET_KEY="$(ler_credencial_existente SECRET_KEY)"
SECRET_KEY="${SECRET_KEY:-$(openssl rand -hex 64)}"

BASICAUTH_USER="synapse-ops"
# BASICAUTH_PASS também é reaproveitada — do contrário a senha do Basic Auth
# de Eco/Netdata muda a cada rerun (o docker compose recria o Traefik com o
# hash novo), obrigando a redescobrir a senha depois de qualquer manutenção.
BASICAUTH_PASS="$(ler_credencial_existente BASICAUTH_PASS)"
BASICAUTH_PASS="${BASICAUTH_PASS:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)}"
BASICAUTH_HASH="$(openssl passwd -apr1 "${BASICAUTH_PASS}")"
BASICAUTH_HASH_ESCAPED="$(echo "$BASICAUTH_HASH" | sed 's/\$/\$\$/g')"

TENANT_ID="${TENANT_ID:-$(echo "$DOMINIO_BASE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/_\+/_/g; s/^_//; s/_$//')}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()  { echo -e "${RED}[ERRO]${NC} $1"; }
fatal(){ echo -e "${RED}[FATAL]${NC} $1"; exit 1; }

# Baseline §2: a instalação só é reprodutível em cima do Ubuntu homologado.
# Falha explícita e imediata em qualquer outra versão — nada de seguir e
# descobrir problema de compatibilidade no meio da instalação.
UBUNTU_VERSAO_HOST="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-desconhecida}")"
if [ "$UBUNTU_VERSAO_HOST" != "$SYNAPSE_UBUNTU_MAJOR" ]; then
  fatal "Ubuntu incompatível (detectado: ${UBUNTU_VERSAO_HOST}). Synapse exige Ubuntu ${SYNAPSE_UBUNTU_MAJOR} LTS."
fi
ok "Ubuntu ${UBUNTU_VERSAO_HOST} confirmado"

# Movido pra cá (era definido só na seção 9B) porque checks mais cedo no
# script (brazil-nf, e potencialmente outros) também precisam alimentar o
# mesmo relatório final — relatorio() precisa existir antes do primeiro uso.
RELATORIO_LINHAS=()
FALHA_CRITICA=false
relatorio() {
  local status="$1" nome="$2" detalhe="${3:-}"
  if [ -n "$detalhe" ]; then
    RELATORIO_LINHAS+=("[${status}] ${nome}
      ${detalhe}")
  else
    RELATORIO_LINHAS+=("[${status}] ${nome}")
  fi
  [ "$status" = "FAIL" ] && FALHA_CRITICA=true
}

salvar_credencial() {
  local chave="$1" valor="$2"
  [ -z "$valor" ] && return 0
  touch "$CRED_FILE"; chmod 600 "$CRED_FILE"
  if grep -q "^${chave}=" "$CRED_FILE" 2>/dev/null; then
    sed -i "s|^${chave}=.*|${chave}=${valor}|" "$CRED_FILE"
  else
    echo "${chave}=${valor}" >> "$CRED_FILE"
  fi
}

N8N_ENV_FILE="/home/ubuntu/n8n/.env"
grava_env_n8n() {
  local chave="$1" valor="$2"
  [ -z "$valor" ] && return 0
  touch "$N8N_ENV_FILE"; chmod 600 "$N8N_ENV_FILE"
  if grep -q "^${chave}=" "$N8N_ENV_FILE" 2>/dev/null; then
    sed -i "s|^${chave}=.*|${chave}=${valor}|" "$N8N_ENV_FILE"
  else
    echo "${chave}=${valor}" >> "$N8N_ENV_FILE"
  fi
}

ritmo_exec() {
  # bench execute <mod>.main exige que "mod" resolva como <app_instalado>.<...> —
  # colocar o .py solto na raiz do bench faz "mod" virar o "app_name" que ele
  # checa contra frappe.get_installed_apps(), e falha com AppNotInstalledError
  # (nome do arquivo não é um app). "frappe" é sempre um app instalado, então
  # colocamos dentro do pacote dele e executamos como frappe.<mod>.main.
  local tmp="/tmp/synapse_ritmo_$$_${RANDOM}.py"
  cat > "$tmp"
  local mod; mod="$(basename "$tmp" .py)"
  docker cp "$tmp" "ritmo-backend-1:/home/frappe/frappe-bench/apps/frappe/frappe/${mod}.py" 2>/dev/null
  docker exec -u frappe ritmo-backend-1 bash -c "cd /home/frappe/frappe-bench && bench --site ${DOMINIO_ERP} execute frappe.${mod}.main" 2>&1
  docker exec -u frappe ritmo-backend-1 rm -f "/home/frappe/frappe-bench/apps/frappe/frappe/${mod}.py" 2>/dev/null || true
  rm -f "$tmp"
}

clonar_repo_nomen() {
  local repo="$1" destino="$2"
  rm -rf "$destino"
  local saida
  if saida=$(git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${repo}.git" "$destino" 2>&1); then
    return 0
  else
    echo "$saida" | sed "s|${GITHUB_TOKEN}|***|g" >&2
    return 1
  fi
}

# Igual a clonar_repo_nomen, mas fixa um commit/tag em vez de pegar o HEAD do
# momento. Usado onde a baseline exige um ref exato e reproduzível (ex.:
# brazil-nf, que não tem release pública — só o commit homologado manualmente).
clonar_repo_nomen_pinned() {
  local repo="$1" destino="$2" ref="$3"
  rm -rf "$destino"
  local saida
  if ! saida=$(git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${repo}.git" "$destino" 2>&1); then
    echo "$saida" | sed "s|${GITHUB_TOKEN}|***|g" >&2
    return 1
  fi
  if ! saida=$(cd "$destino" && git checkout --quiet "$ref" 2>&1); then
    echo "$saida" >&2
    err "Ref '${ref}' não encontrado em ${GITHUB_ORG}/${repo} — confira SYNAPSE_BRAZIL_NF_REF."
    return 1
  fi
  return 0
}

esperar_apt_livre() {
  local tentativas=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    tentativas=$((tentativas+1))
    if [ $tentativas -ge 60 ]; then
      warn "dpkg/apt ainda ocupado por outro processo depois de 5min — seguindo mesmo assim (pode falhar)."
      break
    fi
    log "apt/dpkg ocupado por outro processo (provavelmente unattended-upgrades) — aguardando... (${tentativas}/60)"
    sleep 5
  done
}
parar_unattended_upgrades() {
  systemctl stop unattended-upgrades 2>/dev/null || true
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
}


# =============================================================================
# 1. PRÉ-VERIFICAÇÕES
# =============================================================================
if [ "$(id -u)" -ne 0 ]; then
  fatal "Este script precisa correr como root. Corre com 'sudo -E'."
fi

if ! [[ "$TENANT_ID" =~ ^[a-z0-9_-]{3,64}$ ]]; then
  fatal "tenant_id derivado de '${DOMINIO_BASE}' ficou inválido ('${TENANT_ID}'). Exporte TENANT_ID=algo_valido manualmente e rode de novo."
fi

if [ -n "$WORKFLOWS_DIR_OVERRIDE" ] && [ ! -d "$WORKFLOWS_DIR_OVERRIDE" ]; then
  fatal "Pasta de workflows local informada não existe: ${WORKFLOWS_DIR_OVERRIDE}"
fi

if [ -n "$PAINEL_HTML_OVERRIDE" ] && [ ! -f "$PAINEL_HTML_OVERRIDE" ]; then
  fatal "Arquivo do Painel informado como 4º argumento não existe: ${PAINEL_HTML_OVERRIDE}"
fi

if [ -n "$HOME_SRC_OVERRIDE" ] && [ ! -f "$HOME_SRC_OVERRIDE" ] && [ ! -d "$HOME_SRC_OVERRIDE" ]; then
  fatal "Pasta/arquivo da Home informado como 5º argumento não existe: ${HOME_SRC_OVERRIDE}"
fi

mkdir -p /root
: > "$CRED_FILE"; chmod 600 "$CRED_FILE"
salvar_credencial "DOMINIO_BASE" "$DOMINIO_BASE"
salvar_credencial "TENANT_ID" "$TENANT_ID"
salvar_credencial "EMAIL" "$EMAIL"
salvar_credencial "SENHA" "$SENHA"
salvar_credencial "SECRET_KEY" "$SECRET_KEY"
salvar_credencial "BASICAUTH_USER" "$BASICAUTH_USER"
salvar_credencial "BASICAUTH_PASS" "$BASICAUTH_PASS"
ok "Credenciais base geradas e guardadas em ${CRED_FILE} (permissões 600)"

echo "======================================================"
echo " Nomen — instalação completa (ecossistema + Lyra Central + Semaphore)"
echo "   domínio base   : ${DOMINIO_BASE}"
echo "   Lyra Central   : https://${DOMINIO_LYRA}"
echo "   tenant Lyra    : ${TENANT_ID} (a própria Nomen, atendente interna)"
echo "======================================================"

# =============================================================================
# 2. SISTEMA BASE — apt/kernel/firewall/Docker/Node.js/Redis
#    (Node+Redis são pra Lyra Central rodar via systemd; Docker é pra
#    Traefik + o ecossistema + Semaphore)
# =============================================================================
parar_unattended_upgrades

log "Actualizando sistema..."
esperar_apt_livre
apt update && apt upgrade -y || fatal "Falha ao actualizar o sistema."
esperar_apt_livre
apt install -y curl git nano ufw jq python3 unzip redis-server || fatal "Falha ao instalar pacotes base."

log "Verificando estado do kernel face à CVE-2026-53359 (Januscape)..."
KERNEL_A_CORRER="$(uname -r)"
KERNEL_MAIS_RECENTE="$(dpkg -l 2>/dev/null | awk '/^ii  linux-image-[0-9]/{print $2}' | sed 's/linux-image-//' | sort -V | tail -1)"
if [ -n "$KERNEL_MAIS_RECENTE" ] && [ "$KERNEL_A_CORRER" != "$KERNEL_MAIS_RECENTE" ]; then
  REINICIO_NECESSARIO=true
  warn "Kernel mais recente instalado (${KERNEL_MAIS_RECENTE}) mas a correr ${KERNEL_A_CORRER}. Reinício necessário no fim."
else
  REINICIO_NECESSARIO=false
  ok "Kernel a correr (${KERNEL_A_CORRER}) já é o mais recente disponível."
fi
warn "CVE-2026-53359 (Januscape): falha KVM/x86 com escape de VM para o host. A correção do HYPERVISOR é responsabilidade do provedor da VPS — este script só mantém o kernel do guest atualizado e reinicia quando necessário."

log "Configurando firewall..."
ufw allow OpenSSH; ufw allow 80; ufw allow 443; ufw --force enable
ok "Firewall configurado (só 22/80/443 públicos — Lyra Central em 127.0.0.1:8080 e Semaphore em 127.0.0.1:${SEMAPHORE_PORT} não são expostos diretamente)"

if ! command -v docker >/dev/null 2>&1; then
  log "Instalando Docker..."
  esperar_apt_livre
  curl -fsSL https://get.docker.com | sh || fatal "Falha ao instalar Docker."
  systemctl enable --now docker
fi
ok "Docker disponível: $(docker --version)"

if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/^v//' | cut -d. -f1)" -lt 20 ]; then
  log "Instalando Node.js 20 (NodeSource, pra Lyra Central)..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || fatal "Falha ao configurar o repositório NodeSource."
  esperar_apt_livre
  apt install -y nodejs || fatal "Falha ao instalar Node.js."
fi
ok "Node.js $(node -v) OK"

systemctl enable --now redis-server
if redis-cli ping >/dev/null 2>&1; then
  ok "Redis respondendo (usado pela Lyra Central e pelo rate limiter do ecossistema)"
else
  fatal "Redis não respondeu a PING local — verifique 'systemctl status redis-server'."
fi

# =============================================================================
# 3. REDE + TRAEFIK ÚNICO
#    UM SÓ Traefik pra tudo nesta VPS — docker provider (descobre Ritmo/
#    Harmonia/Harpa/Eco/Acorde/blackhole404 via labels, como antes) + file
#    provider (rota estática pra Lyra Central, que roda via systemd, fora
#    do Docker). "extra_hosts: host.docker.internal:host-gateway" é o que
#    deixa o Traefik (dentro do Docker) alcançar a Lyra Central (no host).
# =============================================================================
log "Criando rede unificada stack-network..."
docker network create stack-network 2>/dev/null || true

log "Instalando Traefik (único, docker + file provider)..."
mkdir -p /home/ubuntu/traefik/dynamic
cat > /home/ubuntu/traefik/docker-compose.yml << EOF
services:
  traefik:
    image: traefik:${SYNAPSE_TRAEFIK_VERSION}
    container_name: traefik
    restart: always
    extra_hosts:
      - "host.docker.internal:host-gateway"
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=stack-network"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesResolvers.myresolver.acme.httpChallenge=true"
      - "--certificatesResolvers.myresolver.acme.httpChallenge.entrypoint=web"
      - "--certificatesResolvers.myresolver.acme.email=${EMAIL}"
      - "--certificatesResolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./dynamic:/etc/traefik/dynamic:ro
      - traefik_certs:/letsencrypt
    networks:
      - stack-network
volumes:
  traefik_certs:
networks:
  stack-network:
    external: true
EOF

# Rota estática da Lyra Central (systemd, fora do Docker). O arquivo já
# existe ANTES da Lyra estar de pé — Traefik só devolve 502 até ela subir,
# sem problema (o "--providers.file.watch=true" pega mudanças sem restart).
cat > /home/ubuntu/traefik/dynamic/lyra.yml << EOF
http:
  routers:
    lyra:
      rule: "Host(\`${DOMINIO_LYRA}\`)"
      entrypoints:
        - websecure
      tls:
        certResolver: myresolver
      service: lyra
  services:
    lyra:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:8080"
EOF

cd /home/ubuntu/traefik && docker compose up -d
ok "Traefik único activo (docker + file provider) — HTTPS pra tudo nesta VPS"

# =============================================================================
# 3.5 BLACKHOLE 404 — backend genérico que só devolve 404
#    GUIs de Ritmo/Harmonia/Harpa ficam escondidas atrás disso (a Lyra
#    Central NÃO passa por aqui — ela é só API, sem GUI pra esconder).
# =============================================================================
log "Instalando backend blackhole404 (404 genérico para rotas de GUI)..."
mkdir -p /home/ubuntu/blackhole404
cat > /home/ubuntu/blackhole404/nginx.conf << 'EOF'
server {
    listen 80 default_server;
    location / {
        return 404;
    }
}
EOF

cat > /home/ubuntu/blackhole404/docker-compose.yml << EOF
services:
  blackhole404:
    image: nginx:${SYNAPSE_NGINX_VERSION}
    container_name: blackhole404
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - stack-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.blackhole404.loadbalancer.server.port=80"
      - "traefik.http.routers.ritmo-deny.rule=Host(\`${DOMINIO_ERP}\`)"
      - "traefik.http.routers.ritmo-deny.entrypoints=websecure"
      - "traefik.http.routers.ritmo-deny.tls.certresolver=myresolver"
      - "traefik.http.routers.ritmo-deny.priority=1"
      - "traefik.http.routers.ritmo-deny.service=blackhole404"
      - "traefik.http.routers.harmonia-deny.rule=Host(\`${DOMINIO_N8N}\`)"
      - "traefik.http.routers.harmonia-deny.entrypoints=websecure"
      - "traefik.http.routers.harmonia-deny.tls.certresolver=myresolver"
      - "traefik.http.routers.harmonia-deny.priority=1"
      - "traefik.http.routers.harmonia-deny.service=blackhole404"
      - "traefik.http.routers.harpa-deny.rule=Host(\`${DOMINIO_CHAT}\`)"
      - "traefik.http.routers.harpa-deny.entrypoints=websecure"
      - "traefik.http.routers.harpa-deny.tls.certresolver=myresolver"
      - "traefik.http.routers.harpa-deny.priority=1"
      - "traefik.http.routers.harpa-deny.service=blackhole404"
networks:
  stack-network:
    external: true
EOF

cd /home/ubuntu/blackhole404 && docker compose up -d
ok "blackhole404 activo"

# =============================================================================
# 4. LYRA CENTRAL — deploy (systemd + Redis local, já instalados na fase 2)
#    Clona github.com/nomen-me/lyra, delega pro scripts/install.sh do
#    próprio repo, e conecta na rota do Traefik já criada na fase 3.
# =============================================================================
log "Instalando a Lyra Central (github.com/${GITHUB_ORG}/lyra)..."
# 2. CLONAR / ATUALIZAR github.com/nomen-me/lyra
# =============================================================================
if [ -d "${LYRA_APP_DIR}/.git" ]; then
  log "Repositório já existe em ${LYRA_APP_DIR} — atualizando (git pull --ff-only)..."
  if ! (cd "$LYRA_APP_DIR" && sudo -u "$APP_USER" git pull --ff-only 2>&1 | sed "s|${GITHUB_TOKEN}|***|g"); then
    err "git pull falhou — verifique conflitos manualmente em ${LYRA_APP_DIR}. Seguindo com o código já presente."
  fi
elif [ -f "${LYRA_APP_DIR}/scripts/install.sh" ]; then
  # Já tem o código de uma execução anterior (o achatamento abaixo troca o
  # clone por uma cópia sem .git, então não tem como dar "git pull" aqui —
  # e não tem problema, porque o clone original já é sempre --depth 1, e
  # atualizações de código são feitas via scripts/deploy.sh, não por este
  # script). Rodar "git clone" de novo aqui só ia falhar (pasta não-vazia).
  ok "Código da Lyra Central já está em ${LYRA_APP_DIR} de uma execução anterior — mantendo. Pra atualizar o código, use scripts/deploy.sh (ver resumo final)."
else
  log "Clonando github.com/${GITHUB_ORG}/lyra em ${LYRA_APP_DIR}..."
  mkdir -p "$(dirname "$LYRA_APP_DIR")"
  saida=$(git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/lyra.git" "$LYRA_APP_DIR" 2>&1) \
    || { echo "$saida" | sed "s|${GITHUB_TOKEN}|***|g" >&2; fatal "Falha ao clonar github.com/${GITHUB_ORG}/lyra. Confirma se GITHUB_TOKEN tem acesso ao repositório."; }
  id -u "$APP_USER" >/dev/null 2>&1 && chown -R "${APP_USER}:${APP_USER}" "$LYRA_APP_DIR"
fi
ok "Código da Lyra Central em ${LYRA_APP_DIR}"

# O repo pode ter uma pasta extra por dentro (ex: se o clone local que virou
# o repo já nasceu com um subdiretório "lyra-central-api/" e isso foi
# commitado assim). Em vez de assumir "scripts/install.sh" direto na raiz,
# procuramos de verdade e corrigimos LYRA_APP_DIR se precisar — mesma lógica
# usada pra achar o pyproject.toml do brazil-nf.
if [ ! -f "${LYRA_APP_DIR}/scripts/install.sh" ]; then
  warn "scripts/install.sh não está direto em ${LYRA_APP_DIR} — procurando dentro do repositório..."
  CANDIDATO="$(find "$LYRA_APP_DIR" -maxdepth 4 -path '*/scripts/install.sh' 2>/dev/null | head -1)"

  # Fallback: o repo às vezes tem só um .zip cru subido ("Add files via
  # upload"), sem o código extraído/commitado de verdade. Se for o caso,
  # extrai aqui mesmo em vez de travar a operação — mas isso é só uma
  # muleta; o certo é a Nomen commitar os arquivos extraídos no repo.
  if [ -z "$CANDIDATO" ]; then
    ZIP_ENCONTRADO="$(find "$LYRA_APP_DIR" -maxdepth 2 -name '*.zip' -not -path '*/.git/*' 2>/dev/null | head -1)"
    if [ -n "$ZIP_ENCONTRADO" ]; then
      warn "Não achei código extraído, mas achei '${ZIP_ENCONTRADO}' — o repo parece ter só o .zip cru subido, sem commit dos arquivos de verdade. Extraindo automaticamente (isso é uma muleta; o certo é vocês commitarem os arquivos extraídos no repo, não o .zip)."
      if command -v unzip >/dev/null 2>&1 || apt install -y unzip >/dev/null 2>&1; then
        EXTRACT_TMP="$(mktemp -d)"
        unzip -o "$ZIP_ENCONTRADO" -d "$EXTRACT_TMP" >/dev/null 2>&1
        CANDIDATO="$(find "$EXTRACT_TMP" -maxdepth 4 -path '*/scripts/install.sh' 2>/dev/null | head -1)"
        if [ -n "$CANDIDATO" ]; then
          RAIZ_REAL="$(dirname "$(dirname "$CANDIDATO")")"
          rm -rf "$LYRA_APP_DIR"; mkdir -p "$LYRA_APP_DIR"
          cp -a "${RAIZ_REAL}/." "$LYRA_APP_DIR/"
          CANDIDATO="$LYRA_APP_DIR/scripts/install.sh"  # já achatado, path final
        fi
        rm -rf "$EXTRACT_TMP"
      fi
    fi
  fi

  # ACHATAMENTO UNIVERSAL: não importa se o scripts/install.sh apareceu
  # aninhado dentro do próprio "git clone" (ex: o repo tem uma pasta
  # "lyra-central-api/" commitada dentro da raiz, em vez de flat) ou veio
  # do fallback do zip acima — sempre convergimos pra
  # ${LYRA_APP_DIR}/scripts/install.sh, um nível só, sem exceção. Isso
  # elimina o "path duplicado" de vez, seja qual for a origem da bagunça.
  if [ -n "$CANDIDATO" ]; then
    RAIZ_REAL="$(dirname "$(dirname "$CANDIDATO")")"
    if [ "$RAIZ_REAL" != "$LYRA_APP_DIR" ]; then
      warn "scripts/install.sh está aninhado em '${RAIZ_REAL}' — achatando pra '${LYRA_APP_DIR}' direto."
      FLAT_TMP="$(mktemp -d)"
      cp -a "${RAIZ_REAL}/." "$FLAT_TMP/"
      rm -rf "$LYRA_APP_DIR"; mkdir -p "$LYRA_APP_DIR"
      cp -a "${FLAT_TMP}/." "$LYRA_APP_DIR/"
      rm -rf "$FLAT_TMP"
    fi
  fi

  FOUND_INSTALL="$([ -f "${LYRA_APP_DIR}/scripts/install.sh" ] && echo "${LYRA_APP_DIR}/scripts/install.sh")"

  if [ -n "$FOUND_INSTALL" ]; then
    ok "scripts/install.sh confirmado em ${LYRA_APP_DIR}/scripts/install.sh (achatado, sem aninhamento)"
  else
    err "Não encontrei scripts/install.sh em nenhum lugar dentro de ${LYRA_APP_DIR} (nem dentro de um .zip). Isto é o que o clone realmente trouxe:"
    echo "----------------------------------------------------------------"
    find "$LYRA_APP_DIR" -maxdepth 2 -not -path '*/.git*' 2>/dev/null
    echo "----------------------------------------------------------------"
    echo "Total de arquivos (fora .git): $(find "$LYRA_APP_DIR" -type f -not -path '*/.git/*' 2>/dev/null | wc -l)"
    (cd "$LYRA_APP_DIR" && echo "Último commit: $(git log -1 --oneline 2>/dev/null || echo 'não foi possível ler')")
    fatal "Confirma no navegador se github.com/${GITHUB_ORG}/lyra realmente tem 'scripts/', 'src/' e 'package.json' commitados na raiz do branch padrão (não só um .zip solto) — a listagem acima é exatamente o que o clone trouxe."
  fi
fi

# Garante o dono certo em TODO o LYRA_APP_DIR, sempre — não só no clone novo.
# O fallback de extração de .zip acima roda como root e faz "cp -a" (que
# preserva o dono de quem copiou, ou seja, root), então sem isso a pasta
# data/ fica sem permissão de escrita pro usuário que o systemd realmente
# usa (APP_USER) — e a API quebra com EACCES ao tentar gravar
# data/tenants.dev.json em modo SECRETS_PROVIDER=env.
id -u "$APP_USER" >/dev/null 2>&1 && chown -R "${APP_USER}:${APP_USER}" "$LYRA_APP_DIR"

# =============================================================================
# 3. .env — só na primeira vez (reruns preservam o que já existe, ADMIN_API_KEY
#    nunca é trocada sozinha: trocar invalidaria os tenants já provisionados)
# =============================================================================
if [ ! -f "${LYRA_APP_DIR}/.env" ]; then
  log "Gerando .env pela primeira vez..."
  ADMIN_API_KEY="${ADMIN_API_KEY:-$(openssl rand -hex 32)}"
  cat > "${LYRA_APP_DIR}/.env" << EOF
PORT=8080
NODE_ENV=development
LOG_LEVEL=info

GEMINI_API_KEY=${GEMINI_API_KEY}
GEMINI_MODEL=${GEMINI_MODEL}

SECRETS_PROVIDER=env

ADMIN_API_KEY=${ADMIN_API_KEY}

REDIS_URL=redis://localhost:6379

TOKENS_PER_ATTENDANCE=1000
RECARGAS_MAXIMAS_MES=3

RATE_LIMIT_WINDOW_MS=60000
RATE_LIMIT_MAX_REQUESTS=60

TIMEOUT_CONSULTAR_FRETE_MS=5000
TIMEOUT_CONSULTAR_SALDO_MS=4000
TIMEOUT_CONSULTAR_ESTOQUE_MS=4000
EOF
  chmod 600 "${LYRA_APP_DIR}/.env"
  id -u "$APP_USER" >/dev/null 2>&1 && chown "${APP_USER}:${APP_USER}" "${LYRA_APP_DIR}/.env"

  # NÃO trunca de novo aqui — o arquivo já foi criado (e populado com
  # DOMINIO_BASE/TENANT_ID/EMAIL/SENHA/BASICAUTH_*) na seção 1. Truncar de
  # novo apagava justamente o TENANT_ID, quebrando o onboarding automático
  # do passo 11 e qualquer tentativa manual de retomá-lo depois (bug real,
  # já reproduzido: TENANT_ID ficava vazio em /root/nomen_credentials.txt).
  touch "$CRED_FILE"; chmod 600 "$CRED_FILE"
  cat >> "$CRED_FILE" << EOF
LYRA_CENTRAL_URL=https://${DOMINIO_LYRA}
ADMIN_API_KEY=${ADMIN_API_KEY}
EOF
  ok ".env criado — ADMIN_API_KEY gerada e salva em ${CRED_FILE} (chmod 600)"

  warn "NODE_ENV=development + SECRETS_PROVIDER=env: as API Keys de cada tenant"
  warn "ficam num arquivo local (data/tenants.dev.json), não criptografado."
  warn "O próprio scripts/install.sh do repo BLOQUEIA subir com NODE_ENV=production"
  warn "nesse modo — de propósito. Pra produção de verdade, primeiro implemente"
  warn "gcp_secret_manager ou vault em src/services/secrets.js (ainda são stubs,"
  warn "conforme o README do repo), troque SECRETS_PROVIDER e NODE_ENV no .env,"
  warn "e rode este script de novo (ele não sobrescreve o .env que já existe —"
  warn "edite manualmente antes de rerodar)."
else
  ok ".env já existe em ${LYRA_APP_DIR} — mantido como está (mesmo comportamento do install.sh do repo)"
fi

# =============================================================================
# 4. DELEGAR PRO scripts/install.sh DO PRÓPRIO REPO
#    (systemd, npm ci, checagens de segurança — não duplicamos essa lógica)
# =============================================================================
log "Rodando scripts/install.sh do repo (systemd + npm ci)..."
if APP_USER="$APP_USER" APP_DIR="$LYRA_APP_DIR" bash "${LYRA_APP_DIR}/scripts/install.sh"; then
  ok "lyra-central-api ativo via systemd"
else
  fatal "install.sh do repo falhou — veja a saída acima (ex: NODE_ENV=production com SECRETS_PROVIDER=env é bloqueado de propósito)."
fi

# O scripts/install.sh acima roda DENTRO deste script — ou seja, como root
# (todo este script exige root), não como ${APP_USER}. Se ele criar a pasta
# data/ nesse meio-tempo (ex: durante "npm ci" ou no primeiro boot da API pra
# preparar tenants.dev.json em SECRETS_PROVIDER=env), essa pasta nasce dona
# de root — por cima do chown que já fizemos na Seção 2 (que rodou ANTES de
# data/ existir, então não pegou essa pasta). Sem repetir o chown aqui, o
# serviço systemd (que roda como ${APP_USER}) recebe EACCES ao tentar abrir
# data/tenants.dev.json em qualquer chamada a /admin/tenants.
mkdir -p "${LYRA_APP_DIR}/data"
id -u "$APP_USER" >/dev/null 2>&1 && chown -R "${APP_USER}:${APP_USER}" "$LYRA_APP_DIR"
systemctl restart lyra-central-api 2>/dev/null || warn "Não consegui reiniciar lyra-central-api agora — reinicie manualmente se necessário."

# =============================================================================

# Captura a chave gerada, direto do .env — nada de copiar/colar manual.
LYRA_ADMIN_API_KEY="$(grep '^ADMIN_API_KEY=' "${LYRA_APP_DIR}/.env" | cut -d'=' -f2-)"
LYRA_CENTRAL_URL="https://${DOMINIO_LYRA}"
salvar_credencial "LYRA_CENTRAL_URL" "$LYRA_CENTRAL_URL"
salvar_credencial "LYRA_ADMIN_API_KEY" "$LYRA_ADMIN_API_KEY"
ok "Lyra Central no ar — chave capturada automaticamente, sem precisar copiar nada"

# 4. ERPNEXT 15 (RITMO)
# =============================================================================
log "Instalando ERPNext 15 (Ritmo)..."
cd /home/ubuntu
[ -d frappe_docker ] || git clone https://github.com/frappe/frappe_docker || fatal "Falha ao clonar frappe_docker."
cd frappe_docker

ERPNEXT_VERSION="${SYNAPSE_ERPNEXT_VERSION}"
ok "ERPNext: usando ${ERPNEXT_VERSION} (fixo na baseline — sem resolução dinâmica)"
cat > .env << EOF
ERPNEXT_VERSION=${ERPNEXT_VERSION}
DB_PASSWORD=${SENHA}
SITES=${DOMINIO_ERP}
FRAPPE_SITE_NAME_HEADER=${DOMINIO_ERP}
LETSENCRYPT_EMAIL=${EMAIL}
SITES_RULE=Host(\`${DOMINIO_ERP}\`)
EOF

cat > overrides/compose.stack-network.yaml << EOF
services:
  frontend:
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.ritmo.rule=Host(\`${DOMINIO_ERP}\`) && PathPrefix(\`/api\`)"
      - "traefik.http.routers.ritmo.entrypoints=websecure"
      - "traefik.http.routers.ritmo.tls.certresolver=myresolver"
      - "traefik.http.routers.ritmo.priority=10"
      - "traefik.http.services.ritmo.loadbalancer.server.port=8080"
  backend: { networks: [stack-network] }
  db: { networks: [stack-network] }
  redis-cache: { networks: [stack-network] }
  redis-queue: { networks: [stack-network] }
  queue-short: { networks: [stack-network] }
  queue-long: { networks: [stack-network] }
  scheduler: { networks: [stack-network] }
  websocket: { networks: [stack-network] }
networks:
  stack-network:
    external: true
EOF

docker compose --project-name ritmo -f compose.yaml \
  -f overrides/compose.mariadb.yaml -f overrides/compose.redis.yaml \
  -f overrides/compose.stack-network.yaml up -d

log "Aguardando MariaDB ficar saudável..."
TENTATIVAS=0
until docker exec ritmo-db-1 mariadb-admin ping -h localhost --silent 2>/dev/null; do
  TENTATIVAS=$((TENTATIVAS+1))
  if [ $TENTATIVAS -ge 30 ]; then
    err "MariaDB não respondeu em 60s. Saída de 'docker logs ritmo-db-1 --tail 50':"
    docker logs ritmo-db-1 --tail 50 2>&1
    fatal "MariaDB não ficou saudável — ver logs acima."
  fi
  sleep 2
done
ok "MariaDB saudável"
log "Aguardando backend ERPNext (15s de margem)..."; sleep 15

if docker exec ritmo-backend-1 test -d "/home/frappe/frappe-bench/sites/${DOMINIO_ERP}" 2>/dev/null; then
  ok "Site ERPNext já existia — reaproveitando"
else
  log "Criando site ERPNext..."
  if docker compose --project-name ritmo exec -T backend bench new-site "${DOMINIO_ERP}" \
    --db-root-password "${SENHA}" --admin-password "${SENHA}" --db-host db --install-app erpnext; then
    ok "Site ERPNext criado"
  else
    fatal "Falha ao criar o site ERPNext. Verifica 'docker logs ritmo-backend-1'. Instalação interrompida de propósito."
  fi
  docker compose --project-name ritmo exec -T backend bench --site "${DOMINIO_ERP}" enable-scheduler
fi

log "Liberando utilizador da base de dados para qualquer host da rede..."
DB_USER=$(docker compose --project-name ritmo exec -T backend bash -c "
  cd /home/frappe/frappe-bench &&
  grep -o '\"db_name\": \"[^\"]*\"' sites/${DOMINIO_ERP}/site_config.json | cut -d'\"' -f4
" | tr -d '\r')
if [ -n "$DB_USER" ]; then
  CURRENT_HOST=$(docker exec ritmo-db-1 mariadb -u root -p"${SENHA}" -N -e "
    SELECT host FROM mysql.user WHERE user='${DB_USER}' AND host != '%' LIMIT 1;" 2>/dev/null | tr -d '\r')
  if [ -n "$CURRENT_HOST" ]; then
    docker exec ritmo-db-1 mariadb -u root -p"${SENHA}" -e "
      RENAME USER '${DB_USER}'@'${CURRENT_HOST}' TO '${DB_USER}'@'%'; FLUSH PRIVILEGES;" 2>/dev/null \
      && ok "Utilizador da BD liberado para qualquer host." \
      || warn "Não foi possível liberar o host do utilizador automaticamente."
  fi
fi
ok "ERPNext instalado em https://${DOMINIO_ERP}"

log "Reiniciando workers do ERPNext..."
docker compose --project-name ritmo restart queue-short queue-long websocket scheduler
sleep 5

log "Instalando módulo fiscal Brazil NF (github.com/${GITHUB_ORG}/brazil-nf)..."
if clonar_repo_nomen_pinned "brazil-nf" "/home/ubuntu/brazil_nf_src" "${SYNAPSE_BRAZIL_NF_REF}"; then
  # O repo hoje (29/set/2026, commit cd1efcac) não traz o app aberto — traz só
  # um brazil_nf.zip na raiz (extrai pra brazil_nf/brazil_nf/hooks.py +
  # brazil_nf/pyproject.toml, layout normal de app Frappe UMA VEZ
  # descompactado). O próprio INSTALL.md do app assume repo aberto (bench
  # get-app direto). Descompacta primeiro se achar zip solto na raiz; se um
  # dia o repo passar a versionar o app aberto (sem zip), o find já resolve
  # sem precisar mexer aqui de novo.
  ZIP_BRAZIL_NF="$(find /home/ubuntu/brazil_nf_src -maxdepth 1 -name '*.zip' | head -1)"
  if [ -n "$ZIP_BRAZIL_NF" ]; then
    command -v unzip >/dev/null 2>&1 || apt install -y unzip >/dev/null 2>&1
    unzip -o "$ZIP_BRAZIL_NF" -d /home/ubuntu/brazil_nf_src >/dev/null 2>&1
  fi
  APP_DIR="$(find /home/ubuntu/brazil_nf_src -maxdepth 4 \( -name 'pyproject.toml' -o -name 'setup.py' \) -exec dirname {} \; | head -1)"
  if [ -z "$APP_DIR" ]; then
    warn "Não achei pyproject.toml/setup.py no repositório brazil-nf — tentando pelo diretório do hooks.py (layout sem packaging próprio)."
    APP_DIR="$(find /home/ubuntu/brazil_nf_src -maxdepth 6 -name 'hooks.py' -exec dirname {} \; | head -1)"
  fi
  if [ -z "$APP_DIR" ]; then
    err "Não encontrei hooks.py nem pyproject.toml/setup.py no repositório brazil-nf — instalação segue sem o módulo fiscal."
  else
    docker exec -u root ritmo-backend-1 rm -rf /home/frappe/frappe-bench/apps/brazil_nf 2>/dev/null || true
    docker exec -u root ritmo-backend-1 mkdir -p /home/frappe/frappe-bench/apps/brazil_nf
    docker cp "${APP_DIR}/." ritmo-backend-1:/home/frappe/frappe-bench/apps/brazil_nf/
    docker exec -u root ritmo-backend-1 chown -R frappe:frappe /home/frappe/frappe-bench/apps/brazil_nf
    if docker exec -u frappe ritmo-backend-1 bash -c "
      cd /home/frappe/frappe-bench && ./env/bin/pip install -e apps/brazil_nf &&
      grep -qxF 'brazil_nf' sites/apps.txt || echo 'brazil_nf' >> sites/apps.txt &&
      bench --site ${DOMINIO_ERP} install-app brazil_nf &&
      bench --site ${DOMINIO_ERP} migrate && bench --site ${DOMINIO_ERP} clear-cache"; then
      docker compose --project-name ritmo restart
      sleep 5
      # O bloco acima só prova que os comandos saíram com exit 0 — não prova
      # que o Frappe realmente registrou o app como instalado no site. Só
      # confia depois de perguntar pro próprio Frappe (list-apps), não pelo
      # exit code da cadeia anterior.
      if docker exec -u frappe ritmo-backend-1 bash -c "cd /home/frappe/frappe-bench && bench --site ${DOMINIO_ERP} list-apps" 2>/dev/null | grep -qx "brazil_nf"; then
        relatorio "PASS" "Brazil NF" "instalado e confirmado em 'bench list-apps' do site ${DOMINIO_ERP}"
      else
        relatorio "FAIL" "Brazil NF" "bench install-app terminou sem erro, mas brazil_nf NÃO aparece em 'bench list-apps' do site ${DOMINIO_ERP} — instalação do módulo fiscal não confirmada."
      fi
    else
      err "Falha ao instalar Brazil NF — corre 'docker logs ritmo-backend-1 --tail 100' depois."
    fi
  fi
else
  err "Falha ao clonar github.com/${GITHUB_ORG}/brazil-nf — confirma se GITHUB_TOKEN tem acesso ao repositório. Instalação segue sem o módulo fiscal."
fi

# =============================================================================
# 5. RITMO — PROVISIONAMENTO (CORS/CSRF/roles/DocTypes/usuário de automação)
#    (fusão do antigo 1_provisionar_ritmo.sh — agora com domínio dinâmico e
#    sem "bench console"; tudo via "bench execute")
# =============================================================================
log "Provisionando Ritmo (CORS, CSRF, roles, DocTypes, usuário de automação)..."

docker exec ritmo-backend-1 bench --site "${DOMINIO_ERP}" set-config allow_cors "${ORIGEM_PAINEL}"
docker exec ritmo-backend-1 bench --site "${DOMINIO_ERP}" set-config session_cookie_samesite "Lax"
ok "CORS liberado para ${ORIGEM_PAINEL} e session_cookie_samesite=Lax"

ritmo_exec > /tmp/synapse_csrf.log <<PYEOF
def main():
    import frappe
    if not frappe.db.exists("Server Script", "synapse_csrf_token"):
        frappe.get_doc({
            "doctype": "Server Script", "name": "synapse_csrf_token",
            "script_type": "API", "api_method": "synapse_csrf_token", "allow_guest": 0,
            "script": "frappe.response['message'] = frappe.local.session.data.csrf_token"
        }).insert(ignore_permissions=True)
        print("Server Script 'synapse_csrf_token' criado -> GET /api/method/synapse_csrf_token")
    else:
        print("Server Script 'synapse_csrf_token' já existia")
    frappe.db.commit()
PYEOF
ok "Endpoint de CSRF token pronto (se 'Server Script' estiver desabilitado no site, habilite em Configurações do Sistema)"

ritmo_exec > /tmp/synapse_caixa_offline.log <<PYEOF
def main():
    import frappe
    # Corpo real dos dois endpoints do Caixa offline. Executam dentro do
    # sandbox do Server Script do Frappe (mesmo mecanismo do
    # synapse_csrf_token acima) — por isso não têm "import frappe": lá
    # dentro "frappe" já vem pronto no escopo, e só o que a whitelist do
    # safe_exec permite (frappe.*, builtins comuns) está disponível.
    SCRIPT_SINCRONIZAR = """
pos_profile = frappe.form_dict.get('pos_profile')
if not pos_profile:
    frappe.throw('Parametro pos_profile e obrigatorio')
if not frappe.db.exists('POS Profile', pos_profile):
    frappe.throw('POS Profile nao encontrado: ' + pos_profile)

linhas_autorizadas = frappe.get_all(
    'POS Profile User',
    filters={'parent': pos_profile, 'parenttype': 'POS Profile'},
    fields=['user']
)
restricao_configurada = len(linhas_autorizadas) > 0
usuarios_ids = [r.user for r in linhas_autorizadas]

usuarios = []
funcionarios = []
if restricao_configurada:
    solicitante = frappe.session.user
    pode_solicitar = (
        solicitante in usuarios_ids
        or 'System Manager' in frappe.get_roles(solicitante)
        or 'Synapse Administrador' in frappe.get_roles(solicitante)
    )
    if not pode_solicitar:
        frappe.throw(
            'Voce nao esta na lista de usuarios autorizados deste POS Profile',
            frappe.PermissionError
        )
    funcionarios = frappe.get_all(
        'Employee',
        filters={'user_id': ['in', usuarios_ids], 'status': 'Active'},
        fields=['name', 'employee_name', 'user_id', 'modified',
                'synapse_pin_hash', 'synapse_pin_salt', 'synapse_pin_kdf_iteracoes']
    )
    for f in funcionarios:
        usuarios.append({
            'user_id': f.user_id,
            'employee': f.name,
            'nome_exibicao': f.employee_name,
            'roles': frappe.get_roles(f.user_id),
            'pin_definido': bool(f.synapse_pin_hash),
            'pin_hash': f.synapse_pin_hash or None,
            'pin_salt': f.synapse_pin_salt or None,
            'pin_kdf_iteracoes': int(f.synapse_pin_kdf_iteracoes) if f.synapse_pin_kdf_iteracoes else None,
        })

pos_profile_modified = frappe.db.get_value('POS Profile', pos_profile, 'modified')
carimbos = [str(pos_profile_modified)] + [str(f.modified) for f in funcionarios]
versao = max(carimbos)

frappe.response['message'] = {
    'pos_profile': pos_profile,
    'sincronizado_em': frappe.utils.now(),
    'versao': versao,
    'restricao_configurada': restricao_configurada,
    'usuarios_autorizados': usuarios,
}
"""
    SCRIPT_DEFINIR_PIN = """
pin_hash = frappe.form_dict.get('pin_hash')
pin_salt = frappe.form_dict.get('pin_salt')
pin_kdf = frappe.form_dict.get('pin_kdf_iteracoes')

if not pin_hash or not pin_salt or not pin_kdf:
    frappe.throw('pin_hash, pin_salt e pin_kdf_iteracoes sao obrigatorios')

if len(pin_hash) < 32 or pin_hash.isdigit():
    frappe.throw('pin_hash nao parece ser um hash valido — operacao recusada por seguranca')

try:
    iteracoes = int(pin_kdf)
except (TypeError, ValueError):
    frappe.throw('pin_kdf_iteracoes precisa ser um numero inteiro')

emp = frappe.get_all('Employee', filters={'user_id': frappe.session.user}, fields=['name'], limit_page_length=1)
if not emp:
    frappe.throw('Nenhum funcionario do Ritmo esta vinculado a este usuario — nao e possivel definir PIN offline')

doc = frappe.get_doc('Employee', emp[0].name)
doc.synapse_pin_hash = pin_hash
doc.synapse_pin_salt = pin_salt
doc.synapse_pin_kdf_iteracoes = iteracoes
doc.synapse_pin_definido_em = frappe.utils.now()
doc.save(ignore_permissions=True)
frappe.db.commit()

frappe.response['message'] = {'ok': True, 'employee': doc.name, 'definido_em': str(doc.synapse_pin_definido_em)}
"""
    scripts = {
        "synapse_sincronizar_caixa": SCRIPT_SINCRONIZAR,
        "synapse_definir_pin": SCRIPT_DEFINIR_PIN,
    }
    for nome, corpo in scripts.items():
        if frappe.db.exists("Server Script", nome):
            doc = frappe.get_doc("Server Script", nome)
            doc.script = corpo
            doc.save(ignore_permissions=True)
            print(f"Server Script '{nome}' atualizado")
        else:
            frappe.get_doc({
                "doctype": "Server Script", "name": nome,
                "script_type": "API", "api_method": nome, "allow_guest": 0,
                "script": corpo
            }).insert(ignore_permissions=True)
            print(f"Server Script '{nome}' criado -> /api/method/{nome}")
    frappe.db.commit()
PYEOF
ok "Endpoints do Caixa offline prontos: /api/method/synapse_sincronizar_caixa (GET) e /api/method/synapse_definir_pin (POST)"

ritmo_exec > /tmp/synapse_roles.log <<PYEOF
def main():
    import frappe
    for role in ["Synapse Administrador", "Synapse Lojista", "Synapse Funcionário"]:
        if not frappe.db.exists("Role", role):
            frappe.get_doc({"doctype": "Role", "role_name": role, "desk_access": 0}).insert(ignore_permissions=True)
            print(f"criada: {role}")
        else:
            print(f"já existia: {role}")
    frappe.db.commit()
PYEOF
ok "Roles Synapse garantidas"

# =============================================================================
# 8.5 USUÁRIO DE LOGIN DO PAINEL (mesmo EMAIL/SENHA de /root/nomen_credentials.txt)
#    O "bench new-site --admin-password" (seção anterior) só define a senha
#    do usuário especial "Administrator" do Frappe — que não tem esse e-mail.
#    O Painel faz login chamando /api/method/login com o EMAIL/SENHA salvos
#    nas credenciais (ver synapse_painel.html: Ritmo.login()), então sem
#    criar explicitamente um User com esse e-mail, login nenhum funciona —
#    é exatamente essa a conta que faltava.
# =============================================================================
log "Criando usuário de login do Painel (${EMAIL})..."
ritmo_exec > /tmp/synapse_admin_user.log <<PYEOF
def main():
    import frappe
    email = "${EMAIL}"
    roles_necessarias = ["System Manager", "Synapse Administrador"]
    if not frappe.db.exists("User", email):
        user = frappe.get_doc({
            "doctype": "User", "email": email, "first_name": "${NOME_LOJA}",
            "user_type": "System User", "send_welcome_email": 0,
            "new_password": "${SENHA}",
            "roles": [{"role": r} for r in roles_necessarias]
        })
        user.insert(ignore_permissions=True)
        print(f"Usuário {email} criado com roles {roles_necessarias}")
    else:
        user = frappe.get_doc("User", email)
        ja_tem = {r.role for r in user.roles}
        for role in roles_necessarias:
            if role not in ja_tem:
                user.append("roles", {"role": role})
        user.new_password = "${SENHA}"
        user.save(ignore_permissions=True)
        print(f"Usuário {email} já existia — roles/senha confirmadas")
    frappe.db.commit()
PYEOF
if grep -qE "criad|confirmadas" /tmp/synapse_admin_user.log; then
  ok "Usuário ${EMAIL} pronto no Ritmo com System Manager + Synapse Administrador — é essa a conta que loga no Painel"
else
  err "Não consegui confirmar a criação do usuário ${EMAIL} no Ritmo — veja /tmp/synapse_admin_user.log. Sem isso, o login no Painel não vai funcionar."
fi

ritmo_exec > /tmp/synapse_tema.log <<PYEOF
def main():
    import frappe
    if not frappe.db.exists("DocType", "Synapse Tema Loja"):
        frappe.get_doc({
            "doctype": "DocType", "name": "Synapse Tema Loja", "module": "Custom", "custom": 1,
            "autoname": "field:nome_tema",
            "fields": [
                {"fieldname": "nome_tema", "label": "Nome do Tema", "fieldtype": "Data", "reqd": 1, "unique": 1},
                {"fieldname": "ativo", "label": "Ativo", "fieldtype": "Check", "default": "0"},
                {"fieldname": "configuracoes_json", "label": "Configurações (JSON)", "fieldtype": "Code", "options": "JSON"}
            ],
            "permissions": [
                {"role": "System Manager", "read": 1, "write": 1, "create": 1, "delete": 1},
                {"role": "Synapse Lojista", "read": 1, "write": 1, "create": 1}
            ]
        }).insert(ignore_permissions=True)
        print("DocType 'Synapse Tema Loja' criado")
    else:
        print("DocType 'Synapse Tema Loja' já existia")
    frappe.db.commit()
PYEOF
ok "DocType 'Synapse Tema Loja' garantido"

ritmo_exec > /tmp/synapse_cred.log <<PYEOF
def main():
    import frappe, json
    schema = json.loads(r'''
{
  "doctype": "DocType",
  "name": "Synapse Credencial Externa",
  "module": "Synapse",
  "custom": 1,
  "istable": 0,
  "issingle": 0,
  "track_changes": 1,
  "autoname": "field:credencial_id",
  "sort_field": "modified",
  "sort_order": "DESC",
  "fields": [
    {
      "fieldname": "credencial_id",
      "fieldtype": "Data",
      "label": "ID",
      "unique": 1,
      "reqd": 1,
      "description": "Ex.: melhorenvio, infinitepay, gmc, gads, msads, meta, whatsapp, telegram, sms — um registro por provedor conectado."
    },
    {
      "fieldname": "provedor",
      "fieldtype": "Data",
      "label": "Provedor",
      "reqd": 1,
      "description": "Chave usada pelo painel (plataforma). Ex.: 'gmc', 'melhorenvio', 'whatsapp'."
    },
    {
      "fieldname": "categoria",
      "fieldtype": "Select",
      "label": "Categoria",
      "reqd": 1,
      "options": "marketing\nenvio\npagamento\natendimento"
    },
    {
      "fieldname": "status",
      "fieldtype": "Select",
      "label": "Status",
      "default": "desconectado",
      "options": "desconectado\nconectado\nexpirado\nerro"
    },
    {
      "fieldname": "conta_conectada",
      "fieldtype": "Data",
      "label": "Conta Conectada",
      "description": "Nome/handle exibido ao lojista (nunca um ID técnico). Ex.: 'joao@gmail.com', '@minhaloja'."
    },
    {
      "fieldname": "sec_credenciais",
      "fieldtype": "Section Break",
      "label": "Credenciais (nunca lidas pelo painel)"
    },
    {
      "fieldname": "access_token",
      "fieldtype": "Password",
      "label": "Access Token"
    },
    {
      "fieldname": "refresh_token",
      "fieldtype": "Password",
      "label": "Refresh Token"
    },
    {
      "fieldname": "expira_em",
      "fieldtype": "Datetime",
      "label": "Token Expira Em",
      "description": "Usado pelo workflow de renovação automática pra saber quando reautenticar."
    },
    {
      "fieldname": "metadados",
      "fieldtype": "Long Text",
      "label": "Metadados (JSON)",
      "description": "Qualquer campo específico do provedor que não mereça virar coluna própria."
    },
    {
      "fieldname": "sec_cache",
      "fieldtype": "Section Break",
      "label": "Cache de leitura (o painel lê só isto)"
    },
    {
      "fieldname": "saldo",
      "fieldtype": "Data",
      "label": "Saldo / Crédito"
    },
    {
      "fieldname": "consumo_diario",
      "fieldtype": "Data",
      "label": "Consumo Diário"
    },
    {
      "fieldname": "roas",
      "fieldtype": "Data",
      "label": "ROAS Geral"
    },
    {
      "fieldname": "cache_atualizado_em",
      "fieldtype": "Datetime",
      "label": "Cache Atualizado Em"
    }
  ],
  "permissions": [
    {
      "role": "System Manager",
      "read": 1,
      "write": 1,
      "create": 1,
      "delete": 1
    },
    {
      "role": "Synapse Automação",
      "read": 1,
      "write": 1,
      "create": 1,
      "if_owner": 0,
      "print": 0,
      "email": 0,
      "export": 0,
      "report": 0,
      "description": "Papel de serviço usado só pela API key do Harmonia — não deve existir papel que dê acesso de leitura direta a access_token/refresh_token pra usuário humano nenhum, nem admin da loja."
    }
  ]
}
''')
    if not frappe.db.exists("Module Def", schema["module"]):
        frappe.get_doc({"doctype": "Module Def", "module_name": schema["module"], "app_name": "frappe", "custom": 1}).insert(ignore_permissions=True)
    if frappe.db.exists("DocType", schema["name"]):
        frappe.delete_doc("DocType", schema["name"], force=True, ignore_permissions=True)
        print("DocType '" + schema["name"] + "' existia com schema antigo — recriado com o schema oficial")
    else:
        print("DocType '" + schema["name"] + "' criado com o schema oficial")
    frappe.get_doc(schema).insert(ignore_permissions=True)
    frappe.db.commit()
PYEOF
ok "DocType 'Synapse Credencial Externa' garantido com o schema oficial (é aqui que o painel grava Melhor Envio/InfinitePay/99)"

ritmo_exec > /tmp/synapse_fields.log <<PYEOF
def main():
    import frappe
    from frappe.custom.doctype.custom_field.custom_field import create_custom_fields
    create_custom_fields({
        "Company": [
            {"fieldname": "synapse_certificado_a1", "label": "Certificado A1 (arquivo)", "fieldtype": "Attach", "insert_after": "company_name"},
            {"fieldname": "synapse_certificado_senha", "label": "Senha do Certificado A1", "fieldtype": "Password", "insert_after": "synapse_certificado_a1"},
            # Campos do formulário de Empresa (aba Fiscal). CNPJ NÃO tem campo
            # novo aqui — usa o "tax_id" nativo do Company, que já existe pra
            # isso (confirmado no schema real do ERPNext v15). Existe também
            # um "cnpj"/"inscricao_estadual" em NF Company Settings (doctype
            # do app brazil_nf, escopo diferente — configuração específica do
            # importador de NF-e). Não sincronizamos os dois automaticamente
            # aqui; é uma decisão em aberto, não uma omissão silenciosa.
            {"fieldname": "synapse_nome_fantasia", "label": "Nome Fantasia", "fieldtype": "Data", "insert_after": "synapse_certificado_senha"},
            {"fieldname": "synapse_endereco", "label": "Endereço", "fieldtype": "Data", "insert_after": "synapse_nome_fantasia"},
            {"fieldname": "synapse_cnae", "label": "CNAE Principal", "fieldtype": "Data", "insert_after": "synapse_endereco"},
            {"fieldname": "synapse_ie", "label": "Inscrição Estadual", "fieldtype": "Data", "insert_after": "synapse_cnae"},
            {"fieldname": "synapse_regime_tributario", "label": "Regime Tributário", "fieldtype": "Select",
             "options": "\\nsimples\\nsimples-excesso\\nnormal", "insert_after": "synapse_ie"},
            {"fieldname": "synapse_email_contador", "label": "E-mail do Contador", "fieldtype": "Data", "insert_after": "synapse_regime_tributario"},
        ],
        "Bank Account": [
            {"fieldname": "synapse_codigo_banco", "label": "Código do Banco", "fieldtype": "Data", "insert_after": "bank"},
            {"fieldname": "synapse_tipo_conta", "label": "Tipo de Conta", "fieldtype": "Select", "options": "corrente\\npoupanca", "insert_after": "synapse_codigo_banco"},
            {"fieldname": "synapse_chave_pix", "label": "Chave PIX", "fieldtype": "Data", "insert_after": "synapse_tipo_conta"},
        ],
        "Employee": [
            # PIN do Caixa offline — nunca a senha do Ritmo. Fieldtype "Data"
            # de propósito, não "Password": o endpoint synapse_sincronizar_caixa
            # precisa devolver hash+salt pro terminal guardar localmente e
            # comparar ali; o fieldtype "Password" do Frappe criptografa e
            # NUNCA devolve o valor por API (nem pro dono do próprio registro),
            # o que quebraria exatamente o mecanismo que este campo existe pra
            # viabilizar. A proteção real destes dados é a mesma do resto do
            # Ritmo (acesso ao banco), não uma camada extra — ver proposta de
            # segurança: PIN curto + storage local copiado é força-bruta
            # viável, isto não é apresentado como garantia diferente disso.
            {"fieldname": "synapse_pin_hash", "label": "Synapse — Hash do PIN (Caixa offline)", "fieldtype": "Data", "insert_after": "user_id", "read_only": 1},
            {"fieldname": "synapse_pin_salt", "label": "Synapse — Salt do PIN", "fieldtype": "Data", "insert_after": "synapse_pin_hash", "read_only": 1},
            {"fieldname": "synapse_pin_kdf_iteracoes", "label": "Synapse — Iterações PBKDF2", "fieldtype": "Int", "insert_after": "synapse_pin_salt", "read_only": 1},
            {"fieldname": "synapse_pin_definido_em", "label": "Synapse — PIN definido em", "fieldtype": "Datetime", "insert_after": "synapse_pin_kdf_iteracoes", "read_only": 1},
            # Endereço do funcionário: o Painel (salvarEnderecoFuncionario) grava estes 3
            # campos direto no Employee. Nunca tinham sido provisionados em lugar nenhum.
            {"fieldname": "synapse_cep", "label": "Synapse — CEP", "fieldtype": "Data", "insert_after": "synapse_pin_definido_em"},
            {"fieldname": "synapse_cidade_uf", "label": "Synapse — Cidade/UF", "fieldtype": "Data", "insert_after": "synapse_cep"},
            {"fieldname": "synapse_endereco", "label": "Synapse — Endereço", "fieldtype": "Data", "insert_after": "synapse_cidade_uf"},
        ],
        "POS Opening Entry": [
            # Chave de idempotência da abertura de caixa: o Painel consulta por ela antes de
            # gravar (jaExiste), então uma retentativa da fila offline nunca duplica a abertura.
            {"fieldname": "synapse_op_id", "label": "Synapse — ID da operação (idempotência)", "fieldtype": "Data", "insert_after": "pos_profile", "unique": 1, "read_only": 1},
        ],
        "POS Closing Entry": [
            {"fieldname": "synapse_op_id", "label": "Synapse — ID da operação (idempotência)", "fieldtype": "Data", "insert_after": "pos_profile", "unique": 1, "read_only": 1},
        ],
        "POS Invoice": [
            {"fieldname": "synapse_op_id", "label": "Synapse — ID da operação (idempotência)", "fieldtype": "Data", "insert_after": "pos_profile", "unique": 1, "read_only": 1},
            # Quem realmente registrou a venda no terminal — não necessariamente
            # quem está com sessão aberta no Ritmo no momento em que a fila
            # sincroniza (pode ser outra pessoa, ou pode ter sido offline).
            # Não usamos o campo nativo "owner" do Frappe pra isso: nunca
            # verificamos se um POST autenticado comum consegue sobrescrevê-lo
            # (é campo de sistema, comportamento não documentado o bastante pra
            # apostar). Um campo próprio é gravável por definição — nós que o
            # criamos.
            {"fieldname": "synapse_operador_real", "label": "Synapse — Operador real (Caixa offline)", "fieldtype": "Data", "insert_after": "synapse_op_id", "read_only": 1},
        ],
        "Sales Order": [
            # Pedido de Venda offline — mesmo par de campos do POS Invoice,
            # pelo mesmo motivo: idempotência (synapse_op_id, Sales Order
            # também autonomeia por naming_series) e identidade real de quem
            # criou o pedido, que pode ser diferente de quem sincroniza.
            {"fieldname": "synapse_op_id", "label": "Synapse — ID da operação (idempotência)", "fieldtype": "Data", "insert_after": "customer", "unique": 1, "read_only": 1},
            {"fieldname": "synapse_operador_real", "label": "Synapse — Operador real (Pedido offline)", "fieldtype": "Data", "insert_after": "synapse_op_id", "read_only": 1},
        ],
        "Customer": [
            # Fecha uma lacuna real de idempotência: buscar Customer por
            # tax_id não ajuda quando o pedido não tem CPF/CNPJ (cliente sem
            # documento) — nesse caso não havia NENHUMA chave estável pra uma
            # retentativa achar o Customer que uma tentativa anterior já
            # criou, e cada retry criava um Customer novo. Este campo guarda
            # o op_id do Pedido que criou o Customer, e passa a ser a SEGUNDA
            # busca (depois de tax_id) antes de decidir criar — cobre
            # justamente o caso sem documento, e reforça o caso com
            # documento contra a própria retentativa da mesma operação.
            # NÃO resolve duas operações DIFERENTES com o mesmo tax_id
            # correndo ao mesmo tempo em terminais diferentes — isso exigiria
            # uma constraint de unicidade em tax_id no banco, que não aplico
            # às cegas aqui sem saber se já existem tax_id duplicados/vazios
            # nos dados reais de vocês. Ver nota na entrega.
            {"fieldname": "synapse_pedido_op_id", "label": "Synapse — Pedido que criou este cliente", "fieldtype": "Data", "insert_after": "customer_name", "read_only": 1},
        ]
    }, ignore_validate=True)
    frappe.db.commit()
    print("Campos customizados garantidos")
PYEOF
ok "Campos customizados (Company, Bank Account, Employee, POS Opening/Closing/Invoice, Sales Order, Customer) garantidos"

ritmo_exec > /tmp/synapse_warehouse_type.log <<PYEOF
def main():
    import frappe
    # Unidades e Filiais filtram Warehouse por warehouse_type 'Loja' e 'Deposito' (sem acento,
    # exatamente como o Painel usa). Os dois tipos precisam existir antes da primeira filial.
    for nome in ["Loja", "Deposito"]:
        if not frappe.db.exists("Warehouse Type", nome):
            frappe.get_doc({"doctype": "Warehouse Type", "name": nome}).insert(ignore_permissions=True)
            print(f"Warehouse Type '{nome}' criado")
        else:
            print(f"Warehouse Type '{nome}' já existia")
    frappe.db.commit()
PYEOF
ok "Warehouse Type 'Loja' e 'Deposito' garantidos (Unidades e Filiais dependem dos dois)"

log "Criando usuário de automação para o Harmonia..."
RESULT_AUTOMACAO=$(ritmo_exec <<PYEOF
def main():
    import frappe
    role_name = "Synapse Automação"
    if not frappe.db.exists("Role", role_name):
        frappe.get_doc({"doctype": "Role", "role_name": role_name, "desk_access": 0}).insert(ignore_permissions=True)

    user_email = "auto@nomen.me"
    if not frappe.db.exists("User", user_email):
        user = frappe.get_doc({
            "doctype": "User", "email": user_email, "first_name": "Harmonia (Automação)",
            "user_type": "System User", "send_welcome_email": 0,
            "roles": [{"role": role_name}, {"role": "System Manager"}]
        })
        user.insert(ignore_permissions=True)
    else:
        user = frappe.get_doc("User", user_email)

    user.api_key = frappe.generate_hash(length=15)
    if not user.get_password("api_secret", raise_exception=False):
        user.api_secret = frappe.generate_hash(length=15)
    user.save(ignore_permissions=True)
    frappe.db.commit()

    print(f"SYNAPSE_KV|api_key|{user.api_key}")
    print(f"SYNAPSE_KV|api_secret|{user.get_password('api_secret')}")
PYEOF
)
ERP_API_KEY=$(echo "$RESULT_AUTOMACAO" | grep '^SYNAPSE_KV|api_key|' | cut -d'|' -f3)
ERP_API_SECRET=$(echo "$RESULT_AUTOMACAO" | grep '^SYNAPSE_KV|api_secret|' | cut -d'|' -f3)
if [ -n "$ERP_API_KEY" ] && [ -n "$ERP_API_SECRET" ]; then
  salvar_credencial "ERP_API_KEY" "$ERP_API_KEY"
  salvar_credencial "ERP_API_SECRET" "$ERP_API_SECRET"
  ok "Usuário de automação auto@nomen.me pronto — chave capturada"
else
  err "Não consegui capturar api_key/api_secret do usuário de automação. Saída: ${RESULT_AUTOMACAO}"
fi

docker exec ritmo-backend-1 bench --site "${DOMINIO_ERP}" clear-cache

log "Criando Empresa Padrão e aplicando Plano de Contas BR..."
RESULT_COMPANY=$(ritmo_exec <<PYEOF
def main():
    import frappe

    nome_empresa = "${NOME_LOJA}"

    if not frappe.db.exists("Company", nome_empresa):
        # Não chutamos um nome fixo de plano de contas — "Standard" é o
        # genérico do Frappe, não o brasileiro. Perguntamos ao próprio
        # ERPNext (mesma função que o Setup Wizard usa) quais planos
        # existem pra "Brazil" nos apps instalados, e usamos o primeiro.
        # Se nenhum vier (nenhuma localização BR instalada), caímos pro
        # genérico mas avisamos de forma explícita — nunca em silêncio.
        coa = "Standard"
        coa_e_brasileiro = False
        try:
            from erpnext.accounts.doctype.account.chart_of_accounts.chart_of_accounts import get_charts_for_country
            opcoes = get_charts_for_country("Brazil") or []
            if opcoes:
                coa = opcoes[0]
                coa_e_brasileiro = True
        except Exception as e:
            print(f"SYNAPSE_KV|coa_erro|{e}")

        try:
            doc = frappe.get_doc({
                "doctype": "Company",
                "company_name": nome_empresa,
                "default_currency": "BRL",
                "country": "Brazil",
                "chart_of_accounts": coa,
            })
            doc.insert(ignore_permissions=True)
            frappe.db.commit()
            print(f"SYNAPSE_KV|company_status|criada")
            print(f"SYNAPSE_KV|coa_usado|{coa}")
            print(f"SYNAPSE_KV|coa_brasileiro|{coa_e_brasileiro}")
        except Exception as e:
            frappe.db.rollback()
            print(f"SYNAPSE_KV|company_status|falhou")
            print(f"SYNAPSE_KV|company_erro|{e}")
            return
    else:
        print(f"SYNAPSE_KV|company_status|ja_existia")

    frappe.db.set_single_value("Global Defaults", "default_company", nome_empresa)
    frappe.db.set_single_value("Global Defaults", "default_currency", "BRL")
    frappe.db.set_single_value("Global Defaults", "country", "Brazil")
    frappe.db.commit()
PYEOF
)
COMPANY_STATUS=$(echo "$RESULT_COMPANY" | grep '^SYNAPSE_KV|company_status|' | cut -d'|' -f3)
COA_USADO=$(echo "$RESULT_COMPANY" | grep '^SYNAPSE_KV|coa_usado|' | cut -d'|' -f3)
COA_BRASILEIRO=$(echo "$RESULT_COMPANY" | grep '^SYNAPSE_KV|coa_brasileiro|' | cut -d'|' -f3)
case "$COMPANY_STATUS" in
  criada)
    if [ "$COA_BRASILEIRO" = "True" ]; then
      ok "Empresa '${NOME_LOJA}' criada com Plano de Contas BR real: '${COA_USADO}'"
    else
      warn "Empresa '${NOME_LOJA}' criada, mas NENHUM plano de contas brasileiro foi encontrado instalado — usou o genérico '${COA_USADO}'. Confirme manualmente se algum app de localização BR precisa ser instalado."
    fi
    ;;
  ja_existia) ok "Empresa '${NOME_LOJA}' já existia — mantida como está" ;;
  *) err "Falha ao criar a Empresa '${NOME_LOJA}'. Saída: ${RESULT_COMPANY}" ;;
esac

# =============================================================================
# 5.5 RITMO — MOTOR DE COMPOSIÇÃO (itens compostos / "montador" do PDV +
#     rastreamento de produção)
#     (o Painel do PDV assume "Synapse Composicao" / "Synapse Producao Item" como existentes)
# =============================================================================
log "Provisionando Motor de Composição (itens compostos + produção)..."

RESULT_COMPOSICAO=$(ritmo_exec <<'PYEOF'
def main():
    import frappe

    if not frappe.db.exists("Module Def", "Synapse"):
        frappe.get_doc({"doctype": "Module Def", "module_name": "Synapse", "app_name": "frappe", "custom": 1}).insert(ignore_permissions=True)

    # ---- 1) Synapse Composicao Opcao (child table, sem dependência) ----
    if not frappe.db.exists("DocType", "Synapse Composicao Opcao"):
        frappe.get_doc({
            "doctype": "DocType", "name": "Synapse Composicao Opcao", "module": "Synapse",
            "custom": 1, "istable": 1,
            "fields": [
                {"fieldname": "nome", "label": "Nome", "fieldtype": "Data", "reqd": 1, "in_list_view": 1},
                {"fieldname": "preco", "label": "Ajuste de Preço", "fieldtype": "Currency", "default": "0", "in_list_view": 1},
            ]
        }).insert(ignore_permissions=True)
        print("criado: Synapse Composicao Opcao")
    else:
        print("ja existia: Synapse Composicao Opcao")

    # ---- 2) Synapse Composicao Grupo (child table; composicao_filha vem depois, quebra de dependência circular) ----
    if not frappe.db.exists("DocType", "Synapse Composicao Grupo"):
        frappe.get_doc({
            "doctype": "DocType", "name": "Synapse Composicao Grupo", "module": "Synapse",
            "custom": 1, "istable": 1,
            "fields": [
                {"fieldname": "nome", "label": "Nome", "fieldtype": "Data", "reqd": 1, "in_list_view": 1},
                {"fieldname": "min", "label": "Mínimo", "fieldtype": "Int", "default": "0", "in_list_view": 1},
                {"fieldname": "max", "label": "Máximo", "fieldtype": "Int", "default": "1", "in_list_view": 1},
                {"fieldname": "regra", "label": "Regra", "fieldtype": "Select", "options": "soma\nproporcional", "default": "soma"},
                {"fieldname": "opcoes", "label": "Opções", "fieldtype": "Table", "options": "Synapse Composicao Opcao"},
            ]
        }).insert(ignore_permissions=True)
        print("criado: Synapse Composicao Grupo")
    else:
        print("ja existia: Synapse Composicao Grupo")

    # ---- 3) Synapse Composicao (pai) ----
    if not frappe.db.exists("DocType", "Synapse Composicao"):
        frappe.get_doc({
            "doctype": "DocType", "name": "Synapse Composicao", "module": "Synapse",
            "custom": 1, "istable": 0, "autoname": "field:titulo",
            "fields": [
                {"fieldname": "titulo", "label": "Título", "fieldtype": "Data", "reqd": 1, "unique": 1, "in_list_view": 1},
                {"fieldname": "grupos", "label": "Grupos", "fieldtype": "Table", "options": "Synapse Composicao Grupo"},
            ],
            "permissions": [
                {"role": "System Manager", "read": 1, "write": 1, "create": 1, "delete": 1},
                {"role": "Synapse Lojista", "read": 1, "write": 1, "create": 1},
            ]
        }).insert(ignore_permissions=True)
        print("criado: Synapse Composicao")
    else:
        print("ja existia: Synapse Composicao")

    # ---- 4) fecha a recursão: adiciona composicao_filha no Grupo agora que Composicao existe ----
    grupo_doc = frappe.get_doc("DocType", "Synapse Composicao Grupo")
    if not any(f.fieldname == "composicao_filha" for f in grupo_doc.fields):
        grupo_doc.append("fields", {
            "fieldname": "composicao_filha", "label": "Composição Filha (recursão)",
            "fieldtype": "Link", "options": "Synapse Composicao",
            "insert_after": "regra"
        })
        grupo_doc.save(ignore_permissions=True)
        print("campo composicao_filha adicionado em Synapse Composicao Grupo")
    else:
        print("composicao_filha ja existia em Synapse Composicao Grupo")

    # ---- 5) Custom Field no Item ----
    from frappe.custom.doctype.custom_field.custom_field import create_custom_fields
    create_custom_fields({
        "Item": [
            {"fieldname": "custom_composicao", "label": "Composição (Motor)", "fieldtype": "Link",
             "options": "Synapse Composicao", "insert_after": "item_group"},
        ]
    }, ignore_validate=True)
    print("custom_composicao garantido em Item")

    # ---- 6) Synapse Producao Item ----
    if not frappe.db.exists("DocType", "Synapse Producao Item"):
        frappe.get_doc({
            "doctype": "DocType", "name": "Synapse Producao Item", "module": "Synapse",
            "custom": 1, "istable": 0, "autoname": "field:synapse_op_id",
            "track_changes": 1,
            "fields": [
                {"fieldname": "synapse_op_id", "label": "Op ID (idempotência)", "fieldtype": "Data", "reqd": 1, "unique": 1},
                {"fieldname": "pos_invoice", "label": "POS Invoice", "fieldtype": "Link", "options": "POS Invoice", "in_list_view": 1},
                {"fieldname": "item_code", "label": "Item", "fieldtype": "Link", "options": "Item", "in_list_view": 1},
                {"fieldname": "frase", "label": "Descrição", "fieldtype": "Data", "in_list_view": 1},
                {"fieldname": "preenchimentos_json", "label": "Escolhas (JSON)", "fieldtype": "Long Text"},
                {"fieldname": "alerta", "label": "Alerta Cozinha", "fieldtype": "Check", "default": "0"},
                {"fieldname": "status_producao", "label": "Status", "fieldtype": "Select",
                 "options": "Pendente\nEm Preparo\nPronto\nEnviado\nEntregue\nCancelado",
                 "default": "Pendente", "in_list_view": 1},
            ],
            "permissions": [
                {"role": "System Manager", "read": 1, "write": 1, "create": 1, "delete": 1},
                {"role": "Synapse Lojista", "read": 1, "write": 1, "create": 1},
                {"role": "Synapse Funcionário", "read": 1, "write": 1},
                {"role": "Synapse Automação", "read": 1, "write": 1, "create": 1},
            ]
        }).insert(ignore_permissions=True)
        print("criado: Synapse Producao Item")
    else:
        print("ja existia: Synapse Producao Item")

    frappe.db.commit()
PYEOF
)
echo "$RESULT_COMPOSICAO" > /tmp/synapse_composicao.log

if echo "$RESULT_COMPOSICAO" | grep -qiE "Traceback|Error|Exception"; then
  err "Motor de Composição: a execução no Ritmo devolveu erro — ver /tmp/synapse_composicao.log. O restante do provisionamento continua, mas o 'montador' do PDV vai ficar quebrado até isto ser corrigido (rode este script de novo depois — é idempotente)."
else
  docker exec ritmo-backend-1 bench --site "${DOMINIO_ERP}" clear-cache

  # Verificação real (não confia só em não ter dado erro acima) — consulta o
  # próprio Ritmo pra confirmar que cada DocType/campo existe de fato.
  VERIFICACAO_COMPOSICAO=$(ritmo_exec <<'PYEOF'
def main():
    import frappe
    esperado = [
        "Synapse Composicao Opcao",
        "Synapse Composicao Grupo",
        "Synapse Composicao",
        "Synapse Producao Item",
    ]
    for nome in esperado:
        print(f"SYNAPSE_CHECK|{nome}|{1 if frappe.db.exists('DocType', nome) else 0}")
    tem_campo = frappe.db.exists("Custom Field", {"dt": "Item", "fieldname": "custom_composicao"})
    print(f"SYNAPSE_CHECK|Item.custom_composicao|{1 if tem_campo else 0}")
PYEOF
)
  FALHOU_COMPOSICAO=0
  while IFS='|' read -r _ nome existe; do
    [ -z "$nome" ] && continue
    if [ "$existe" = "1" ]; then
      ok "Motor de Composição: confirmado '${nome}'"
    else
      err "Motor de Composição: NÃO encontrado '${nome}' — ver /tmp/synapse_composicao.log"
      FALHOU_COMPOSICAO=1
    fi
  done < <(echo "$VERIFICACAO_COMPOSICAO" | grep '^SYNAPSE_CHECK|')

  if [ "$FALHOU_COMPOSICAO" -eq 0 ]; then
    ok "Motor de Composição garantido e confirmado (itens compostos + Kanban de produção prontos para uso no painel)"
  fi
fi

# =============================================================================
# 6. N8N (HARMONIA)
#    docker-compose usa "env_file: .env" (não valores fixos) — assim as
#    fases seguintes só escrevem no .env e reiniciam, sem tocar no compose.
# =============================================================================
log "Instalando N8N (Harmonia)..."
mkdir -p /home/ubuntu/n8n
cat > /home/ubuntu/n8n/docker-compose.yml << EOF
services:
  n8n:
    image: n8nio/n8n:${SYNAPSE_N8N_VERSION}
    container_name: harmonia
    restart: always
    env_file: .env
    volumes:
      - harmonia_data:/home/node/.n8n
    networks:
      - stack-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.harmonia.rule=Host(\`${DOMINIO_N8N}\`) && (PathPrefix(\`/webhook\`) || PathPrefix(\`/webhook-test\`) || PathPrefix(\`/api/v1\`) || PathPrefix(\`/healthz\`))"
      - "traefik.http.routers.harmonia.entrypoints=websecure"
      - "traefik.http.routers.harmonia.tls.certresolver=myresolver"
      - "traefik.http.routers.harmonia.priority=10"
      - "traefik.http.services.harmonia.loadbalancer.server.port=5678"
volumes:
  harmonia_data:
networks:
  stack-network:
    external: true
EOF

touch "$N8N_ENV_FILE"; chmod 600 "$N8N_ENV_FILE"
grava_env_n8n "N8N_HOST" "${DOMINIO_N8N}"
grava_env_n8n "N8N_PORT" "5678"
grava_env_n8n "N8N_PROTOCOL" "https"
grava_env_n8n "WEBHOOK_URL" "https://${DOMINIO_N8N}/"
grava_env_n8n "N8N_BASIC_AUTH_ACTIVE" "true"
grava_env_n8n "N8N_BASIC_AUTH_USER" "admin"
grava_env_n8n "N8N_BASIC_AUTH_PASSWORD" "${SENHA}"
# CHATWOOT_WHATSAPP_INBOX_ID não é gravado aqui — nesse ponto do script a
# conta do Harpa ainda nem existe, então "1" era só um chute sem base
# nenhuma. O valor real (ou a ausência honesta dele) é resolvido mais
# adiante, na seção 9, depois que a conta do Chatwoot já existe de verdade.

cd /home/ubuntu/n8n && docker compose up -d
ok "N8N instalado em https://${DOMINIO_N8N}"

# =============================================================================
# 7. CHATWOOT (HARPA)
# =============================================================================
log "Instalando Chatwoot (Harpa)..."
mkdir -p /home/ubuntu/chatwoot
cat > /home/ubuntu/chatwoot/docker-compose.yml << EOF
services:
  base: &base
    image: chatwoot/chatwoot:${SYNAPSE_CHATWOOT_VERSION}
    env_file: .env
    volumes:
      - harpa_storage:/app/storage
  rails:
    <<: *base
    container_name: harpa-rails
    restart: always
    command: bundle exec rails s -p 3000 -b 0.0.0.0
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.harpa.rule=Host(\`${DOMINIO_CHAT}\`) && (PathPrefix(\`/packs\`) || PathPrefix(\`/widget\`) || PathPrefix(\`/api/v1\`) || PathPrefix(\`/webhooks\`) || PathPrefix(\`/cable\`))"
      - "traefik.http.routers.harpa.entrypoints=websecure"
      - "traefik.http.routers.harpa.tls.certresolver=myresolver"
      - "traefik.http.routers.harpa.priority=10"
      - "traefik.http.services.harpa.loadbalancer.server.port=3000"
  sidekiq:
    <<: *base
    container_name: harpa-sidekiq
    restart: always
    command: bundle exec sidekiq -C config/sidekiq.yml
    networks: [stack-network]
  postgres:
    container_name: harpa-postgres
    # pg16 é o Postgres oficial do docker-compose.production.yaml upstream do
    # Chatwoot para a 4.18.0. Assume volume novo (reinstalação limpa) — se
    # algum dia isso rodar sobre um volume pg15 já existente, precisa de
    # pg_upgrade/dump-restore antes, não é troca direta de tag.
    image: pgvector/pgvector:${SYNAPSE_CHATWOOT_POSTGRES_VERSION}
    restart: always
    environment:
      POSTGRES_DB: harpa
      POSTGRES_USER: harpa
      POSTGRES_PASSWORD: ${SENHA}
    volumes: [harpa_postgres_data:/var/lib/postgresql/data]
    networks: [stack-network]
  redis:
    container_name: harpa-redis
    image: redis:${SYNAPSE_CHATWOOT_REDIS_VERSION}
    restart: always
    volumes: [harpa_redis:/data]
    networks: [stack-network]
volumes:
  harpa_storage:
  harpa_postgres_data:
  harpa_redis:
networks:
  stack-network:
    external: true
EOF

cat > /home/ubuntu/chatwoot/.env << EOF
SECRET_KEY_BASE=${SECRET_KEY}
FRONTEND_URL=https://${DOMINIO_CHAT}
DEFAULT_LOCALE=pt_BR
FORCE_SSL=true
ENABLE_ACCOUNT_SIGNUP=false
REDIS_URL=redis://harpa-redis:6379
POSTGRES_HOST=harpa-postgres
POSTGRES_USERNAME=harpa
POSTGRES_PASSWORD=${SENHA}
POSTGRES_DATABASE=harpa
RAILS_ENV=production
RAILS_LOG_TO_STDOUT=true
EOF

cd /home/ubuntu/chatwoot
docker compose up -d postgres redis
log "Aguardando PostgreSQL do Chatwoot ficar saudável..."
TENTATIVAS=0
until docker compose exec -T postgres pg_isready -U harpa 2>/dev/null | grep -q "accepting connections"; do
  TENTATIVAS=$((TENTATIVAS+1))
  if [ $TENTATIVAS -ge 30 ]; then err "PostgreSQL do Chatwoot não respondeu a tempo. Seguindo mesmo assim."; break; fi
  sleep 2
done

docker compose stop rails sidekiq 2>/dev/null || true
if docker compose run --rm -T rails bundle exec rails db:chatwoot_prepare; then
  docker compose start rails sidekiq
  ok "Chatwoot instalado em https://${DOMINIO_CHAT}"
else
  err "Falha ao preparar a BD do Chatwoot. Rode depois: cd /home/ubuntu/chatwoot && docker compose run --rm -T rails bundle exec rails db:chatwoot_prepare"
fi
log "Aguardando Chatwoot subir de vez (20s)..."; sleep 20

# =============================================================================
# 8. HARPA — PROVISIONAMENTO (conta, admin, token, inbox webchat)
#    (fusão do antigo 3_provisionar_harpa.sh — domínio do widget dinâmico)
# =============================================================================
log "Provisionando Harpa (conta, admin, token de API)..."
RESULT_HARPA=$(docker exec -i harpa-rails bundle exec rails runner "
account = Account.find_by(name: '${NOME_LOJA}') || Account.create!(name: '${NOME_LOJA}')

user = User.find_by(email: '${EMAIL}')
if user.nil?
  user = User.new(name: 'Administrador Synapse', email: '${EMAIL}', password: '${SENHA}', password_confirmation: '${SENHA}')
  user.skip_confirmation!
  user.save!
end

unless AccountUser.exists?(account: account, user: user)
  AccountUser.create!(account: account, user: user, role: :administrator)
end

token = user.access_token&.token || AccessToken.create!(owner: user).token

inbox = account.inboxes.find_by(name: 'Site Synapse')
if inbox.nil?
  channel = Channel::WebWidget.create!(website_url: 'https://${DOMINIO_PAINEL}', account: account)
  inbox = account.inboxes.create!(name: 'Site Synapse', channel: channel)
end

puts \"SYNAPSE_KV|account_id|#{account.id}\"
puts \"SYNAPSE_KV|api_token|#{token}\"
puts \"SYNAPSE_KV|inbox_id|#{inbox.id}\"
" 2>&1)

CW_ACCOUNT_ID=$(echo "$RESULT_HARPA" | grep '^SYNAPSE_KV|account_id|' | cut -d'|' -f3)
CW_API_TOKEN=$(echo "$RESULT_HARPA" | grep '^SYNAPSE_KV|api_token|' | cut -d'|' -f3)
if [ -n "$CW_ACCOUNT_ID" ] && [ -n "$CW_API_TOKEN" ]; then
  salvar_credencial "CHATWOOT_ACCOUNT_ID" "$CW_ACCOUNT_ID"
  salvar_credencial "CHATWOOT_API_TOKEN" "$CW_API_TOKEN"
  ok "Conta '${NOME_LOJA}' provisionada no Harpa (account_id=${CW_ACCOUNT_ID}) — chave capturada"
else
  err "Não consegui capturar account_id/api_token do Harpa. Saída: ${RESULT_HARPA}"
fi
log "Inbox de WhatsApp: verificado/criado mais adiante nesta mesma execução, na seção que já tem CHATWOOT_ACCOUNT_ID/CHATWOOT_API_TOKEN e os secrets da Meta disponíveis."

# =============================================================================
# 9. GRAVA CREDENCIAIS DE INFRA NO .env DO HARMONIA
#    (substitui o antigo 4_atualizar_credenciais_harmonia.sh — sem prompt
#    manual: só as chaves que o próprio provisionamento acabou de gerar.
#    Melhor Envio/InfinitePay/99 ficam fora — o painel grava no Ritmo.
#    GEMINI_API_KEY fica fora — centralizada só na Lyra Central.)
# =============================================================================
log "Gravando credenciais de infra no .env do Harmonia..."
grava_env_n8n "ERPNEXT_DOMAIN" "https://${DOMINIO_ERP}"
grava_env_n8n "ERPNEXT_API_KEY" "${ERP_API_KEY:-}"
grava_env_n8n "ERPNEXT_API_SECRET" "${ERP_API_SECRET:-}"
grava_env_n8n "CHATWOOT_DOMAIN" "https://${DOMINIO_CHAT}"
grava_env_n8n "CHATWOOT_API_TOKEN" "${CW_API_TOKEN:-}"
grava_env_n8n "CHATWOOT_ACCOUNT_ID" "${CW_ACCOUNT_ID:-}"
grava_env_n8n "HARMONIA_DOMAIN" "https://${DOMINIO_N8N}"

# =============================================================================
# 9B. RELATÓRIO PASS/FAIL + SECRETS DA META + WHATSAPP REAL + WEBHOOK
#     A partir daqui o script vira provisionador: cada elo é validado contra
#     a API real, nunca assumido por um HTTP 200 isolado, e tudo entra num
#     relatório final que decide se a instalação terminou com SUCCESS ou
#     PARCIAL. Nada disso imprime segredo em texto puro — só os 4 últimos
#     dígitos, e nunca em arquivo versionado.
# =============================================================================
mascarar() {
  local v="$1"
  [ -z "$v" ] && { echo "(vazio)"; return; }
  echo "***${v: -4}"
}

if [[ "$CW_ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
  relatorio "PASS" "Chatwoot" "conta '${NOME_LOJA}' (account_id=${CW_ACCOUNT_ID}) provisionada"
else
  relatorio "FAIL" "Chatwoot" "account_id não capturado — ver seção 8 acima"
fi
CODE_CW_API=$(curl -s -o /dev/null -w '%{http_code}' -H "api_access_token: ${CW_API_TOKEN}" \
  "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}" 2>/dev/null)
if [ "$CODE_CW_API" = "200" ]; then
  relatorio "PASS" "Chatwoot API" "autenticação com o token confirmada (HTTP 200)"
else
  relatorio "FAIL" "Chatwoot API" "HTTP ${CODE_CW_API} ao autenticar com CHATWOOT_API_TOKEN"
fi

# --- Secrets da Meta: só de mecanismo externo protegido. NUNCA por
#     argumento de linha de comando (fica no histórico do shell e em `ps`).
META_SECRETS_FILE="${META_SECRETS_FILE:-/root/.synapse_meta_secrets.env}"
if [ -f "$META_SECRETS_FILE" ]; then
  PERM_SECRETS=$(stat -c '%a' "$META_SECRETS_FILE" 2>/dev/null)
  if [ "$PERM_SECRETS" != "600" ]; then
    warn "Corrigindo permissão de ${META_SECRETS_FILE} para 600 (estava ${PERM_SECRETS})."
    chmod 600 "$META_SECRETS_FILE"
  fi
  set -a
  # shellcheck disable=SC1090
  source "$META_SECRETS_FILE"
  set +a
  ok "Secrets da Meta carregados de ${META_SECRETS_FILE} (permissão 600, fora do repo clonado)"
else
  warn "${META_SECRETS_FILE} não encontrado — também aceito por variável de ambiente já exportada antes de rodar este script."
fi
: "${META_APP_ID:=}"
: "${META_APP_SECRET:=}"
: "${META_WA_PHONE_NUMBER_ID:=}"
: "${META_WA_BUSINESS_ACCOUNT_ID:=}"
: "${META_SYSTEM_USER_TOKEN:=}"
: "${META_WEBHOOK_VERIFY_TOKEN:=}"
: "${META_GRAPH_API_VERSION:=${SYNAPSE_META_GRAPH_API_VERSION}}"

META_SECRETS_OK=true
for _v in META_APP_ID META_WA_PHONE_NUMBER_ID META_WA_BUSINESS_ACCOUNT_ID META_SYSTEM_USER_TOKEN; do
  [ -z "${!_v}" ] && META_SECRETS_OK=false
done

CW_WHATSAPP_INBOX_ID=""
if [ "$META_SECRETS_OK" = false ]; then
  relatorio "FAIL" "WhatsApp credentials" "faltando um ou mais de META_APP_ID/META_WA_PHONE_NUMBER_ID/META_WA_BUSINESS_ACCOUNT_ID/META_SYSTEM_USER_TOKEN em ${META_SECRETS_FILE} ou variável de ambiente — exceção real, não dá pra inventar valor"
  relatorio "FAIL" "WhatsApp inbox" "pulado — sem credenciais Meta válidas"
  relatorio "FAIL" "Chatwoot webhook" "pulado — depende do inbox de WhatsApp existir"
else
  relatorio "PASS" "WhatsApp credentials" "presentes (token $(mascarar "$META_SYSTEM_USER_TOKEN"))"

  GRAPH="https://graph.facebook.com/${META_GRAPH_API_VERSION}"

  HTTP_TOKEN=$(curl -s -o /tmp/synapse_meta_token.json -w '%{http_code}' \
    "${GRAPH}/me?access_token=${META_SYSTEM_USER_TOKEN}")
  if [ "$HTTP_TOKEN" = "200" ]; then
    relatorio "PASS" "Meta token válido"
  else
    ERRO_META=$(python3 -c "
import json
try:
    print(json.load(open('/tmp/synapse_meta_token.json')).get('error', {}).get('message', 'sem detalhe'))
except Exception:
    print('resposta não-JSON')
" 2>/dev/null)
    relatorio "FAIL" "Meta token válido" "HTTP ${HTTP_TOKEN} — ${ERRO_META}"
  fi

  HTTP_WABA=$(curl -s -o /tmp/synapse_meta_waba.json -w '%{http_code}' \
    "${GRAPH}/${META_WA_BUSINESS_ACCOUNT_ID}?access_token=${META_SYSTEM_USER_TOKEN}")
  if [ "$HTTP_WABA" = "200" ]; then
    relatorio "PASS" "WhatsApp Business Account" "id=${META_WA_BUSINESS_ACCOUNT_ID} acessível"
  else
    ERRO_WABA=$(python3 -c "
import json
try:
    print(json.load(open('/tmp/synapse_meta_waba.json')).get('error', {}).get('message', 'sem detalhe'))
except Exception:
    print('resposta não-JSON')
" 2>/dev/null)
    relatorio "FAIL" "WhatsApp Business Account" "HTTP ${HTTP_WABA} — ${ERRO_WABA}"
  fi

  HTTP_TEL=$(curl -s -o /tmp/synapse_meta_tel.json -w '%{http_code}' \
    "${GRAPH}/${META_WA_PHONE_NUMBER_ID}?fields=display_phone_number,verified_name&access_token=${META_SYSTEM_USER_TOKEN}")
  META_DISPLAY_PHONE=""
  if [ "$HTTP_TEL" = "200" ]; then
    META_DISPLAY_PHONE=$(python3 -c "
import json
try:
    print(json.load(open('/tmp/synapse_meta_tel.json')).get('display_phone_number',''))
except Exception:
    pass
" 2>/dev/null)
    relatorio "PASS" "Phone Number válido" "id=${META_WA_PHONE_NUMBER_ID} (${META_DISPLAY_PHONE:-sem display_phone_number})"
  else
    relatorio "FAIL" "Phone Number válido" "HTTP ${HTTP_TEL} — phone_number_id inacessível com este token"
  fi

  # A API do Graph pagina phone_numbers (default ~25/página) — sem seguir
  # o cursor, um WABA com mais de uma página podia dar falso-negativo aqui
  # mesmo com o número certo cadastrado. Segue paging.next até achar ou
  # esgotar (com teto de segurança pra nunca ficar em loop infinito).
  PERTENCE="nao"
  PROXIMA_URL="${GRAPH}/${META_WA_BUSINESS_ACCOUNT_ID}/phone_numbers?access_token=${META_SYSTEM_USER_TOKEN}"
  HTTP_WABA_NUMS="000"
  for _pagina in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$PROXIMA_URL" ] && break
    HTTP_WABA_NUMS=$(curl -s -o /tmp/synapse_meta_waba_nums.json -w '%{http_code}' "$PROXIMA_URL")
    [ "$HTTP_WABA_NUMS" != "200" ] && break
    RESULTADO_PAGINA=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/synapse_meta_waba_nums.json'))
    ids = [n.get('id') for n in d.get('data', [])]
    achou = '${META_WA_PHONE_NUMBER_ID}' in ids
    prox = (d.get('paging') or {}).get('next', '')
    print(f\"{'sim' if achou else 'nao'}|{prox}\")
except Exception:
    print('nao|')
" 2>/dev/null)
    IFS='|' read -r ACHOU_NESSA_PAGINA PROXIMA_URL <<< "$RESULTADO_PAGINA"
    if [ "$ACHOU_NESSA_PAGINA" = "sim" ]; then
      PERTENCE="sim"
      break
    fi
  done
  if [ "$PERTENCE" = "sim" ]; then
    relatorio "PASS" "Phone Number pertence ao WABA"
  else
    relatorio "FAIL" "Phone Number pertence ao WABA" "phone_number_id ${META_WA_PHONE_NUMBER_ID} não está na lista de números do WABA ${META_WA_BUSINESS_ACCOUNT_ID} (HTTP ${HTTP_WABA_NUMS})"
  fi

  # --- Inbox de WhatsApp no Chatwoot: procura, reutiliza se existir,
  #     cria via API oficial se não existir. Idempotente (rerun não duplica).
  INBOXES_JSON=$(curl -s -H "api_access_token: ${CW_API_TOKEN}" \
    "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}/inboxes" 2>/dev/null)
  CW_WHATSAPP_INBOX_ID=$(echo "$INBOXES_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    lista = d.get('payload', d) if isinstance(d, dict) else d
    for inbox in lista:
        if 'whatsapp' in str(inbox.get('channel_type', '')).lower():
            print(inbox['id']); break
except Exception:
    pass
" 2>/dev/null)

  if [ -n "$CW_WHATSAPP_INBOX_ID" ]; then
    relatorio "PASS" "WhatsApp inbox" "reutilizado (id=${CW_WHATSAPP_INBOX_ID}) — já existia, não recriado"
  else
    PAYLOAD_INBOX=$(NOME_LOJA_ENV="$NOME_LOJA" TELEFONE_ENV="$META_DISPLAY_PHONE" \
      TOKEN_ENV="$META_SYSTEM_USER_TOKEN" PHONE_ID_ENV="$META_WA_PHONE_NUMBER_ID" \
      WABA_ID_ENV="$META_WA_BUSINESS_ACCOUNT_ID" python3 -c "
import json, os
print(json.dumps({
    'name': f\"WhatsApp {os.environ['NOME_LOJA_ENV']}\",
    'channel': {
        'type': 'whatsapp',
        'phone_number': os.environ['TELEFONE_ENV'],
        'provider': 'whatsapp_cloud',
        'provider_config': {
            'api_key': os.environ['TOKEN_ENV'],
            'phone_number_id': os.environ['PHONE_ID_ENV'],
            'business_account_id': os.environ['WABA_ID_ENV']
        }
    }
}))
")
    HTTP_INBOX=$(curl -s -o /tmp/synapse_cw_inbox.json -w '%{http_code}' \
      -X POST "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}/inboxes" \
      -H "api_access_token: ${CW_API_TOKEN}" -H 'Content-Type: application/json' \
      -d "$PAYLOAD_INBOX")
    if [ "$HTTP_INBOX" = "200" ] || [ "$HTTP_INBOX" = "201" ]; then
      CW_WHATSAPP_INBOX_ID=$(python3 -c "
import json
try:
    print(json.load(open('/tmp/synapse_cw_inbox.json')).get('id',''))
except Exception:
    pass
" 2>/dev/null)
      relatorio "PASS" "WhatsApp inbox" "criado (id=${CW_WHATSAPP_INBOX_ID})"
    else
      # nunca ecoa o corpo cru sem checar segredo — provider_config não volta
      # na resposta de erro do Chatwoot, mas por precaução mascaramos mesmo
      # assim antes de logar.
      CORPO_ERRO_INBOX=$(cat /tmp/synapse_cw_inbox.json 2>/dev/null | sed "s/${META_SYSTEM_USER_TOKEN}/***MASCARADO***/g" | head -c 300)
      relatorio "FAIL" "WhatsApp inbox" "HTTP ${HTTP_INBOX} ao criar — ${CORPO_ERRO_INBOX}"
    fi
  fi

  if [ -n "$CW_WHATSAPP_INBOX_ID" ]; then
    grava_env_n8n "CHATWOOT_WHATSAPP_INBOX_ID" "$CW_WHATSAPP_INBOX_ID"
  fi

  # --- Webhook da conta Chatwoot -> Harmonia. Cria se não existir
  #     (idempotente), e CONFIRMA lendo de volta — um POST 200 sozinho não
  #     é considerado suficiente.
  WEBHOOK_ALVO="https://${DOMINIO_N8N}/webhook/synapse-atendimento"
  WEBHOOKS_JSON=$(curl -s -H "api_access_token: ${CW_API_TOKEN}" \
    "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}/webhooks" 2>/dev/null)
  JA_EXISTE_WEBHOOK=$(echo "$WEBHOOKS_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    lista = d.get('payload', d) if isinstance(d, dict) else d
    print('sim' if any(w.get('url') == '${WEBHOOK_ALVO}' for w in lista) else 'nao')
except Exception:
    print('nao')
" 2>/dev/null)
  if [ "$JA_EXISTE_WEBHOOK" != "sim" ]; then
    curl -s -o /tmp/synapse_cw_webhook.json -w '%{http_code}' \
      -X POST "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}/webhooks" \
      -H "api_access_token: ${CW_API_TOKEN}" -H 'Content-Type: application/json' \
      -d "{\"url\":\"${WEBHOOK_ALVO}\",\"subscriptions\":[\"message_created\"]}" > /dev/null
  fi
  # confirma o estado FINAL, não o retorno do POST
  WEBHOOKS_JSON_DEPOIS=$(curl -s -H "api_access_token: ${CW_API_TOKEN}" \
    "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}/webhooks" 2>/dev/null)
  WEBHOOK_CONFIRMADO=$(echo "$WEBHOOKS_JSON_DEPOIS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    lista = d.get('payload', d) if isinstance(d, dict) else d
    for w in lista:
        if w.get('url') == '${WEBHOOK_ALVO}':
            subs = w.get('subscriptions', [])
            print('sim' if 'message_created' in subs else 'sem_evento')
            break
    else:
        print('nao')
except Exception:
    print('nao')
" 2>/dev/null)
  case "$WEBHOOK_CONFIRMADO" in
    sim) relatorio "PASS" "Chatwoot webhook" "confirmado: ${WEBHOOK_ALVO} com evento message_created ativo" ;;
    sem_evento) relatorio "FAIL" "Chatwoot webhook" "URL existe mas sem o evento message_created habilitado" ;;
    *) relatorio "FAIL" "Chatwoot webhook" "não encontrado ao reconsultar a conta — o POST pode ter retornado 200 sem persistir" ;;
  esac
fi

cd /home/ubuntu/n8n && docker compose up -d
ok ".env do Harmonia atualizado e N8N reiniciado"

# =============================================================================
# 9.5 PAINEL — deploy do frontend estático (painel.${DOMINIO_BASE})
#    É um único arquivo HTML/CSS/JS sem build: em runtime, ele resolve os
#    domínios de Ritmo/Harmonia/Harpa/Eco a partir do próprio hostname
#    (ver resolverAmbienteSynapse() dentro do arquivo) — então servir esse
#    arquivo estático é tudo que este passo precisa fazer.
#    Fonte, em ordem de prioridade:
#      (a) arquivo local passado como 4º argumento do script
#          (PAINEL_HTML_OVERRIDE)
#      (b) /root/synapse_painel.html na própria VPS (default, sem precisar
#          passar argumento — só copiar o arquivo pra lá antes de rodar)
#      (c) github.com/nomen-me/painel, index.html na raiz (ou 1 nível
#          abaixo)
#    Se nenhuma das três existir, o passo é pulado (não-fatal, mesmo padrão
#    usado pra Brazil NF e pros workflows do Harmonia) e entra no resumo
#    final como pendência, em vez de travar o resto da instalação.
# =============================================================================
log "Instalando o Painel (frontend estático em https://${DOMINIO_PAINEL})..."
mkdir -p /home/ubuntu/painel
PAINEL_HTML_ORIGEM=""
if [ -n "$PAINEL_HTML_OVERRIDE" ]; then
  PAINEL_HTML_ORIGEM="$PAINEL_HTML_OVERRIDE"
  ok "Usando arquivo local informado para o Painel: ${PAINEL_HTML_ORIGEM}"
elif [ -f /root/synapse_painel.html ]; then
  PAINEL_HTML_ORIGEM="/root/synapse_painel.html"
  ok "Usando /root/synapse_painel.html (default, sem precisar passar argumento)"
else
  if clonar_repo_nomen "painel" "/home/ubuntu/painel_src"; then
    CANDIDATO_PAINEL="$(find /home/ubuntu/painel_src -maxdepth 2 -iname 'index.html' 2>/dev/null | head -1)"
    if [ -n "$CANDIDATO_PAINEL" ]; then
      PAINEL_HTML_ORIGEM="$CANDIDATO_PAINEL"
      ok "index.html do Painel encontrado em github.com/${GITHUB_ORG}/painel"
    else
      warn "github.com/${GITHUB_ORG}/painel clonou mas não achei um index.html na raiz (nem 1 nível abaixo)."
    fi
  else
    warn "Não consegui clonar github.com/${GITHUB_ORG}/painel (repo pode não existir ainda, ou GITHUB_TOKEN sem acesso). Passe o HTML como 4º argumento, ou copie-o pra /root/synapse_painel.html, pra não depender desse repo."
  fi
fi

PAINEL_INSTALADO="nao"
if [ -n "$PAINEL_HTML_ORIGEM" ]; then
  # Mount de PASTA, não de arquivo único. Bind mount de arquivo é resolvido
  # por inode na criação do container; qualquer coisa que substitua o arquivo
  # (scp, vim, git, e o próprio `sed -i` logo abaixo) cria um inode novo e o
  # container continua servindo o arquivo antigo, já apagado do host. Como
  # `docker compose up -d` não recria container cujo compose não mudou, cada
  # reexecução entregava o arquivo novo pro host e mantinha o velho no ar.
  # Pasta o Docker resolve por caminho — trocar o index.html passa a valer.
  mkdir -p /home/ubuntu/painel/site /home/ubuntu/painel/conf
  cp "$PAINEL_HTML_ORIGEM" /home/ubuntu/painel/site/index.html

  # Preenche em runtime os 2 únicos valores que o próprio arquivo não tem
  # como descobrir sozinho (o resto é resolvido no navegador a partir do
  # hostname) — sem isso, alguém teria que editar isso à mão depois de
  # publicado. Se o layout do SYNAPSE_CONFIG mudar no repo do painel, estes
  # dois sed's silenciosamente não substituem nada (o grep abaixo avisa).
  sed -i "s|empresa: null,.*|empresa: '$(printf '%s' "$NOME_LOJA" | sed "s/'/\\\\'/g")', // preenchido automaticamente pela instalação|" /home/ubuntu/painel/site/index.html
  sed -i "s|chatwootContaId: null,.*|chatwootContaId: ${CW_ACCOUNT_ID:-null}, // preenchido automaticamente pela instalação|" /home/ubuntu/painel/site/index.html

  if grep -q "empresa: null" /home/ubuntu/painel/site/index.html; then
    warn "Não consegui preencher 'empresa' automaticamente no Painel (o texto 'empresa: null,' não foi encontrado no arquivo — o layout do SYNAPSE_CONFIG pode ter mudado). Preencha manualmente."
  fi
  if grep -q "chatwootContaId: null" /home/ubuntu/painel/site/index.html && [ -n "${CW_ACCOUNT_ID:-}" ]; then
    warn "Não consegui preencher 'chatwootContaId' automaticamente no Painel. Preencha manualmente com o valor ${CW_ACCOUNT_ID}."
  fi

  # O painel é um arquivo único que muda a cada deploy. Revalidação obrigatória
  # custa um HEAD; descobrir semanas depois que o navegador segurou a versão
  # antiga custa muito mais.
  cat > /home/ubuntu/painel/conf/default.conf << 'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location = / {
        add_header Cache-Control "no-store, must-revalidate" always;
        expires -1;
    }
    location = /index.html {
        add_header Cache-Control "no-store, must-revalidate" always;
        expires -1;
    }
    location / {
        try_files $uri =404;
    }
}
EOF

  cat > /home/ubuntu/painel/docker-compose.yml << EOF
services:
  painel:
    image: nginx:${SYNAPSE_NGINX_VERSION}
    container_name: painel
    restart: always
    volumes:
      - ./site:/usr/share/nginx/html:ro
      - ./conf:/etc/nginx/conf.d:ro
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.painel.rule=Host(\`${DOMINIO_PAINEL}\`)"
      - "traefik.http.routers.painel.entrypoints=websecure"
      - "traefik.http.routers.painel.tls.certresolver=myresolver"
      - "traefik.http.routers.painel.priority=10"
      - "traefik.http.services.painel.loadbalancer.server.port=80"
networks:
  stack-network:
    external: true
EOF
  # --force-recreate: numa reexecução o compose não mudou, e sem isso o
  # container antigo seguiria no ar com o conteúdo antigo.
  cd /home/ubuntu/painel && docker compose up -d --force-recreate

  # Verificação contra a realidade, não contra a intenção: não basta o
  # container ter sido recriado (docker compose up) nem o HTTPS responder
  # 200 — HTTP 200 só prova que ALGUMA página respondeu, não que é a certa.
  # Só declara sucesso se host, container e o HTTPS público servirem,
  # byte a byte, o mesmo arquivo. Qualquer divergência é FAIL, não aviso:
  # já aconteceu publicação "concluída" com o Panel antigo continuando no ar.
  sleep 2
  PAINEL_H_HOST="$(sha256sum /home/ubuntu/painel/site/index.html | awk '{print $1}')"
  PAINEL_H_CONT="$(docker exec painel sha256sum /usr/share/nginx/html/index.html 2>/dev/null | awk '{print $1}')"
  PAINEL_H_HTTPS="$(curl -fsSL "https://${DOMINIO_PAINEL}/" 2>/dev/null | sha256sum | awk '{print $1}')"
  log "PANEL_DEPLOY_OK candidato — host_hash=${PAINEL_H_HOST} container_hash=${PAINEL_H_CONT:-vazio} https_hash=${PAINEL_H_HTTPS:-vazio}"
  if [ -n "$PAINEL_H_HOST" ] && [ "$PAINEL_H_HOST" = "$PAINEL_H_CONT" ] && [ "$PAINEL_H_HOST" = "$PAINEL_H_HTTPS" ]; then
    ok "Painel publicado e validado em https://${DOMINIO_PAINEL} — host, container e HTTPS servem o mesmo arquivo (${PAINEL_H_HOST})"
    relatorio "PASS" "Panel" "host=container=https=${PAINEL_H_HOST}"
    PAINEL_INSTALADO="sim"
  else
    err "Painel NÃO validado — host, container e HTTPS não batem (host=${PAINEL_H_HOST} container=${PAINEL_H_CONT:-vazio} https=${PAINEL_H_HTTPS:-vazio}). Não declarando como instalado."
    relatorio "FAIL" "Panel" "host=${PAINEL_H_HOST} container=${PAINEL_H_CONT:-vazio} https=${PAINEL_H_HTTPS:-vazio} — rode: cd /home/ubuntu/painel && docker compose up -d --force-recreate"
    PAINEL_INSTALADO="nao"
  fi
else
  warn "Painel NÃO foi publicado — nenhuma fonte de HTML disponível nesta execução. Rode de novo passando o caminho local como 4º argumento, copiando o arquivo pra /root/synapse_painel.html, ou criando github.com/${GITHUB_ORG}/painel com o index.html (o script é idempotente)."
fi

# =============================================================================
# 9.6 HOME — deploy do frontend estático da raiz (https://${DOMINIO_BASE})
#    Diferente do Painel (9.5), a Home NÃO é um arquivo único: o index.html
#    referencia páginas irmãs (ex: como-funciona.html, integracoes.html,
#    privacy.html, status.html, support.html, terms.html) e uma subpasta
#    assets/ com imagens — então este passo serve uma PASTA inteira via
#    nginx, não só um arquivo. Fonte, em ordem de prioridade:
#      (a) pasta ou arquivo local passado como 5º argumento do script
#          (HOME_SRC_OVERRIDE) — se for pasta, copia tudo que tiver dentro;
#          se for um arquivo único, vira só o index.html (páginas irmãs vão
#          dar 404 até serem colocadas na pasta manualmente)
#      (b) /root/home-site na própria VPS (pasta — default, sem argumento)
#      (c) /root/index.html na própria VPS (arquivo único — default)
#    Se nenhuma existir, o passo é pulado (não-fatal, mesmo padrão do
#    Painel). Ainda não existe um repo oficial pra clonar (diferente do
#    Painel, que já tem github.com/nomen-me/painel) — se/quando existir,
#    adicionar aqui o mesmo fallback de clonar_repo_nomen usado acima.
# =============================================================================
log "Instalando a página inicial (frontend estático em https://${DOMINIO_BASE})..."
mkdir -p /home/ubuntu/home-site/public
HOME_SRC_ORIGEM=""
HOME_SRC_E_PASTA="nao"
if [ -n "$HOME_SRC_OVERRIDE" ]; then
  HOME_SRC_ORIGEM="$HOME_SRC_OVERRIDE"
  if [ -d "$HOME_SRC_OVERRIDE" ]; then
    HOME_SRC_E_PASTA="sim"
    ok "Usando pasta local informada para a Home: ${HOME_SRC_ORIGEM}"
  else
    ok "Usando arquivo local informado para a Home: ${HOME_SRC_ORIGEM}"
  fi
elif [ -d /root/home-site ]; then
  HOME_SRC_ORIGEM="/root/home-site"
  HOME_SRC_E_PASTA="sim"
  ok "Usando /root/home-site (pasta, default, sem precisar passar argumento)"
elif [ -f /root/index.html ]; then
  HOME_SRC_ORIGEM="/root/index.html"
  ok "Usando /root/index.html (arquivo único, default, sem precisar passar argumento)"
else
  warn "Nenhuma fonte de HTML pra Home nesta execução (nem 5º argumento, nem /root/home-site, nem /root/index.html)."
fi

HOME_INSTALADO="nao"
if [ -n "$HOME_SRC_ORIGEM" ]; then
  if [ "$HOME_SRC_E_PASTA" = "sim" ]; then
    cp -r "${HOME_SRC_ORIGEM}/." /home/ubuntu/home-site/public/
  else
    cp "$HOME_SRC_ORIGEM" /home/ubuntu/home-site/public/index.html
  fi

  if [ -f /home/ubuntu/home-site/public/index.html ]; then
    # Avisa (não trava) se o index.html referenciar páginas irmãs que não
    # vieram junto — comum quando só o index.html foi passado sem o resto
    # do site, ou quando a pasta ainda está incompleta.
    PAGINAS_FALTANDO=""
    for pagina in $(grep -oE 'href="[A-Za-z0-9_.-]+\.html"' /home/ubuntu/home-site/public/index.html 2>/dev/null | sed -E 's/href="([^"]+)"/\1/' | sort -u); do
      [ -f "/home/ubuntu/home-site/public/${pagina}" ] || PAGINAS_FALTANDO="${PAGINAS_FALTANDO} ${pagina}"
    done
    if [ -n "$PAGINAS_FALTANDO" ]; then
      warn "index.html da Home referencia páginas que ainda não estão em /home/ubuntu/home-site/public/:${PAGINAS_FALTANDO} — esses links vão dar 404 até você colocar os arquivos lá (mesma pasta) e rodar 'cd /home/ubuntu/home-site && docker compose restart' (não precisa reinstalar tudo)."
    fi

    cat > /home/ubuntu/home-site/docker-compose.yml << EOF
services:
  home-site:
    image: nginx:${SYNAPSE_NGINX_VERSION}
    container_name: home-site
    restart: always
    volumes:
      - ./public:/usr/share/nginx/html:ro
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.home-site.rule=Host(\`${DOMINIO_BASE}\`)"
      - "traefik.http.routers.home-site.entrypoints=websecure"
      - "traefik.http.routers.home-site.tls.certresolver=myresolver"
      - "traefik.http.routers.home-site.priority=10"
      - "traefik.http.services.home-site.loadbalancer.server.port=80"
networks:
  stack-network:
    external: true
EOF
    cd /home/ubuntu/home-site && docker compose up -d
    ok "Página inicial publicada em https://${DOMINIO_BASE}"
    HOME_INSTALADO="sim"
  else
    warn "Copiei ${HOME_SRC_ORIGEM} pra /home/ubuntu/home-site/public/ mas não achei um index.html lá dentro — a Home não foi publicada."
  fi
else
  warn "Página inicial NÃO foi publicada — nenhuma fonte de HTML disponível nesta execução. Rode de novo passando a pasta/arquivo local como 5º argumento, ou copie pra /root/home-site (pasta) ou /root/index.html (arquivo) (o script é idempotente)."
fi

# =============================================================================
# 10. UPTIME KUMA (ECO) + NETDATA (ACORDE)
# =============================================================================
log "Instalando Uptime Kuma (Eco)..."
mkdir -p /home/ubuntu/uptime
cat > /home/ubuntu/uptime/docker-compose.yml << EOF
services:
  uptime-kuma:
    image: louislam/uptime-kuma:${SYNAPSE_UPTIME_KUMA_VERSION}
    container_name: eco
    restart: always
    volumes: [eco_data:/app/data]
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.eco.rule=Host(\`${DOMINIO_UPTIME}\`)"
      - "traefik.http.routers.eco.entrypoints=websecure"
      - "traefik.http.routers.eco.tls.certresolver=myresolver"
      - "traefik.http.routers.eco.priority=1"
      - "traefik.http.routers.eco.middlewares=synapse-infra-auth@docker"
      - "traefik.http.services.eco.loadbalancer.server.port=3001"
      # Status page pública: é feita pra ser lida sem login (é o que o painel
      # do cliente consulta) — fica de fora do Basic Auth, o resto do Eco não.
      - "traefik.http.routers.eco-status-publico.rule=Host(\`${DOMINIO_UPTIME}\`) && PathPrefix(\`/api/status-page\`)"
      - "traefik.http.routers.eco-status-publico.entrypoints=websecure"
      - "traefik.http.routers.eco-status-publico.tls.certresolver=myresolver"
      - "traefik.http.routers.eco-status-publico.priority=10"
      - "traefik.http.routers.eco-status-publico.service=eco"
      - "traefik.http.middlewares.synapse-infra-auth.basicauth.users=${BASICAUTH_USER}:${BASICAUTH_HASH_ESCAPED}"
volumes:
  eco_data:
networks:
  stack-network:
    external: true
EOF
cd /home/ubuntu/uptime && docker compose up -d
ok "Uptime Kuma instalado em https://${DOMINIO_UPTIME} (atrás de Basic Auth; monitores/alertas: configurar manualmente pela UI)"

log "Instalando Netdata (Acorde)..."
mkdir -p /home/ubuntu/netdata
cat > /home/ubuntu/netdata/docker-compose.yml << EOF
services:
  netdata:
    image: netdata/netdata:${SYNAPSE_NETDATA_VERSION}
    container_name: acorde
    restart: always
    cap_add: [SYS_PTRACE, SYS_ADMIN]
    security_opt: [apparmor:unconfined]
    volumes:
      - acorde_config:/etc/netdata
      - acorde_lib:/var/lib/netdata
      - acorde_cache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.acorde.rule=Host(\`${DOMINIO_NETDATA}\`)"
      - "traefik.http.routers.acorde.entrypoints=websecure"
      - "traefik.http.routers.acorde.tls.certresolver=myresolver"
      - "traefik.http.routers.acorde.middlewares=synapse-infra-auth@docker"
      - "traefik.http.services.acorde.loadbalancer.server.port=19999"
volumes:
  acorde_config:
  acorde_lib:
  acorde_cache:
networks:
  stack-network:
    external: true
EOF
cd /home/ubuntu/netdata && docker compose up -d
ok "Netdata instalado em https://${DOMINIO_NETDATA}"

# =============================================================================

# =============================================================================
# 11. ONBOARDING DA PRÓPRIA NOMEN NA LYRA CENTRAL (tenant "atendente interna")
#    Lyra Central está NA MESMA VPS — chama local (127.0.0.1:8080), sem
#    depender de DNS/TLS pra essa parte. A chave já foi capturada na fase 4,
#    sem precisar de nenhuma variável de ambiente externa.
# =============================================================================
log "Provisionando a própria Nomen como tenant '${TENANT_ID}' na Lyra Central..."
HTTP_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "http://127.0.0.1:8080/admin/tenants" \
  -H "Authorization: Bearer ${LYRA_ADMIN_API_KEY}" -H "Content-Type: application/json" \
  -d "{\"tenant_id\": \"${TENANT_ID}\"}")
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)

if [ "$HTTP_STATUS" = "409" ]; then
  warn "Tenant '${TENANT_ID}' já existia na Lyra Central — girando (rotate) a chave pra reaproveitar neste provisionamento."
  HTTP_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "http://127.0.0.1:8080/admin/tenants/${TENANT_ID}/rotate" \
    -H "Authorization: Bearer ${LYRA_ADMIN_API_KEY}")
  HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
  HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)
fi

LYRA_TENANT_API_KEY=""
if [ "$HTTP_STATUS" = "201" ] || [ "$HTTP_STATUS" = "200" ]; then
  LYRA_TENANT_API_KEY=$(echo "$HTTP_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null)
fi

if [ -n "$LYRA_TENANT_API_KEY" ]; then
  salvar_credencial "LYRA_ATENDENTE_TENANT_ID" "$TENANT_ID"
  salvar_credencial "LYRA_ATENDENTE_API_KEY" "$LYRA_TENANT_API_KEY"
  grava_env_n8n "LYRA_CENTRAL_URL" "https://${DOMINIO_LYRA}"
  grava_env_n8n "LYRA_TENANT_ID" "$TENANT_ID"
  grava_env_n8n "LYRA_API_KEY" "$LYRA_TENANT_API_KEY"
  cd /home/ubuntu/n8n && docker compose up -d
  ok "Nomen provisionada como tenant da própria Lyra Central — Harmonia interno já conectado, sem passo manual"
else
  err "Falha ao provisionar a Nomen como tenant (HTTP ${HTTP_STATUS}): ${HTTP_BODY}. Corrija e rode de novo — o script é idempotente."
fi

# 12. WORKFLOWS DO HARMONIA + API KEY PÚBLICA DO N8N (best-effort)
#    ⚠️ Validar antes de confiar em produção: os endpoints REST internos do
#    n8n usados aqui (/rest/owner/setup, /rest/login, /rest/api-keys) não são
#    API pública documentada e podem mudar de formato entre versões — este
#    ambiente de geração de código não teve como testar contra uma instância
#    real. Se falhar, a importação abaixo é pulada e fica só o caminho manual
#    (gerar a chave em Configurações > API na UI do Harmonia e rodar o passo
#    de importação à parte).
# =============================================================================
if [ -n "$WORKFLOWS_DIR_OVERRIDE" ]; then
  WORKFLOWS_DIR="$WORKFLOWS_DIR_OVERRIDE"
  ok "Usando pasta de workflows local informada: ${WORKFLOWS_DIR}"
else
  log "Clonando github.com/${GITHUB_ORG}/json pra pegar os workflows (W0-W4 + Lyra L1-L3 + schema de funções)..."
  if clonar_repo_nomen "json" "/home/ubuntu/json_src"; then
    WORKFLOWS_DIR="/home/ubuntu/json_src"
    # O repo, hoje, tem só um Json.zip cru dentro (sem os arquivos extraídos
    # commitados) — mesma situação que já existia pro repo da Lyra, mesmo
    # fallback: se não achar *.json direto na raiz, procura um .zip e extrai,
    # achatando pra WORKFLOWS_DIR não importar em qual subpasta o zip guardava
    # os arquivos (evita repetir aqui o bug de "0 workflows encontrados" que
    # antes só aparecia como erro fatal do importador, sem essa correção).
    if [ -z "$(find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null)" ]; then
      ZIP_WORKFLOWS="$(find "$WORKFLOWS_DIR" -maxdepth 2 -name '*.zip' -not -path '*/.git/*' 2>/dev/null | head -1)"
      if [ -n "$ZIP_WORKFLOWS" ]; then
        warn "Não achei .json direto em ${WORKFLOWS_DIR} — achei '${ZIP_WORKFLOWS}' (repo só com o zip cru, sem commit dos arquivos extraídos). Extraindo automaticamente (muleta; o certo é commitar os arquivos extraídos no repo, não o .zip)."
        command -v unzip >/dev/null 2>&1 || apt install -y unzip >/dev/null 2>&1
        EXTRACT_TMP_WF="$(mktemp -d)"
        unzip -o "$ZIP_WORKFLOWS" -d "$EXTRACT_TMP_WF" >/dev/null 2>&1
        # Achata: copia qualquer *.json encontrado em qualquer profundidade
        # direto pra WORKFLOWS_DIR, não importa a subpasta onde o zip guardou.
        find "$EXTRACT_TMP_WF" -name '*.json' -exec cp -t "$WORKFLOWS_DIR" {} + 2>/dev/null
        find "$EXTRACT_TMP_WF" -name '*.js' -exec cp -t "$WORKFLOWS_DIR" {} + 2>/dev/null
        rm -rf "$EXTRACT_TMP_WF"
      fi
    fi
    QTD_JSON="$(find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
    if [ "$QTD_JSON" -gt 0 ]; then
      ok "Workflows encontrados em ${WORKFLOWS_DIR} (${QTD_JSON} arquivos .json — o lyra_functions.json de lá é ignorado na importação, não é workflow, é o schema de tools consumido pela Lyra Central, não pelo Harmonia)"
    else
      err "Nenhum .json encontrado em ${WORKFLOWS_DIR} mesmo depois de tentar extrair zip — importação de workflows será pulada. Confira manualmente o conteúdo de github.com/${GITHUB_ORG}/json."
      WORKFLOWS_DIR=""
    fi
  else
    warn "Falha ao clonar github.com/${GITHUB_ORG}/json (confirma GITHUB_TOKEN) — importação de workflows será pulada."
    WORKFLOWS_DIR=""
  fi
fi

N8N_API_KEY=""
if [ -n "$WORKFLOWS_DIR" ] && [ -d "$WORKFLOWS_DIR" ]; then
  log "Tentando gerar API key pública do N8N automaticamente..."
  N8N_BASE="https://${DOMINIO_N8N}"
  N8N_AUTOMACAO_EMAIL="automacao@${DOMINIO_BASE}"

  # Não existe forma oficial (API/CLI/env var) de criar essa chave sem
  # passar pela UI — confirmado na documentação e na comunidade do próprio
  # n8n. Isto continua batendo em endpoints internos não documentados (não
  # tem alternativa), mas agora espera o n8n estar de pé de verdade antes de
  # tentar — tentar isso logo depois do "docker compose up -d" é o motivo
  # mais comum de falha (container ainda migrando o banco), não o formato
  # do endpoint em si.
  log "Aguardando o Harmonia (n8n) responder em ${N8N_BASE}/healthz..."
  N8N_PRONTO=false
  for _tentativa in $(seq 1 30); do
    if curl -fsS -o /dev/null "${N8N_BASE}/healthz" 2>/dev/null; then
      N8N_PRONTO=true
      break
    fi
    sleep 3
  done
  if [ "$N8N_PRONTO" = false ]; then
    warn "n8n não respondeu em /healthz depois de 90s — tentando gerar a API key mesmo assim (pode falhar por isso)."
  else
    ok "n8n respondendo em /healthz"
  fi

  N8N_API_KEY=""
  for _tentativa in 1 2 3; do
    COOKIEJAR="/tmp/synapse_n8n_cookie_$$"

    HTTP_SETUP=$(curl -s -o /tmp/synapse_n8n_setup.json -w '%{http_code}' -c "$COOKIEJAR" \
      -X POST "${N8N_BASE}/rest/owner/setup" -H 'Content-Type: application/json' \
      -d "{\"email\":\"${N8N_AUTOMACAO_EMAIL}\",\"firstName\":\"Synapse\",\"lastName\":\"Automacao\",\"password\":\"${SENHA}\"}")

    if [ "$HTTP_SETUP" != "200" ]; then
      # owner já pode existir de um rerun anterior — tenta login em vez de
      # setup, e mostra o corpo real de cada resposta pra não ficar cego
      # sobre qual dos dois passos falhou e por quê.
      HTTP_LOGIN=$(curl -s -o /tmp/synapse_n8n_login.json -w '%{http_code}' -c "$COOKIEJAR" \
        -X POST "${N8N_BASE}/rest/login" -H 'Content-Type: application/json' \
        -d "{\"email\":\"${N8N_AUTOMACAO_EMAIL}\",\"password\":\"${SENHA}\"}")
      if [ "$HTTP_LOGIN" != "200" ]; then
        warn "Tentativa ${_tentativa}/3: setup=HTTP ${HTTP_SETUP} ($(cat /tmp/synapse_n8n_setup.json 2>/dev/null | head -c 200)), login=HTTP ${HTTP_LOGIN} ($(cat /tmp/synapse_n8n_login.json 2>/dev/null | head -c 200))"
        rm -f "$COOKIEJAR"
        sleep 5
        continue
      fi
    fi

    HTTP_KEY=$(curl -s -b "$COOKIEJAR" -o /tmp/synapse_n8n_key.json -w '%{http_code}' \
      -X POST "${N8N_BASE}/rest/api-keys" \
      -H 'Content-Type: application/json' -d '{"label":"synapse-provisionamento"}')
    rm -f "$COOKIEJAR"

    if [ "$HTTP_KEY" = "200" ] || [ "$HTTP_KEY" = "201" ]; then
      N8N_API_KEY=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/synapse_n8n_key.json'))
    for k in ('rawApiKey', 'apiKey', 'key'):
        v = d.get(k) or (d.get('data') or {}).get(k)
        if v:
            print(v); break
except Exception:
    pass
" 2>/dev/null)
      [ -n "$N8N_API_KEY" ] && break
      warn "Tentativa ${_tentativa}/3: /rest/api-keys respondeu HTTP ${HTTP_KEY} mas sem chave reconhecível no corpo: $(cat /tmp/synapse_n8n_key.json 2>/dev/null | head -c 200)"
    else
      warn "Tentativa ${_tentativa}/3: /rest/api-keys respondeu HTTP ${HTTP_KEY}: $(cat /tmp/synapse_n8n_key.json 2>/dev/null | head -c 200)"
    fi
    sleep 5
  done

  if [ -n "$N8N_API_KEY" ]; then
    salvar_credencial "N8N_API_KEY" "$N8N_API_KEY"
    ok "API key pública do N8N gerada automaticamente"

    log "Importando workflows de ${WORKFLOWS_DIR}..."
    N8N_URL="$N8N_BASE" N8N_API_KEY="$N8N_API_KEY" python3 - "$WORKFLOWS_DIR" <<'PYEOF'
import os, sys, json, glob, urllib.request, urllib.error

N8N_URL = os.environ.get("N8N_URL", "").rstrip("/")
N8N_API_KEY = os.environ.get("N8N_API_KEY", "")
PASTA = sys.argv[1] if len(sys.argv) > 1 else "."

def chamar(metodo, caminho, corpo=None):
    req = urllib.request.Request(
        N8N_URL + caminho, method=metodo,
        headers={"X-N8N-API-KEY": N8N_API_KEY, "Content-Type": "application/json"},
        data=json.dumps(corpo).encode() if corpo is not None else None,
    )
    try:
        with urllib.request.urlopen(req) as resp:
            corpo_resp = resp.read()
            return json.loads(corpo_resp) if corpo_resp else {}
    except urllib.error.HTTPError as e:
        print(f"   erro HTTP {e.code}: {e.read().decode()[:300]}")
        return None

def existente_por_nome(nome):
    dados = chamar("GET", "/api/v1/workflows?limit=250")
    if not dados:
        return None
    for wf in dados.get("data", []):
        if wf["name"] == nome:
            return wf["id"]
    return None

def limpar_para_import(wf):
    for chave in ("id", "createdAt", "updatedAt", "versionId", "active", "tags"):
        wf.pop(chave, None)
    return wf

arquivos = sorted(glob.glob(os.path.join(PASTA, "*.json")))
if not arquivos:
    sys.exit(f"Nenhum .json encontrado em {PASTA}")

print(f"== Synapse — importando workflows reais em {N8N_URL} ==")
resultados = []
for caminho in arquivos:
    with open(caminho, encoding="utf-8") as f:
        conteudo = json.load(f)
    if "nodes" not in conteudo:
        print(f"   pulado (não é workflow): {os.path.basename(caminho)}")
        continue
    wf = limpar_para_import(conteudo)
    nome = wf["name"]
    existente_id = existente_por_nome(nome)
    if existente_id:
        resultado = chamar("PUT", f"/api/v1/workflows/{existente_id}", wf)
        acao, wf_id = "atualizado", existente_id
    else:
        resultado = chamar("POST", "/api/v1/workflows", wf)
        acao = "criado"
        wf_id = resultado["id"] if resultado else None
    ativado = False
    if resultado and wf_id:
        ativado = chamar("POST", f"/api/v1/workflows/{wf_id}/activate") is not None
        print(f"   {acao} e ativado: {nome}")
    else:
        print(f"   FALHOU: {nome} — revise o erro acima")
    resultados.append({"nome": nome, "id": wf_id, "acao": acao if resultado else "falhou", "ativo": ativado})

with open("/tmp/synapse_import_resultado.json", "w", encoding="utf-8") as f:
    json.dump(resultados, f, ensure_ascii=False)
print("Pronto. Confira no editor do n8n se os webhooks path batem com o que os outros serviços chamam.")
PYEOF

    # Verificação real do que foi importado — não confia só no que o loop
    # acima imprimiu, reconsulta a API e confere existência + estado ativo
    # do workflow que a cadeia WhatsApp precisa (Lyra_L1_triagem), além de
    # contar falhas de qualquer outro.
    if [ -f /tmp/synapse_import_resultado.json ]; then
      RESUMO_IMPORT=$(python3 -c "
import json
try:
    r = json.load(open('/tmp/synapse_import_resultado.json'))
except Exception:
    print('erro|0|0'); raise SystemExit
falhas = [w['nome'] for w in r if w['acao'] == 'falhou']
l1 = next((w for w in r if 'L1' in w['nome'] and 'Triagem' in w['nome']), None)
l1_ok = 'sim' if (l1 and l1['ativo']) else 'nao'
print(f\"{len(r)}|{len(falhas)}|{l1_ok}|{','.join(falhas) if falhas else '-'}\")
" 2>/dev/null)
      IFS='|' read -r QTD_WF QTD_FALHAS_WF L1_ATIVO NOMES_FALHOS <<< "$RESUMO_IMPORT"
      if [ "${QTD_FALHAS_WF:-1}" = "0" ] && [ -n "$QTD_WF" ]; then
        relatorio "PASS" "workflows" "${QTD_WF} workflows importados e ativados, verificado via GET /api/v1/workflows"
      else
        relatorio "FAIL" "workflows" "${QTD_FALHAS_WF:-?} de ${QTD_WF:-?} falharam: ${NOMES_FALHOS:-desconhecido}"
      fi
      if [ "$L1_ATIVO" = "sim" ]; then
        relatorio "PASS" "workflow Lyra L1 Triagem" "existe e está ativo"
      else
        relatorio "FAIL" "workflow Lyra L1 Triagem" "não encontrado ativo após import — cadeia do WhatsApp não vai responder"
      fi
    else
      relatorio "FAIL" "workflows" "script de importação não gerou resultado (falha antes de terminar)"
    fi
  else
    relatorio "FAIL" "N8N API key" "não gerada automaticamente após retries — ver diagnóstico HTTP acima"
    relatorio "FAIL" "workflows" "pulado — sem API key do n8n"
    warn "Não consegui gerar a API key pública do N8N automaticamente (endpoint interno pode ter mudado). Importação de workflows pulada. A UI do Harmonia não responde mais publicamente (GUI escondida de propósito) e a porta 5678 não é publicada no host — pra gerar a chave manualmente: (1) adicione 'ports: [\"127.0.0.1:5678:5678\"]' ao serviço n8n em /home/ubuntu/n8n/docker-compose.yml, (2) 'docker compose up -d', (3) na sua máquina: 'ssh -L 5678:localhost:5678 <usuario>@<ip-da-vps>' e abra http://localhost:5678 (Configurações > API), (4) remova a linha 'ports:' e rode 'docker compose up -d' de novo pra fechar o acesso. Depois: N8N_URL=https://${DOMINIO_N8N} N8N_API_KEY=<chave> python3 2_importar_workflows_harmonia.py ${WORKFLOWS_DIR}"
  fi
fi

# =============================================================================

# =============================================================================
# 13. SEMAPHORE UI (orquestração de Ansible) — rede própria, sem Traefik,
#    só acessível via túnel SSH (não é por-cliente, é só pra operação da Nomen)
# =============================================================================
log "Instalando Semaphore UI..."
if docker inspect semaphore >/dev/null 2>&1; then
  warn "Já existe um container 'semaphore' nesta VPS — reaproveitando/atualizando."
fi
docker network create semaphore-network 2>/dev/null || true

porta_em_uso() {
  local porta="$1"
  if docker ps --filter "name=^semaphore$" --format '{{.Ports}}' 2>/dev/null | grep -q "127.0.0.1:${porta}->"; then
    return 1
  fi
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${porta}$"
}
while porta_em_uso "$SEMAPHORE_PORT"; do
  warn "Porta 127.0.0.1:${SEMAPHORE_PORT} já está em uso por outro serviço nesta VPS — tentando a próxima."
  SEMAPHORE_PORT=$((SEMAPHORE_PORT + 1))
done
ok "Semaphore vai usar a porta local ${SEMAPHORE_PORT} (127.0.0.1:${SEMAPHORE_PORT} -> container:3000)"

SEMAPHORE_ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)"
SEMAPHORE_ACCESS_KEY_ENCRYPTION="$(head -c32 /dev/urandom | base64)"
salvar_credencial "SEMAPHORE_PORT" "$SEMAPHORE_PORT"
salvar_credencial "SEMAPHORE_ADMIN_USER" "$SEMAPHORE_ADMIN_USER"
salvar_credencial "SEMAPHORE_ADMIN_PASSWORD" "$SEMAPHORE_ADMIN_PASSWORD"

mkdir -p /home/ubuntu/semaphore
cat > /home/ubuntu/semaphore/docker-compose.yml << EOF
services:
  semaphore:
    image: semaphoreui/semaphore:${SYNAPSE_SEMAPHORE_VERSION}
    container_name: semaphore
    restart: always
    ports:
      - "127.0.0.1:${SEMAPHORE_PORT}:3000"
    environment:
      # bolt (BoltDB embutido) foi descontinuado no Semaphore 2.16 e REMOVIDO
      # de vez no 2.19 — a baseline fixa v2.19.12, onde "bolt" já não existe
      # mais e crasharia com "Unknown database dialect: bolt" se usado.
      # sqlite é o substituto oficial recomendado, mesma ideia (embutido, um
      # arquivo só, sem precisar de MySQL/Postgres à parte) — funciona com
      # as mesmas variáveis, sem precisar de configuração extra.
      SEMAPHORE_DB_DIALECT: sqlite
      SEMAPHORE_ADMIN: ${SEMAPHORE_ADMIN_USER}
      SEMAPHORE_ADMIN_PASSWORD: ${SEMAPHORE_ADMIN_PASSWORD}
      SEMAPHORE_ADMIN_NAME: "Synapse Ops"
      SEMAPHORE_ADMIN_EMAIL: ${SEMAPHORE_ADMIN_EMAIL}
      SEMAPHORE_ACCESS_KEY_ENCRYPTION: ${SEMAPHORE_ACCESS_KEY_ENCRYPTION}
      TZ: America/Sao_Paulo
    volumes:
      - semaphore_config:/etc/semaphore
      - semaphore_data:/var/lib/semaphore
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - semaphore-network
volumes:
  semaphore_config:
  semaphore_data:
networks:
  semaphore-network:
    external: true
EOF

cd /home/ubuntu/semaphore && docker compose up -d || err "Falha ao subir o Semaphore UI. Verifica 'docker logs semaphore'."

log "Aguardando o Semaphore responder localmente..."
TENTATIVAS=0
until curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${SEMAPHORE_PORT}"; do
  TENTATIVAS=$((TENTATIVAS+1))
  [ $TENTATIVAS -ge 20 ] && { err "Semaphore não respondeu em 40s. Verifica 'docker logs semaphore'."; break; }
  sleep 2
done
ok "Semaphore UI no ar (verificado localmente em http://127.0.0.1:${SEMAPHORE_PORT})"

# =============================================================================
# 13B. SEMAPHORE — CONFIGURAÇÃO AUTOMÁTICA (só nesta VPS de gestão; clientes
#      nunca recebem Semaphore). Usa o configurar_semaphore_synapse.sh do
#      bundle oficial — não reimplementa nada: cria projeto, Key Store,
#      repositório, Environment, Inventory, templates e agendamento via API,
#      de forma idempotente. O container acima já existe, então o script do
#      bundle NÃO tenta instalar o Semaphore de novo (ele detecta e preserva).
#
#      Onde estão os arquivos do bundle (nesta ordem):
#        1. SEMAPHORE_BUNDLE_DIR (variável de ambiente, pasta 'semaphore/'
#           extraída do bundle)
#        2. github.com/${GITHUB_ORG}/synapse, subpasta semaphore/
#      Nenhum dos dois achado => etapa FALHA de forma explícita no relatório
#      (nunca some em silêncio).
# =============================================================================
log "Configurando o Semaphore (projeto Synapse, chaves, repo, templates)..."
SEMA_BUNDLE_DIR="${SEMAPHORE_BUNDLE_DIR:-}"
if [ -z "$SEMA_BUNDLE_DIR" ] || [ ! -f "${SEMA_BUNDLE_DIR}/configurar_semaphore_synapse.sh" ]; then
  if clonar_repo_nomen "synapse" "/home/ubuntu/synapse_src" \
     && [ -f "/home/ubuntu/synapse_src/semaphore/configurar_semaphore_synapse.sh" ]; then
    SEMA_BUNDLE_DIR="/home/ubuntu/synapse_src/semaphore"
  else
    SEMA_BUNDLE_DIR=""
  fi
fi

SEMA_CONFIG_OK=false
if [ -z "$SEMA_BUNDLE_DIR" ]; then
  relatorio "FAIL" "Semaphore configurado" "bundle não encontrado — exporte SEMAPHORE_BUNDLE_DIR=<pasta semaphore/ extraída> ou commite o bundle em ${GITHUB_ORG}/synapse (subpasta semaphore/) e rode de novo (idempotente)"
else
  SEMA_LOG="/var/log/synapse_semaphore_config.log"
  : > "$SEMA_LOG"; chmod 600 "$SEMA_LOG"
  # Segredos entram só por variável de ambiente deste processo filho —
  # nunca por argumento (apareceria em ps) e nunca no log (filtro abaixo).
  ( cd "$SEMA_BUNDLE_DIR" && \
    SEMAPHORE_URL="http://127.0.0.1:${SEMAPHORE_PORT}" \
    SEMAPHORE_LOGIN="$SEMAPHORE_ADMIN_USER" \
    SEMAPHORE_PASSWORD="$SEMAPHORE_ADMIN_PASSWORD" \
    GITHUB_TOKEN="$GITHUB_TOKEN" \
    LYRA_CENTRAL_URL="$LYRA_CENTRAL_URL" \
    LYRA_ADMIN_API_KEY="$LYRA_ADMIN_API_KEY" \
    bash ./configurar_semaphore_synapse.sh ) 2>&1 \
    | sed -e "s|${GITHUB_TOKEN}|***REDACTED***|g" \
          -e "s|${SEMAPHORE_ADMIN_PASSWORD}|***REDACTED***|g" \
          -e "s|${LYRA_ADMIN_API_KEY}|***REDACTED***|g" >> "$SEMA_LOG"
  SEMA_RC=${PIPESTATUS[0]}

  # Verificação INDEPENDENTE do que o script disse: loga na API de novo e
  # confere que o projeto Synapse e os 3 templates existem de verdade.
  SEMA_COOKIE="$(mktemp)"
  SEMA_LOGIN_BODY=$(SEMA_U="$SEMAPHORE_ADMIN_USER" SEMA_P="$SEMAPHORE_ADMIN_PASSWORD" python3 -c "
import json, os
print(json.dumps({'auth': os.environ['SEMA_U'], 'password': os.environ['SEMA_P']}))")
  SEMA_HTTP=$(curl -s -o /dev/null -w '%{http_code}' -c "$SEMA_COOKIE" -X POST \
    -H 'Content-Type: application/json' -d "$SEMA_LOGIN_BODY" \
    "http://127.0.0.1:${SEMAPHORE_PORT}/api/auth/login")
  if [ "$SEMA_HTTP" = "204" ] || [ "$SEMA_HTTP" = "200" ]; then
    SEMA_PROJ_ID=$(curl -s -b "$SEMA_COOKIE" "http://127.0.0.1:${SEMAPHORE_PORT}/api/projects" \
      | jq -r '.[] | select(.name=="Synapse") | .id' 2>/dev/null | head -n1)
    SEMA_QTD_TPL=0
    if [ -n "$SEMA_PROJ_ID" ]; then
      SEMA_QTD_TPL=$(curl -s -b "$SEMA_COOKIE" "http://127.0.0.1:${SEMAPHORE_PORT}/api/project/${SEMA_PROJ_ID}/templates" \
        | jq -r '[.[] | select(.name=="Provisionar Cliente" or .name=="Atualizar Cliente" or .name=="Backup Diário")] | length' 2>/dev/null)
    fi
    if [ -n "$SEMA_PROJ_ID" ] && [ "${SEMA_QTD_TPL:-0}" -ge 3 ]; then
      SEMA_CONFIG_OK=true
      relatorio "PASS" "Semaphore configurado" "projeto Synapse (id=${SEMA_PROJ_ID}) com os 3 templates, confirmado via API"
    else
      relatorio "FAIL" "Semaphore configurado" "após o script: projeto=${SEMA_PROJ_ID:-ausente}, templates encontrados=${SEMA_QTD_TPL:-0}/3 (exit do script=${SEMA_RC}) — ver ${SEMA_LOG}"
    fi
  else
    relatorio "FAIL" "Semaphore configurado" "login na API falhou (HTTP ${SEMA_HTTP}) — o script de configuração não teria conseguido autenticar (exit=${SEMA_RC}); ver ${SEMA_LOG}"
  fi
  rm -f "$SEMA_COOKIE"

  # O bundle lista suas próprias pendências: repassa as linhas dele, sem
  # esconder nenhuma (ex.: falha de push por token só-leitura).
  SEMA_PENDENCIAS=$(sed -n '/4\. Etapas pendentes/,/Templates confirmados/p' "$SEMA_LOG" \
    | grep '^  - ' | sed 's/\x1b\[[0-9;]*m//g' | head -c 1500)
  if [ -n "$SEMA_PENDENCIAS" ]; then
    relatorio "EXCEÇÃO" "Semaphore — pendências declaradas pelo bundle" "$(echo "$SEMA_PENDENCIAS" | tr '\n' ' ')"
  fi
fi


# =============================================================================
# 14. VALIDAÇÃO FINAL
# =============================================================================
log "Validando serviços instalados..."
sleep 10
check_service() {
  local nome=$1 url=$2 auth="${3:-}"
  local code
  if [ -n "$auth" ]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -u "$auth" "$url" 2>/dev/null)
  else
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
  fi
  if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
    ok "$nome respondeu HTTP $code"
  else
    err "$nome não respondeu correctamente (HTTP $code) — verifica DNS e logs do container"
  fi
}
check_service "Lyra Central — local"       "http://127.0.0.1:8080/healthz"
check_service "Lyra Central — pública"     "https://${DOMINIO_LYRA}/healthz"

# GEMINI_API_KEY/GEMINI_MODEL: confirma que estão gravados no .env real da
# Lyra Central (não em variável do instalador, que não prova que o
# PROCESSO da Lyra os usa) e depois faz uma chamada REAL a /v1/chat pra
# confirmar que o motor está de fato respondendo através deles.
if [ -f "${LYRA_APP_DIR}/.env" ] && grep -q '^GEMINI_API_KEY=.\+' "${LYRA_APP_DIR}/.env"; then
  relatorio "PASS" "Gemini" "GEMINI_API_KEY presente no .env da Lyra Central"
else
  relatorio "FAIL" "Gemini" "GEMINI_API_KEY ausente ou vazio em ${LYRA_APP_DIR}/.env"
fi
GEMINI_MODEL_CONFIGURADO=$(grep '^GEMINI_MODEL=' "${LYRA_APP_DIR}/.env" 2>/dev/null | cut -d= -f2-)

if [ -n "$LYRA_TENANT_API_KEY" ]; then
  HTTP_CHAT_TESTE=$(curl -s -o /tmp/synapse_lyra_chat_teste.json -w '%{http_code}' --max-time 30 \
    -X POST "https://${DOMINIO_LYRA}/v1/chat" \
    -H "Authorization: Bearer ${LYRA_TENANT_API_KEY}" -H "X-Tenant-ID: ${TENANT_ID}" \
    -H 'Content-Type: application/json' \
    -d '{"conversation_id":"synapse-provisionamento-teste","message":"teste automático de provisionamento, responda em 1 palavra"}')
  if [ "$HTTP_CHAT_TESTE" = "200" ]; then
    FINISH_REASON_TESTE=$(grep -o "finish_reason[^}]*" /tmp/synapse_lyra_chat_teste.json 2>/dev/null | head -1)
    if echo "$FINISH_REASON_TESTE" | grep -qi "infra_failure"; then
      relatorio "FAIL" "Lyra Central" "/v1/chat respondeu HTTP 200 mas com finish_reason infra_failure — Gemini configurado (${GEMINI_MODEL_CONFIGURADO:-default}) porém a chamada real falhou"
    else
      relatorio "PASS" "Lyra Central" "/v1/chat respondeu com sucesso usando GEMINI_MODEL=${GEMINI_MODEL_CONFIGURADO:-default}"
    fi
  else
    relatorio "FAIL" "Lyra Central" "/v1/chat HTTP ${HTTP_CHAT_TESTE} — $(cat /tmp/synapse_lyra_chat_teste.json 2>/dev/null | head -c 200)"
  fi
else
  relatorio "FAIL" "Lyra Central" "sem LYRA_TENANT_API_KEY — onboarding do tenant falhou antes, não dá pra testar /v1/chat de verdade"
fi
check_service "ERPNext (Ritmo) — API"      "https://${DOMINIO_ERP}/api/method/ping"
check_service "N8N (Harmonia) — healthz"   "https://${DOMINIO_N8N}/healthz"
check_service "Chatwoot (Harpa) — widget"  "https://${DOMINIO_CHAT}/packs/js/sdk.js"
check_service "Uptime (Eco) — Basic Auth"  "https://${DOMINIO_UPTIME}" "${BASICAUTH_USER}:${BASICAUTH_PASS}"

# --- Teste de ponta a ponta AUTOMÁTICO possível daqui: injeta um evento no
#     formato real do Chatwoot direto no webhook do n8n e confere no
#     próprio n8n se a execução rodou com sucesso. Isso prova
#     Chatwoot-shape -> n8n -> Lyra -> Gemini -> Lyra -> n8n de ponta a
#     ponta. O único trecho que ISSO NÃO prova é Meta -> Chatwoot em si
#     (exigiria mandar uma mensagem de um número de telefone real) — fica
#     honestamente marcado como exceção, não fingido como testado.
if [ -n "${N8N_API_KEY:-}" ] && [ "$L1_ATIVO" = "sim" ]; then
  PAYLOAD_TESTE_E2E=$(python3 -c "
import json
print(json.dumps({
    'event': 'message_created',
    'message_type': 'incoming',
    'private': False,
    'content': 'teste automático de provisionamento',
    'conversation': {'id': 999999001, 'status': 'open'},
    'inbox': {'channel_type': 'Channel::Whatsapp'},
    'sender': {'id': 999999001, 'name': 'Provisionamento Synapse', 'phone_number': '+000000000'}
}))
")
  curl -s -o /dev/null -X POST "https://${DOMINIO_N8N}/webhook/synapse-atendimento" \
    -H 'Content-Type: application/json' -d "$PAYLOAD_TESTE_E2E"
  sleep 8
  L1_WF_ID=$(python3 -c "
import json
try:
    r = json.load(open('/tmp/synapse_import_resultado.json'))
    l1 = next((w for w in r if 'L1' in w['nome'] and 'Triagem' in w['nome']), None)
    print(l1['id'] if l1 else '')
except Exception:
    pass
" 2>/dev/null)
  if [ -n "$L1_WF_ID" ]; then
    EXEC_JSON=$(curl -s -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      "https://${DOMINIO_N8N}/api/v1/executions?workflowId=${L1_WF_ID}&limit=1" 2>/dev/null)
    STATUS_EXEC=$(echo "$EXEC_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ex = (d.get('data') or [None])[0]
    print(ex.get('status','desconhecido') if ex else 'sem_execucao')
except Exception:
    print('erro')
" 2>/dev/null)
    if [ "$STATUS_EXEC" = "success" ]; then
      relatorio "PASS" "integração ponta a ponta (sintética)" "Chatwoot-shape -> n8n -> Lyra -> Gemini -> n8n executou com sucesso. Meta -> Chatwoot em si só é validado com uma mensagem real de telefone (fora do alcance de automação sem enviar mensagem real a um destinatário)."
    else
      relatorio "FAIL" "integração ponta a ponta (sintética)" "última execução do workflow L1 = '${STATUS_EXEC}' (esperado 'success') — confira em ${N8N_BASE}/workflow/${L1_WF_ID}/executions"
    fi
  else
    relatorio "FAIL" "integração ponta a ponta (sintética)" "não achei o ID do workflow L1 pra checar a execução"
  fi
else
  relatorio "FAIL" "integração ponta a ponta (sintética)" "pulado — depende de N8N API key e do workflow L1 ativo"
fi
check_service "Netdata (Acorde) — Basic Auth" "https://${DOMINIO_NETDATA}" "${BASICAUTH_USER}:${BASICAUTH_PASS}"
if [ "$PAINEL_INSTALADO" = "sim" ]; then
  check_service "Painel"                     "https://${DOMINIO_PAINEL}"
fi
if [ "$HOME_INSTALADO" = "sim" ]; then
  check_service "Home (raiz)"                "https://${DOMINIO_BASE}"
fi

CODE_SEMA=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${SEMAPHORE_PORT}" 2>/dev/null)
[ "$CODE_SEMA" = "200" ] && ok "Semaphore — local respondeu HTTP 200" || err "Semaphore local não respondeu (HTTP ${CODE_SEMA})"

log "Confirmando que as GUIs internas estão de fato bloqueadas (deve dar 404)..."
for par in "ERPNext (Ritmo)|https://${DOMINIO_ERP}/app" "N8N (Harmonia)|https://${DOMINIO_N8N}/" "Chatwoot (Harpa)|https://${DOMINIO_CHAT}/app/login"; do
  nome="${par%%|*}"; url="${par##*|}"
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
  if [ "$code" == "404" ]; then
    ok "$nome bloqueado corretamente (GET nessa rota devolveu 404)"
  else
    err "$nome deveria devolver 404 nessa rota e devolveu HTTP $code — revise as labels do Traefik antes de considerar a instalação segura"
  fi
done

# =============================================================================
# 15. REINÍCIO (SE NECESSÁRIO PARA O PATCH DE KERNEL)
# =============================================================================
if [ "$REINICIO_NECESSARIO" = true ]; then
  if [ "$AUTO_REBOOT" = "sim" ]; then
    log "AUTO_REBOOT=sim — reiniciando em 5s (Ctrl+C pra cancelar)..."
    sleep 5
    reboot
  else
    echo -e "${YELLOW}Há um patch de kernel pendente (CVE-2026-53359). Reiniciar agora? Digite 'sim' pra continuar:${NC}"
    read -r CONFIRMACAO
    if [ "$CONFIRMACAO" = "sim" ]; then
      log "Reiniciando em 5s (Ctrl+C pra cancelar)..."
      sleep 5
      reboot
    else
      warn "Reinício adiado — os containers têm restart:always e o systemd da Lyra Central volta sozinho quando você reiniciar manualmente (sudo reboot)."
    fi
  fi
fi

# =============================================================================
# RELATÓRIO FINAL — PASS/FAIL real, não "instalação concluída" por hábito
# =============================================================================
# Confere de verdade — o script usa 'set -uo pipefail', NÃO 'set -e', e o
# próprio helper err() não interrompe a execução (de propósito, pra um
# check isolado não derrubar o provisionamento inteiro). Então nenhuma
# dessas linhas pode ser assumida como PASS sem checar agora — a alegação
# antiga aqui ("set -e já teria interrompido") tinha 2 erros factuais e
# foi removida.
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  && relatorio "PASS" "Docker" "daemon respondendo" \
  || relatorio "FAIL" "Docker" "'docker info' falhou"

systemctl is-active --quiet redis-server \
  && relatorio "PASS" "Redis (Lyra, local)" "redis-server ativo" \
  || relatorio "FAIL" "Redis (Lyra, local)" "systemctl is-active redis-server falhou"

docker exec harpa-redis redis-cli ping 2>/dev/null | grep -q PONG \
  && relatorio "PASS" "Redis (Harpa)" "PONG" \
  || relatorio "FAIL" "Redis (Harpa)" "container harpa-redis não respondeu PING"

docker exec harpa-postgres pg_isready >/dev/null 2>&1 \
  && relatorio "PASS" "PostgreSQL (Harpa)" "pg_isready OK" \
  || relatorio "FAIL" "PostgreSQL (Harpa)" "container harpa-postgres não respondeu pg_isready"

docker exec ritmo-db-1 mariadb-admin ping -h localhost --silent 2>/dev/null \
  && relatorio "PASS" "MariaDB (Ritmo/ERPNext)" "ping OK" \
  || relatorio "FAIL" "MariaDB (Ritmo/ERPNext)" "container ritmo-db-1 não respondeu"

CODE_ERPNEXT_PING=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${DOMINIO_ERP}/api/method/ping" 2>/dev/null)
[ "$CODE_ERPNEXT_PING" = "200" ] \
  && relatorio "PASS" "ERPNext API" "HTTP 200 em /api/method/ping" \
  || relatorio "FAIL" "ERPNext API" "HTTP ${CODE_ERPNEXT_PING}"

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   RELATÓRIO FINAL DE PROVISIONAMENTO — ${DOMINIO_BASE}${NC}"
echo -e "${GREEN}============================================================${NC}"
for _linha in "${RELATORIO_LINHAS[@]}"; do
  if [[ "$_linha" == "[PASS]"* ]]; then
    echo -e "${GREEN}${_linha}${NC}"
  elif [[ "$_linha" == "[EXCEÇÃO]"* ]]; then
    echo -e "${YELLOW}${_linha}${NC}"
  else
    echo -e "${RED}${_linha}${NC}"
  fi
done
echo -e "${GREEN}============================================================${NC}"
if [ "$FALHA_CRITICA" = true ]; then
  echo -e "${RED}INSTALAÇÃO PARCIALMENTE CONCLUÍDA — há [FAIL] acima. NÃO declarar concluída.${NC}"
elif printf '%s\n' "${RELATORIO_LINHAS[@]}" | grep -q '^\[EXCEÇÃO\]'; then
  echo -e "${YELLOW}INSTALAÇÃO CONCLUÍDA COM EXCEÇÕES DECLARADAS — nenhum [FAIL], mas há [EXCEÇÃO] acima que exige ação manual explícita.${NC}"
else
  echo -e "${GREEN}INSTALAÇÃO CONCLUÍDA — todos os checks do relatório passaram.${NC}"
fi
echo -e "${GREEN}============================================================${NC}"
echo -e "  Lyra Central      → https://${DOMINIO_LYRA}  (systemctl status lyra-central-api)"
echo -e "  Lyra atendente    → tenant '${TENANT_ID}' (a própria Nomen, já conectada ao Harmonia)"
echo -e "  Ritmo (ERPNext)   → https://${DOMINIO_ERP}  (com Brazil NF instalado)"
echo -e "  Harmonia (N8N)    → https://${DOMINIO_N8N}"
echo -e "  Harpa (Chatwoot)  → https://${DOMINIO_CHAT}"
echo -e "  Eco (Uptime)      → https://${DOMINIO_UPTIME}"
echo -e "  Acorde (Netdata)  → https://${DOMINIO_NETDATA}"
if [ "$PAINEL_INSTALADO" = "sim" ]; then
  echo -e "  Painel            → https://${DOMINIO_PAINEL}"
else
  echo -e "  Painel            → ${RED}NÃO publicado nesta execução${NC} (ver pendência 4 abaixo)"
fi
if [ "$HOME_INSTALADO" = "sim" ]; then
  echo -e "  Home (raiz)       → https://${DOMINIO_BASE}"
else
  echo -e "  Home (raiz)       → ${RED}NÃO publicada nesta execução${NC} (ver pendência 4b abaixo)"
fi
echo -e "  Semaphore         → só via túnel SSH: ssh -L ${SEMAPHORE_PORT}:localhost:${SEMAPHORE_PORT} <usuario>@<ip-desta-vps>"
echo -e "  Credenciais       → ${CRED_FILE} (chmod 600) — TUDO num arquivo só"
echo ""
echo -e "${YELLOW}PRÓXIMOS PASSOS (fora do alcance de script):${NC}"
echo -e "  1. Confirme o teto de gastos no projeto GCP (Vertex AI/Gemini)."
echo -e "  2. Pra atualizar o código da Lyra Central depois, use o scripts/deploy.sh"
echo -e "     que já vem no repo (dentro de ${LYRA_APP_DIR}) — git pull + rollback automático."
echo -e "  3. NODE_ENV=development (SECRETS_PROVIDER=env) na Lyra Central — API Keys de"
echo -e "     tenant ficam em texto local. Não é produção real com cliente pagante ainda"
echo -e "     (gcp_secret_manager/vault são stubs no repo)."
if [ "$PAINEL_INSTALADO" = "sim" ]; then
  echo -e "  4. No Painel (https://${DOMINIO_PAINEL}), cadastrar Melhor Envio / InfinitePay / 99 Empresas."
else
  if [ -z "$PAINEL_HTML_ORIGEM" ]; then
    echo -e "  4. ${RED}Painel não publicado${NC} — nenhuma fonte de HTML disponível. Rode de novo com o HTML como 4º argumento, copie pra /root/synapse_painel.html, ou crie github.com/${GITHUB_ORG}/painel."
  else
    echo -e "  4. ${RED}Painel publicado mas NÃO validado${NC} — host/container/HTTPS não bateram (ver PANEL_DEPLOY_OK acima). Rode: cd /home/ubuntu/painel && docker compose up -d --force-recreate, e confira se https://${DOMINIO_PAINEL} responde antes de reexecutar."
  fi
fi
if [ "$HOME_INSTALADO" != "sim" ]; then
  echo -e "  4b. ${RED}Home não publicada${NC} — rode de novo com a pasta/arquivo como 5º argumento, ou copie pra /root/home-site (pasta) ou /root/index.html (arquivo)."
fi
echo -e "  5. Inbox de WhatsApp no Harpa: precisa de credenciais de um provedor."
echo -e "  6. Confirmar Plano de Contas BR no Ritmo, se o passo automático não achou o nome certo."
echo -e "  7. Criar a Status Page do Eco com slug 'synapse' (Basic Auth: ${BASICAUTH_USER})."
echo -e "  8. Confirmar os 8 registros DNS (raiz/lyra/ritmo/harmonia/harpa/acorde/eco/painel) apontando pro IP desta VPS — a raiz (apex) é nova, precisa existir pra Home funcionar."
echo -e "  9. Semaphore: projeto, Key Store, repo (github.com/nomen-me/synapse), Environment, Inventory e templates"
echo -e "     são configurados AUTOMATICAMENTE na seção 13B (log em /var/log/synapse_semaphore_config.log)."
echo -e "     Manual restante (declarado como [EXCEÇÃO] no relatório): a Integration n8n->Semaphore"
echo -e "     (Project > Integrations) — o bundle não automatiza porque o schema do payload não foi confirmado."
if [ -z "${LYRA_TENANT_API_KEY:-}" ]; then
  echo -e "  10. ${RED}Onboarding da Nomen como tenant falhou — rode o script de novo (é idempotente).${NC}"
fi
if [ "$PAINEL_INSTALADO" = "sim" ]; then
  echo -e "  11. O card de Consumo (VPS) do Painel chama o webhook 'monitoramento/metricas' no"
  echo -e "      Harmonia como proxy pro Acorde — esse workflow ainda não existe no repo de"
  echo -e "      workflows, precisa ser criado à parte (o Painel sobe normalmente sem ele; só"
  echo -e "      esse card específico fica sem dado até o workflow existir)."
fi
echo -e "${GREEN}============================================================${NC}"

}

main "$@"

#!/bin/bash
# =============================================================================
#  SYNAPSE — PROVISIONAMENTO DE CLIENTE NOVO (script único, ponta-a-ponta)
#  Funde em um só fluxo:
#    - install_synapse_v6.sh   (VPS do zero: Docker/Traefik/Ritmo/Harmonia/
#                                Harpa/Eco/Acorde)
#    - 1_provisionar_ritmo.sh  (CORS/CSRF/roles/DocTypes/usuário de automação)
#    - 3_provisionar_harpa.sh  (conta/admin/token/inbox webchat)
#    - 4_atualizar_credenciais_harmonia.sh (grava .env do Harmonia)
#    - onboard-client.sh       (tenant na Lyra Central + injeta LYRA_API_KEY)
#    - 2_importar_workflows_harmonia.py (sobe os workflows W0-W4 + Lyra L1-L3)
#  Roda direto, como root, na VPS nova do cliente.
#
#  Uso local (script já baixado):
#    export LYRA_CENTRAL_URL=https://lyra.suaempresa.com
#    export LYRA_ADMIN_API_KEY=xxxxx
#    export GITHUB_TOKEN=ghp_xxxxx   # PAT com acesso de leitura aos repos nomen-me (privados)
#    sudo -E ./provisionar_cliente_synapse.sh <dominio-base> ["Nome da Loja"] [pasta-workflows] [arquivo-html-do-painel] [pasta-ou-arquivo-da-home]
#
#  Exemplo:
#    sudo -E ./provisionar_cliente_synapse.sh lojademo.com.br "Loja Demo" "" /root/synapse_painel.html /root/home-site
#
#  Uso via "curl | bash" (script hospedado no repo, sem baixar antes):
#    ⚠️ "curl ... | bash <dominio>" NÃO funciona — depois do "|", o bash lê o
#    SCRIPT do stdin, então qualquer coisa escrita depois de "bash" é
#    interpretada como argumento do PRÓPRIO bash, não do script. É preciso
#    "-s --" pra sinalizar "o resto da linha são argumentos do script".
#    E se github.com/nomen-me/synapse for um repo PRIVADO (como os outros
#    repos nomen-me citados abaixo), o "curl" no raw.githubusercontent
#    TAMBÉM precisa de autenticação própria — GITHUB_TOKEN usado dentro do
#    script é só pro "git clone" de dentro dele, não autentica esse curl:
#      export LYRA_CENTRAL_URL=https://lyra.suaempresa.com
#      export LYRA_ADMIN_API_KEY=xxxxx
#      export GITHUB_TOKEN=ghp_xxxxx
#      curl -fsSL -H "Authorization: token ${GITHUB_TOKEN}" \
#        https://raw.githubusercontent.com/nomen-me/synapse/main/provisionar_cliente_synapse.sh \
#        | sudo -E bash -s -- lojademo.com.br "Loja Demo"
#    (se o repo for Public, dá pra tirar o "-H Authorization" desse curl)
#
#  O 3º argumento (pasta-workflows) agora é OPCIONAL: se não for passado, o
#  script clona github.com/nomen-me/json (W0-W4 + Lyra L1-L3 + schema de
#  funções) e usa esses arquivos. Só informe esse argumento se quiser
#  apontar pra uma pasta local (ex: testando workflows ainda não commitados).
#
#  De onde vem cada coisa (nada mais depende de FileZilla/scp manual):
#    - Módulo fiscal Brazil NF   → github.com/nomen-me/brazil-nf
#    - Workflows do Harmonia     → github.com/nomen-me/json (raiz do repo)
#    - Painel/PDV (mesmo produto pra todo cliente, PWA offline-first) → um
#      CONJUNTO de 7 arquivos (index.html, sw.js, manifest.json, fflate.js,
#      icon-192.png, icon-512.png, icon-512-maskable.png), nunca só o HTML.
#      Ordem de prioridade (ver seção 9.5):
#        1) 4º argumento do script — pasta com os 7 arquivos, ou (modo
#           antigo) 1 arquivo HTML único + os outros 6 do lado dele
#        2) /root/painel_dist/ na VPS — pasta com os 7 arquivos
#        3) /root/synapse_painel.html (modo antigo) + os outros 6 em /root
#        4) clone de github.com/nomen-me/painel, travado no commit/tag de
#           SYNAPSE_PAINEL_REF (precisa ser exportado — não há valor-padrão
#           chutado; ver comentário na declaração da variável)
#      Sem um conjunto completo de alguma dessas 4 fontes, a instalação
#      FALHA de propósito (Painel é requisito obrigatório do PDV).
#    - Home/site da raiz (próprio da loja, diferente pra cada cliente,
#      sem repo padrão) → 5º argumento local, /root/home-site (pasta) ou
#      /root/index.html (arquivo) — ver seção 9.6 (esta, sim, é opcional)
#
#  Pré-requisitos antes de rodar:
#    - VPS Ubuntu 24.04 limpa, root/sudo
#    - 7 registros DNS tipo A apontando pro IP desta VPS:
#        ritmo. harmonia. harpa. acorde. eco. painel. <dominio-base>
#        + o próprio <dominio-base> (raiz/apex, sem subdomínio — é onde a
#        Home é publicada, seção 9.6)
#    - LYRA_CENTRAL_URL, LYRA_ADMIN_API_KEY e GITHUB_TOKEN exportados no
#      ambiente, e uma das 4 fontes do Painel acima disponível (os 7
#      arquivos em /root/painel_dist/ é a forma mais simples)
#
#  O QUE O SCRIPT NÃO FAZ DE PROPÓSITO (fica pro painel de operações ou
#  manual, ver resumo final):
#    - Credenciais de Melhor Envio / InfinitePay / 99 Empresas → cadastradas
#      pelo painel, direto no Ritmo (DocType "Synapse Credencial Externa")
#    - Inbox de WhatsApp no Harpa → depende de conta própria (Meta/Twilio/
#      360dialog) que só o cliente/vocês criam
#    - GEMINI_API_KEY → não existe mais por cliente; a Lyra Central já
#      centraliza isso
# =============================================================================
set -uo pipefail
# (sem -e de propósito: uma falha num passo não-crítico não deve abortar o
#  resto da instalação — cada passo crítico tem sua própria checagem/fatal)

# Todo o corpo do script fica dentro de main(), chamada só na ÚLTIMA linha
# do arquivo. Isso é o que garante rodar de forma segura via "curl | bash":
# bash precisa ler a função INTEIRA (até o "}" de fechamento) antes de poder
# executar qualquer parte dela — então, quando algum comando aqui dentro
# (docker exec, docker compose exec/run, etc.) tentar ler stdin, não sobra
# mais nada do script no mesmo cano pra ele roubar (o "curl" já entregou
# tudo, o bash já terminou de PARSEAR o arquivo inteiro nesse ponto). Sem
# isso, "curl | bash" pode morrer silenciosamente no meio — cada comando
# interno que lê stdin disputa os mesmos bytes que o bash ainda não leu.
main() {

# =============================================================================
# 0. ARGUMENTOS, VARIÁVEIS DERIVADAS E HELPERS
# =============================================================================
DOMINIO_BASE="${1:?Uso: sudo -E bash provisionar_cliente_synapse.sh <dominio-base> [\"Nome da Loja\"] [pasta-workflows-local-opcional] [arquivo-html-do-painel-opcional] [pasta-ou-arquivo-da-home-opcional]}"
NOME_LOJA="${2:-$DOMINIO_BASE}"
WORKFLOWS_DIR_OVERRIDE="${3:-}"   # se vazio, workflows vêm do clone de nomen-me/synapse (fase 12)
PAINEL_HTML_OVERRIDE="${4:-}"
HOME_SRC_OVERRIDE="${5:-}"

LYRA_CENTRAL_URL="${LYRA_CENTRAL_URL:?Exporte LYRA_CENTRAL_URL antes de rodar (ex: export LYRA_CENTRAL_URL=https://lyra.suaempresa.com)}"
LYRA_ADMIN_API_KEY="${LYRA_ADMIN_API_KEY:?Exporte LYRA_ADMIN_API_KEY antes de rodar}"
LYRA_CENTRAL_URL="${LYRA_CENTRAL_URL%/}"
GITHUB_TOKEN="${GITHUB_TOKEN:?Exporte GITHUB_TOKEN antes de rodar (PAT com acesso de leitura aos repos privados nomen-me)}"
GITHUB_ORG="nomen-me"

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

# Painel: ao contrário do brazil-nf, este script NÃO tem como saber sozinho
# qual commit/tag de github.com/${GITHUB_ORG}/painel corresponde à versão
# validada (synapse_painel_18-09m.html + sw.js entregues junto desta tarefa)
# — isso só existe no repositório real, que este ambiente não acessa. Por
# isso, de propósito, NÃO HÁ um valor-padrão chutado aqui (seria exatamente
# o "HTML antigo sem controle de versão" que a seção 10 da instrução proíbe,
# só que disfarçado de commit). Se os passos (a)/(b)/(c) da seção 9.5 não
# acharem uma fonte local, o clone do repo oficial só é tentado quando
# SYNAPSE_PAINEL_REF for exportado com o commit/tag real e homologado.
SYNAPSE_PAINEL_REF="${SYNAPSE_PAINEL_REF:-}"

AUTO_REBOOT="${AUTO_REBOOT:-nao}"   # export AUTO_REBOOT=sim para pular a confirmação de reboot

DOMINIO_ERP="ritmo.${DOMINIO_BASE}"
DOMINIO_N8N="harmonia.${DOMINIO_BASE}"
DOMINIO_CHAT="harpa.${DOMINIO_BASE}"
DOMINIO_NETDATA="acorde.${DOMINIO_BASE}"
DOMINIO_UPTIME="eco.${DOMINIO_BASE}"
DOMINIO_PAINEL="painel.${DOMINIO_BASE}"
ORIGEM_PAINEL="https://${DOMINIO_PAINEL}"

EMAIL="admin@${DOMINIO_BASE}"
SENHA="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)"
SECRET_KEY="$(openssl rand -hex 64)"

# Basic Auth de infraestrutura para Eco (Uptime Kuma) e Acorde (Netdata) —
# essas duas ficam com Basic Auth em vez de 404, porque são ferramentas de
# operação que a própria equipe Synapse acessa, não algo pra esconder de
# quem já tem a senha certa.
BASICAUTH_USER="synapse-ops"
BASICAUTH_PASS="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)"
BASICAUTH_HASH="$(openssl passwd -apr1 "${BASICAUTH_PASS}")"
BASICAUTH_HASH_ESCAPED="$(echo "$BASICAUTH_HASH" | sed 's/\$/\$\$/g')"  # docker-compose exige $$ pra não tentar interpolar variável

# tenant_id derivado do domínio, no formato aceito pela Lyra Central (^[a-z0-9_-]{3,64}$)
TENANT_ID="${TENANT_ID:-$(echo "$DOMINIO_BASE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/_\+/_/g; s/^_//; s/_$//')}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()  { echo -e "${RED}[ERRO]${NC} $1"; }
fatal(){ echo -e "${RED}[FATAL]${NC} $1"; exit 1; }

# Baseline §2: a instalação só é reprodutível em cima do Ubuntu homologado.
# Falha explícita e imediata em qualquer outra versão — nada de seguir e
# descobrir problema de compatibilidade no meio do provisionamento.
UBUNTU_VERSAO_HOST="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-desconhecida}")"
if [ "$UBUNTU_VERSAO_HOST" != "$SYNAPSE_UBUNTU_MAJOR" ]; then
  fatal "Ubuntu incompatível (detectado: ${UBUNTU_VERSAO_HOST}). Synapse exige Ubuntu ${SYNAPSE_UBUNTU_MAJOR} LTS."
fi
ok "Ubuntu ${UBUNTU_VERSAO_HOST} confirmado"

CRED_FILE="/root/synapse_credentials.txt"
salvar_credencial() {
  # upsert de UMA chave no arquivo de credenciais — idempotente, reaproveitado
  # também para o .env do Harmonia (ver grava_env abaixo)
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

# Executa um snippet Python dentro do backend do ERPNext via "bench execute"
# (nunca "bench console" interativo — não funciona de forma confiável dentro
# de um script não-interativo). Uso:
#   RESULTADO=$(ritmo_exec <<PYEOF
#   def main():
#       import frappe
#       ...
#   PYEOF
#   )
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

# Clona um repo privado nomen-me via HTTPS usando GITHUB_TOKEN. Não é fatal
# por padrão — quem chama decide o que fazer se vier vazio/falhar (o site
# fiscal, por exemplo, segue sem o módulo em vez de abortar tudo).
clonar_repo_nomen() {
  local repo="$1" destino="$2"
  rm -rf "$destino"
  local saida
  if saida=$(git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${repo}.git" "$destino" 2>&1); then
    return 0
  else
    # redige o token antes de mostrar qualquer coisa (git às vezes ecoa a URL no erro)
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

if [ -n "$PAINEL_HTML_OVERRIDE" ] && [ ! -f "$PAINEL_HTML_OVERRIDE" ] && [ ! -d "$PAINEL_HTML_OVERRIDE" ]; then
  fatal "Pasta/arquivo do Painel informado como 4º argumento não existe: ${PAINEL_HTML_OVERRIDE}"
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
salvar_credencial "BASICAUTH_USER" "$BASICAUTH_USER"
salvar_credencial "BASICAUTH_PASS" "$BASICAUTH_PASS"
ok "Password gerada e guardada em ${CRED_FILE} (permissões 600)"

echo "======================================================"
echo " Synapse — provisionando cliente novo"
echo "   domínio base : ${DOMINIO_BASE}"
echo "   loja         : ${NOME_LOJA}"
echo "   tenant Lyra  : ${TENANT_ID}"
echo "======================================================"

# =============================================================================
# 2. SISTEMA BASE + CVE-2026-53359 (kernel) + FIREWALL + DOCKER
# =============================================================================
# Numa VPS recém-criada o unattended-upgrades pode segurar o lock do
# dpkg/apt por um bom tempo. Paramos a instância atual dele (não desativa
# permanentemente, só interrompe a execução em andamento — volta a rodar no
# próximo agendamento/boot) e, como rede de segurança extra, esperamos o
# lock liberar antes de qualquer apt/docker install.
parar_unattended_upgrades() {
  systemctl stop unattended-upgrades 2>/dev/null || true
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
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
parar_unattended_upgrades

log "Actualizando sistema..."
esperar_apt_livre
apt update && apt upgrade -y || fatal "Falha ao actualizar o sistema."
esperar_apt_livre
apt install -y curl git nano ufw jq python3 unzip || fatal "Falha ao instalar pacotes base."

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
ok "Firewall configurado"

if ! command -v docker >/dev/null 2>&1; then
  log "Instalando Docker..."
  esperar_apt_livre
  curl -fsSL https://get.docker.com | sh || fatal "Falha ao instalar Docker."
  systemctl enable --now docker
fi
ok "Docker disponível: $(docker --version)"

# =============================================================================
# 3. REDE UNIFICADA + TRAEFIK
# =============================================================================
log "Criando rede unificada stack-network..."
docker network create stack-network 2>/dev/null || true

log "Instalando Traefik standalone..."
mkdir -p /home/ubuntu/traefik
cat > /home/ubuntu/traefik/docker-compose.yml << EOF
services:
  traefik:
    image: traefik:${SYNAPSE_TRAEFIK_VERSION}
    container_name: traefik
    restart: always
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=stack-network"
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
      - traefik_certs:/letsencrypt
    networks:
      - stack-network
volumes:
  traefik_certs:
networks:
  stack-network:
    external: true
EOF
cd /home/ubuntu/traefik && docker compose up -d
ok "Traefik standalone activo"

# =============================================================================
# 3.5 BLACKHOLE 404 — backend genérico que só devolve 404
#    É vital que os clientes da Synapse jamais vejam as GUIs internas
#    (ERPNext/N8N/Chatwoot) nem saibam de que peças a stack é composta.
#    Este container serve de destino para os routers "*-deny" criados nas
#    fases seguintes: qualquer rota não-API/não-webhook cai aqui e recebe
#    404, enquanto as chamadas de API/webhook continuam passando direto
#    para o serviço real (routers "*-allow" com prioridade maior).
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

      # ---- Ritmo (ERPNext): tudo que não começa com /api cai aqui ----
      - "traefik.http.routers.ritmo-deny.rule=Host(\`${DOMINIO_ERP}\`)"
      - "traefik.http.routers.ritmo-deny.entrypoints=websecure"
      - "traefik.http.routers.ritmo-deny.tls.certresolver=myresolver"
      - "traefik.http.routers.ritmo-deny.priority=1"
      - "traefik.http.routers.ritmo-deny.service=blackhole404"

      # ---- Harmonia (N8N): editor/telas caem aqui; webhooks/API não ----
      - "traefik.http.routers.harmonia-deny.rule=Host(\`${DOMINIO_N8N}\`)"
      - "traefik.http.routers.harmonia-deny.entrypoints=websecure"
      - "traefik.http.routers.harmonia-deny.tls.certresolver=myresolver"
      - "traefik.http.routers.harmonia-deny.priority=1"
      - "traefik.http.routers.harmonia-deny.service=blackhole404"

      # ---- Harpa (Chatwoot): login/painel de atendimento caem aqui ----
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
ok "blackhole404 activo — GUIs de Ritmo/Harmonia/Harpa vão responder 404 a partir de agora (os routers *-allow, criados junto de cada serviço, têm prioridade maior e liberam só API/webhook)"

# =============================================================================
# 4. ERPNEXT 15 (RITMO)
# =============================================================================
log "Instalando ERPNext 15 (Ritmo)..."
cd /home/ubuntu
[ -d frappe_docker ] || git clone https://github.com/frappe/frappe_docker || fatal "Falha ao clonar frappe_docker."
cd frappe_docker

cat > .env << EOF
ERPNEXT_VERSION=${SYNAPSE_ERPNEXT_VERSION}
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
        ok "Brazil NF instalado e confirmado em 'bench list-apps' do site ${DOMINIO_ERP}"
        BRAZIL_NF_CONFIRMADO="sim"
      else
        err "bench install-app terminou sem erro, mas brazil_nf NÃO aparece em 'bench list-apps' do site ${DOMINIO_ERP} — instalação do módulo fiscal não confirmada."
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
# 8.5 USUÁRIO DE LOGIN DO PAINEL (mesmo EMAIL/SENHA de /root/synapse_credentials.txt)
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
  # FATAL, não aviso: sem este usuário, login nenhum funciona no Painel —
  # nem o login online inicial que sincroniza a lista de operadores
  # autorizados do Caixa, nem nada do PDV depende disso (seção 13/17 da
  # instrução obrigatória). Seguir "parcialmente instalado" aqui deixaria
  # o cliente com um PDV que não abre.
  fatal "Não consegui confirmar a criação do usuário ${EMAIL} no Ritmo — veja /tmp/synapse_admin_user.log. Sem isso, o login no Painel (e portanto o PDV) não funciona."
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
            # Item 6 (Fase 1) — mesa/comanda/senha. Não existe campo nativo
            # equivalente no ERPNext; opcional, só preenchido quando a venda
            # tem atendimento identificado. Contrato idêntico ao já usado no
            # instalador central (instalar_nomen_completo.sh) — mesmo nome,
            # mesmo fieldtype, mesma posição relativa.
            {"fieldname": "synapse_identificacao_atendimento", "label": "Synapse — Mesa/Comanda/Senha", "fieldtype": "Data", "insert_after": "synapse_operador_real"},
        ],
        "Sales Order": [
            # Pedido de Venda offline — mesmo par de campos do POS Invoice,
            # pelo mesmo motivo: idempotência (synapse_op_id, Sales Order
            # também autonomeia por naming_series) e identidade real de quem
            # criou o pedido, que pode ser diferente de quem sincroniza.
            {"fieldname": "synapse_op_id", "label": "Synapse — ID da operação (idempotência)", "fieldtype": "Data", "insert_after": "customer", "unique": 1, "read_only": 1},
            {"fieldname": "synapse_operador_real", "label": "Synapse — Operador real (Pedido offline)", "fieldtype": "Data", "insert_after": "synapse_op_id", "read_only": 1},
            {"fieldname": "synapse_identificacao_atendimento", "label": "Synapse — Mesa/Comanda/Senha", "fieldtype": "Data", "insert_after": "synapse_operador_real"},
        ],
        "POS Invoice Item": [
            # Item 2.3 (Fase 1) — item genérico: nunca cria um Item novo no
            # catálogo por venda (ver ITEM_GENERICO_CODE no cliente); estes
            # campos só marcam a linha como genérica e guardam quem autorizou.
            # Faltavam neste provisionador — confirmados existentes no
            # instalador central, nunca transportados pra cá até agora.
            {"fieldname": "synapse_item_generico", "label": "Synapse — Item genérico", "fieldtype": "Check", "insert_after": "rate"},
            {"fieldname": "synapse_preco_autorizado_por", "label": "Synapse — Preço autorizado por", "fieldtype": "Data", "insert_after": "synapse_item_generico", "read_only": 1},
            {"fieldname": "synapse_preco_motivo", "label": "Synapse — Motivo do preço autorizado", "fieldtype": "Data", "insert_after": "synapse_preco_autorizado_por", "read_only": 1},
        ],
        "Sales Order Item": [
            {"fieldname": "synapse_item_generico", "label": "Synapse — Item genérico", "fieldtype": "Check", "insert_after": "rate"},
            {"fieldname": "synapse_preco_autorizado_por", "label": "Synapse — Preço autorizado por", "fieldtype": "Data", "insert_after": "synapse_item_generico", "read_only": 1},
            {"fieldname": "synapse_preco_motivo", "label": "Synapse — Motivo do preço autorizado", "fieldtype": "Data", "insert_after": "synapse_preco_autorizado_por", "read_only": 1},
        ],
        "POS Profile": [
            # Item 4.2 (Fase 1) — acréscimos (frete/embalagem/taxa de serviço)
            # viram linhas reais em Sales Taxes and Charges, que exige uma
            # Account. Configurada uma vez aqui; sem isso, sincronizar uma
            # venda/pedido com acréscimo falha com mensagem clara (ver
            # pdvMapearAjustesDocParaRitmo no painel) em vez de adivinhar
            # uma conta contábil que pode não existir nesse plano de contas.
            {"fieldname": "synapse_conta_acrescimos", "label": "Synapse — Conta contábil para acréscimos", "fieldtype": "Link", "options": "Account", "insert_after": "selling_price_list"},
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
ok "Campos customizados (Company, Bank Account, Employee, POS Opening/Closing/Invoice, Sales Order, POS Invoice Item, Sales Order Item, POS Profile, Customer) garantidos"

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

# =============================================================================
# 8.4 ITEM GENÉRICO — item coringa usado pelo PDV pra vendas de itens
#    excepcionais não cadastrados no catálogo (ver ITEM_GENERICO_CODE no
#    painel). Contrato idêntico ao instalador central: um único Item
#    criado uma vez na instalação (infraestrutura), nunca um Item novo por
#    venda. Seção 6 da instrução obrigatória: isto é requisito do novo PDV,
#    não pode depender de criação manual depois — por isso, diferente do
#    instalador central (que só avisava e seguia), aqui a ausência de
#    Item Group/UOM é FATAL: sem este item, a operação "item genérico" do
#    PDV (seção 13 da instrução) fica inoperante em qualquer cliente novo.
# =============================================================================
RESULT_ITEM_GENERICO=$(ritmo_exec <<'PYEOF'
def main():
    import frappe
    if frappe.db.exists("Item", "ITEM-GENERICO"):
        print("SYNAPSE_KV|status|ja_existia")
        return
    grupo = "All Item Groups" if frappe.db.exists("Item Group", "All Item Groups") else frappe.db.get_value("Item Group", {}, "name")
    uom = frappe.db.get_value("UOM", {}, "name")
    if not grupo or not uom:
        print("SYNAPSE_KV|status|sem_dependencia")
        return
    frappe.get_doc({
        "doctype": "Item", "item_code": "ITEM-GENERICO", "item_name": "Item genérico (preço livre)",
        "item_group": grupo, "stock_uom": uom,
        "is_stock_item": 0,  # não é produto físico rastreável em estoque — só um veículo pra descrição/preço livres
        "description": "Item coringa usado pelo PDV para vendas de itens excepcionais não cadastrados no catálogo. Não vender fisicamente por este código — a descrição real vem da linha da venda.",
    }).insert(ignore_permissions=True)
    frappe.db.commit()
    print(f"SYNAPSE_KV|status|criado")
    print(f"SYNAPSE_KV|grupo|{grupo}")
    print(f"SYNAPSE_KV|uom|{uom}")
PYEOF
)
ITEM_GENERICO_STATUS=$(echo "$RESULT_ITEM_GENERICO" | grep '^SYNAPSE_KV|status|' | cut -d'|' -f3)
case "$ITEM_GENERICO_STATUS" in
  criado)
    ITEM_GENERICO_GRUPO=$(echo "$RESULT_ITEM_GENERICO" | grep '^SYNAPSE_KV|grupo|' | cut -d'|' -f3)
    ITEM_GENERICO_UOM=$(echo "$RESULT_ITEM_GENERICO" | grep '^SYNAPSE_KV|uom|' | cut -d'|' -f3)
    ok "Item 'ITEM-GENERICO' criado (grupo: ${ITEM_GENERICO_GRUPO} | uom: ${ITEM_GENERICO_UOM})"
    ;;
  ja_existia) ok "Item 'ITEM-GENERICO' já existia — mantido como está" ;;
  *) fatal "Não foi possível criar o Item 'ITEM-GENERICO' — nenhum Item Group nem UOM existe ainda neste site (${DOMINIO_ERP}). Isto não pode acontecer num ERPNext recém-instalado com app 'erpnext' presente (ele semeia Item Group/UOM padrão); confira 'bench --site ${DOMINIO_ERP} list-apps' antes de rodar de novo. Saída: ${RESULT_ITEM_GENERICO}. A operação 'item genérico' do PDV (seção 13) não funciona sem isto, por isso a instalação foi interrompida em vez de seguir parcialmente funcional." ;;
esac

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
  # FATAL, não aviso: Company é a raiz de praticamente todo doctype de
  # venda do ERPNext (POS Profile, Warehouse, Sales Order, POS Invoice...).
  # Sem ela, abertura de caixa e venda (seção 13) não têm onde existir —
  # não é um estado "parcialmente funcional", é "não funciona".
  *) fatal "Falha ao criar a Empresa '${NOME_LOJA}'. Saída: ${RESULT_COMPANY}" ;;
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
grava_env_n8n "CHATWOOT_WHATSAPP_INBOX_ID" "1"

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
warn "Inbox de WhatsApp e de E-mail NÃO são criados aqui de propósito (dependem de credenciais de terceiros). WhatsApp: 1 chamada em POST /api/v1/accounts/{id}/inboxes assim que tiver o provider_config."

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

cd /home/ubuntu/n8n && docker compose up -d
ok ".env do Harmonia atualizado e N8N reiniciado"

# =============================================================================
# 9.5 PAINEL — deploy do frontend estático (painel.${DOMINIO_BASE})
#    É o mesmo produto (Painel de operações + PDV) pra todo cliente, sem
#    build: em runtime, ele resolve os domínios de Ritmo/Harmonia/Harpa/Eco
#    a partir do próprio hostname (ver resolverAmbienteSynapse() dentro do
#    arquivo) — nenhum valor precisa ser injetado no HTML por este script
#    (SYNAPSE_CONFIG não tem mais placeholder nenhum pra preencher; o antigo
#    "empresa: null"/"chatwootContaId: null" não existe na versão atual do
#    Painel — nomeEmpresa é resolvido em runtime, lendo o Ritmo).
#
#    O que precisa ser publicado NÃO é mais um arquivo único: desde a
#    implementação offline-first, o Painel é um conjunto coerente de 7
#    arquivos (seção 11/12 da instrução obrigatória — publicar só o HTML e
#    deixar um sw.js antigo preso no servidor é FAIL):
#      index.html  sw.js  manifest.json  fflate.js
#      icon-192.png  icon-512.png  icon-512-maskable.png
#    Todos lidos pelo navegador por caminho relativo (ver <script
#    src="fflate.js">, <link rel="manifest" href="manifest.json">,
#    navigator.serviceWorker.register('sw.js') dentro do próprio Painel) —
#    por isso os 7 têm que ficar juntos, no mesmo diretório servido.
#
#    Fonte, em ordem de prioridade (a função resolver_painel_de() abaixo
#    procura os 7 nomes dentro da pasta informada, até 1 nível abaixo):
#      (a) 4º argumento do script (PAINEL_HTML_OVERRIDE): se for uma PASTA,
#          ela já deve conter os 7 arquivos; se for um ARQUIVO único
#          (compatibilidade com o uso antigo), ele vira o index.html e os
#          outros 6 são procurados do lado dele, na mesma pasta.
#      (b) /root/painel_dist/ na própria VPS — convenção nova, pasta única
#          com os 7 arquivos (mesmo padrão já usado por /root/home-site/
#          na seção 9.6 — não é mecanismo novo, é o mesmo composto aqui).
#      (c) /root/synapse_painel.html (compatibilidade com o uso antigo) +
#          os outros 6 arquivos soltos direto em /root/.
#      (d) github.com/nomen-me/painel, num commit/tag FIXO — nunca o HEAD
#          do momento, que é exatamente o "sem controle de versão" que a
#          seção 10 da instrução proíbe. Só é tentado se SYNAPSE_PAINEL_REF
#          estiver exportado (ver comentário na declaração da variável, no
#          topo do script, sobre por que não há um valor-padrão aqui).
#    Diferente da versão anterior deste script, a ausência de uma fonte
#    completa (os 7 arquivos) é FATAL — seção 13/17/22 da instrução: o
#    Painel/Service Worker são requisitos do PDV, não podem virar uma
#    pendência "best effort" no resumo final.
# =============================================================================
# Procura, dentro da pasta $1 (até 1 nível abaixo), cada um dos 7 arquivos
# do Painel. Preenche PAINEL_SRC_<NOME> com o caminho encontrado (vazio se
# não achou) e PAINEL_FALTANDO com a lista dos que faltaram. Devolve 0 só
# se os 7 foram encontrados.
resolver_painel_de() {
  local pasta="$1"
  PAINEL_SRC_INDEX="$(find "$pasta" -maxdepth 2 -iname 'index.html' 2>/dev/null | head -1)"
  PAINEL_SRC_SW="$(find "$pasta" -maxdepth 2 -iname 'sw.js' 2>/dev/null | head -1)"
  PAINEL_SRC_MANIFEST="$(find "$pasta" -maxdepth 2 -iname 'manifest.json' 2>/dev/null | head -1)"
  PAINEL_SRC_FFLATE="$(find "$pasta" -maxdepth 2 -iname 'fflate.js' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON192="$(find "$pasta" -maxdepth 2 -iname 'icon-192.png' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON512="$(find "$pasta" -maxdepth 2 -iname 'icon-512.png' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON512M="$(find "$pasta" -maxdepth 2 -iname 'icon-512-maskable.png' 2>/dev/null | head -1)"
  PAINEL_FALTANDO=""
  [ -z "$PAINEL_SRC_INDEX" ]    && PAINEL_FALTANDO="${PAINEL_FALTANDO}index.html "
  [ -z "$PAINEL_SRC_SW" ]       && PAINEL_FALTANDO="${PAINEL_FALTANDO}sw.js "
  [ -z "$PAINEL_SRC_MANIFEST" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}manifest.json "
  [ -z "$PAINEL_SRC_FFLATE" ]   && PAINEL_FALTANDO="${PAINEL_FALTANDO}fflate.js "
  [ -z "$PAINEL_SRC_ICON192" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-192.png "
  [ -z "$PAINEL_SRC_ICON512" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512.png "
  [ -z "$PAINEL_SRC_ICON512M" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512-maskable.png "
  [ -z "$PAINEL_FALTANDO" ]
}

log "Instalando o Painel (frontend estático + PWA em https://${DOMINIO_PAINEL})..."
mkdir -p /home/ubuntu/painel/site
PAINEL_FONTE_USADA=""
PAINEL_TENTATIVAS_LOG=""

if [ -n "$PAINEL_HTML_OVERRIDE" ]; then
  if [ -d "$PAINEL_HTML_OVERRIDE" ]; then
    if resolver_painel_de "$PAINEL_HTML_OVERRIDE"; then
      PAINEL_FONTE_USADA="pasta informada no 4º argumento (${PAINEL_HTML_OVERRIDE})"
    else
      PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- 4º argumento (pasta ${PAINEL_HTML_OVERRIDE}): faltou ${PAINEL_FALTANDO}\n"
    fi
  else
    # Compatibilidade com o uso antigo (1 arquivo só): ele é o index.html;
    # os outros 6 são procurados do lado dele, na mesma pasta (maxdepth 1 —
    # não desce em subpastas de quem passou um arquivo solto).
    PAINEL_SRC_INDEX="$PAINEL_HTML_OVERRIDE"
    local_dir_override="$(dirname "$PAINEL_HTML_OVERRIDE")"
    PAINEL_SRC_SW="$(find "$local_dir_override" -maxdepth 1 -iname 'sw.js' 2>/dev/null | head -1)"
    PAINEL_SRC_MANIFEST="$(find "$local_dir_override" -maxdepth 1 -iname 'manifest.json' 2>/dev/null | head -1)"
    PAINEL_SRC_FFLATE="$(find "$local_dir_override" -maxdepth 1 -iname 'fflate.js' 2>/dev/null | head -1)"
    PAINEL_SRC_ICON192="$(find "$local_dir_override" -maxdepth 1 -iname 'icon-192.png' 2>/dev/null | head -1)"
    PAINEL_SRC_ICON512="$(find "$local_dir_override" -maxdepth 1 -iname 'icon-512.png' 2>/dev/null | head -1)"
    PAINEL_SRC_ICON512M="$(find "$local_dir_override" -maxdepth 1 -iname 'icon-512-maskable.png' 2>/dev/null | head -1)"
    PAINEL_FALTANDO=""
    [ -z "$PAINEL_SRC_SW" ]       && PAINEL_FALTANDO="${PAINEL_FALTANDO}sw.js "
    [ -z "$PAINEL_SRC_MANIFEST" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}manifest.json "
    [ -z "$PAINEL_SRC_FFLATE" ]   && PAINEL_FALTANDO="${PAINEL_FALTANDO}fflate.js "
    [ -z "$PAINEL_SRC_ICON192" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-192.png "
    [ -z "$PAINEL_SRC_ICON512" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512.png "
    [ -z "$PAINEL_SRC_ICON512M" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512-maskable.png "
    if [ -z "$PAINEL_FALTANDO" ]; then
      PAINEL_FONTE_USADA="arquivo informado no 4º argumento (${PAINEL_HTML_OVERRIDE}) + 6 arquivos irmãos em ${local_dir_override}"
    else
      PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- 4º argumento (arquivo ${PAINEL_HTML_OVERRIDE}, irmãos em ${local_dir_override}): faltou ${PAINEL_FALTANDO}\n"
    fi
  fi
fi

if [ -z "$PAINEL_FONTE_USADA" ] && [ -d /root/painel_dist ]; then
  if resolver_painel_de /root/painel_dist; then
    PAINEL_FONTE_USADA="/root/painel_dist/ (default, sem precisar passar argumento)"
  else
    PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- /root/painel_dist/: faltou ${PAINEL_FALTANDO}\n"
  fi
fi

if [ -z "$PAINEL_FONTE_USADA" ] && [ -f /root/synapse_painel.html ]; then
  PAINEL_SRC_INDEX="/root/synapse_painel.html"
  PAINEL_SRC_SW="$(find /root -maxdepth 1 -iname 'sw.js' 2>/dev/null | head -1)"
  PAINEL_SRC_MANIFEST="$(find /root -maxdepth 1 -iname 'manifest.json' 2>/dev/null | head -1)"
  PAINEL_SRC_FFLATE="$(find /root -maxdepth 1 -iname 'fflate.js' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON192="$(find /root -maxdepth 1 -iname 'icon-192.png' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON512="$(find /root -maxdepth 1 -iname 'icon-512.png' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON512M="$(find /root -maxdepth 1 -iname 'icon-512-maskable.png' 2>/dev/null | head -1)"
  PAINEL_FALTANDO=""
  [ -z "$PAINEL_SRC_SW" ]       && PAINEL_FALTANDO="${PAINEL_FALTANDO}sw.js "
  [ -z "$PAINEL_SRC_MANIFEST" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}manifest.json "
  [ -z "$PAINEL_SRC_FFLATE" ]   && PAINEL_FALTANDO="${PAINEL_FALTANDO}fflate.js "
  [ -z "$PAINEL_SRC_ICON192" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-192.png "
  [ -z "$PAINEL_SRC_ICON512" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512.png "
  [ -z "$PAINEL_SRC_ICON512M" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512-maskable.png "
  if [ -z "$PAINEL_FALTANDO" ]; then
    PAINEL_FONTE_USADA="/root/synapse_painel.html (default antigo) + 6 arquivos irmãos em /root"
  else
    PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- /root/synapse_painel.html + irmãos em /root: faltou ${PAINEL_FALTANDO}\n"
  fi
fi

if [ -z "$PAINEL_FONTE_USADA" ]; then
  if [ -z "$SYNAPSE_PAINEL_REF" ]; then
    PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- github.com/${GITHUB_ORG}/painel: não tentado (SYNAPSE_PAINEL_REF não foi exportado — ver comentário na declaração da variável)\n"
  elif clonar_repo_nomen_pinned "painel" "/home/ubuntu/painel_src" "${SYNAPSE_PAINEL_REF}"; then
    if resolver_painel_de /home/ubuntu/painel_src; then
      PAINEL_FONTE_USADA="github.com/${GITHUB_ORG}/painel @ ${SYNAPSE_PAINEL_REF}"
    else
      PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- github.com/${GITHUB_ORG}/painel @ ${SYNAPSE_PAINEL_REF}: faltou ${PAINEL_FALTANDO}\n"
    fi
  else
    PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- github.com/${GITHUB_ORG}/painel @ ${SYNAPSE_PAINEL_REF}: não consegui clonar/checkout (repo ou ref podem não existir, ou GITHUB_TOKEN sem acesso)\n"
  fi
fi

if [ -z "$PAINEL_FONTE_USADA" ]; then
  fatal "Painel não publicado — nenhuma das fontes possíveis tinha os 7 arquivos completos (index.html, sw.js, manifest.json, fflate.js, icon-192.png, icon-512.png, icon-512-maskable.png). Tentativas:\n$(echo -e "$PAINEL_TENTATIVAS_LOG")Forneça a pasta completa como 4º argumento, copie-a para /root/painel_dist/, ou exporte SYNAPSE_PAINEL_REF com o commit/tag homologado de github.com/${GITHUB_ORG}/painel. O Painel/PDV é requisito obrigatório (seção 13 da instrução) — a instalação não pode seguir sem ele."
fi

ok "Fonte do Painel: ${PAINEL_FONTE_USADA}"
cp "$PAINEL_SRC_INDEX"    /home/ubuntu/painel/site/index.html
cp "$PAINEL_SRC_SW"       /home/ubuntu/painel/site/sw.js
cp "$PAINEL_SRC_MANIFEST" /home/ubuntu/painel/site/manifest.json
cp "$PAINEL_SRC_FFLATE"   /home/ubuntu/painel/site/fflate.js
cp "$PAINEL_SRC_ICON192"  /home/ubuntu/painel/site/icon-192.png
cp "$PAINEL_SRC_ICON512"  /home/ubuntu/painel/site/icon-512.png
cp "$PAINEL_SRC_ICON512M" /home/ubuntu/painel/site/icon-512-maskable.png

# Mount de PASTA, não de arquivo único: um bind mount de arquivo único
# resolve o inode no momento do "docker compose up" e nunca mais acompanha
# uma troca de arquivo no host sem recriar o container (é exatamente o bug
# de cache/build-antiga já corrigido no instalador central e no
# corrigir_painel.sh — reproduzir aqui a mesma causa seria reintroduzir o
# mesmo defeito num lugar novo).
cat > /home/ubuntu/painel/docker-compose.yml << EOF
services:
  painel:
    image: nginx:${SYNAPSE_NGINX_VERSION}
    container_name: painel
    restart: always
    volumes:
      - ./site:/usr/share/nginx/html:ro
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
# --force-recreate: numa reexecução o compose não mudou (mesma imagem, mesmo
# mount), e sem isso o container antigo seguiria no ar — o mount de pasta
# evita o bug do inode, mas só troca o que o container ENXERGA se ele for
# recriado pelo menos uma vez depois do novo conteúdo estar no host.
cd /home/ubuntu/painel && docker compose up -d --force-recreate

# Verificação contra a realidade, não contra a intenção: não basta o
# container ter sido recriado nem o HTTPS responder 200 — HTTP 200 só prova
# que ALGUMA coisa respondeu, não que é o conteúdo certo. Publicar só o
# index.html novo e deixar um sw.js antigo preso no ar é exatamente o tipo
# de falha que essa checagem existe pra pegar (o sw.js é o mais perigoso dos
# 7: é ele quem decide se o navegador vai servir o PWA do cache ou buscar a
# versão nova). Confere os 7, não só o index.html.
#
# HTTPS logo após um docker compose up pode falhar por timing de emissão de
# certificado (Traefik/ACME), não por bug de publicação — por isso tenta
# algumas vezes com espera antes de declarar falha de verdade.
PAINEL_ARQUIVOS=(index.html sw.js manifest.json fflate.js icon-192.png icon-512.png icon-512-maskable.png)
PAINEL_VALIDADO="sim"
PAINEL_DEPLOY_LOG=""
for arq in "${PAINEL_ARQUIVOS[@]}"; do
  h_host="$(sha256sum "/home/ubuntu/painel/site/${arq}" 2>/dev/null | awk '{print $1}')"
  h_cont=""
  h_https=""
  for tentativa in 1 2 3 4 5; do
    h_cont="$(docker exec painel sha256sum "/usr/share/nginx/html/${arq}" 2>/dev/null | awk '{print $1}')"
    h_https="$(curl -fsSL --max-time 5 "https://${DOMINIO_PAINEL}/${arq}" 2>/dev/null | sha256sum | awk '{print $1}')"
    [ -n "$h_host" ] && [ "$h_host" = "$h_cont" ] && [ "$h_host" = "$h_https" ] && break
    sleep 3
  done
  PAINEL_DEPLOY_LOG="${PAINEL_DEPLOY_LOG}${arq}: host=${h_host:-vazio} container=${h_cont:-vazio} https=${h_https:-vazio}\n"
  if [ -z "$h_host" ] || [ "$h_host" != "$h_cont" ] || [ "$h_host" != "$h_https" ]; then
    PAINEL_VALIDADO="nao"
  fi
done
log "PANEL_DEPLOY_OK candidato (7 arquivos, até 5 tentativas/15s cada por causa de emissão de certificado):\n$(echo -e "$PAINEL_DEPLOY_LOG")"
if [ "$PAINEL_VALIDADO" = "sim" ]; then
  ok "Painel publicado e validado em https://${DOMINIO_PAINEL} — os 7 arquivos batem byte a byte entre host, container e HTTPS (fonte: ${PAINEL_FONTE_USADA})"
else
  err "Painel publicado, mas a validação host=container=HTTPS FALHOU em pelo menos 1 dos 7 arquivos — ver PANEL_DEPLOY_OK acima. NÃO declarando o Painel como corretamente instalado. Rode: cd /home/ubuntu/painel && docker compose up -d --force-recreate, espere o certificado, e reexecute só esta seção."
fi

# =============================================================================
# 9.6 HOME — deploy do frontend estático da raiz (https://${DOMINIO_BASE})
#    Diferente do Painel, a Home É a própria loja/site do cliente — sem repo
#    padrão (cada cliente tem a sua). Também pode ser mais que um arquivo
#    (index.html + páginas irmãs + subpasta assets/), então este passo serve
#    uma PASTA inteira via nginx, não só um arquivo único. Fonte, em ordem
#    de prioridade:
#      (a) pasta ou arquivo local passado como 5º argumento do script
#          (HOME_SRC_OVERRIDE) — se for pasta, copia tudo que tiver dentro;
#          se for um arquivo único, vira só o index.html (páginas irmãs
#          eventuais vão dar 404 até serem colocadas na pasta manualmente)
#      (b) /root/home-site na própria VPS (pasta — default, sem argumento)
#      (c) /root/index.html na própria VPS (arquivo único — default)
#    Se nenhuma existir, o passo é pulado (não-fatal, mesmo padrão do
#    Painel).
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
# 11. ONBOARDING NA LYRA CENTRAL
#    (fusão do antigo onboard-client.sh — chama /admin/tenants e já injeta
#    LYRA_API_KEY no .env do Harmonia, fechando o ciclo sozinho)
# =============================================================================
log "Provisionando tenant '${TENANT_ID}' na Lyra Central (${LYRA_CENTRAL_URL})..."
HTTP_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "${LYRA_CENTRAL_URL}/admin/tenants" \
  -H "Authorization: Bearer ${LYRA_ADMIN_API_KEY}" -H "Content-Type: application/json" \
  -d "{\"tenant_id\": \"${TENANT_ID}\"}")
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)

if [ "$HTTP_STATUS" = "409" ]; then
  warn "Tenant '${TENANT_ID}' já existia na Lyra Central — girando (rotate) a chave para reaproveitar neste provisionamento."
  HTTP_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "${LYRA_CENTRAL_URL}/admin/tenants/${TENANT_ID}/rotate" \
    -H "Authorization: Bearer ${LYRA_ADMIN_API_KEY}")
  HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
  HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)
fi

LYRA_API_KEY=""
if [ "$HTTP_STATUS" = "201" ] || [ "$HTTP_STATUS" = "200" ]; then
  LYRA_API_KEY=$(echo "$HTTP_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null)
fi

if [ -n "$LYRA_API_KEY" ]; then
  salvar_credencial "LYRA_CENTRAL_URL" "$LYRA_CENTRAL_URL"
  salvar_credencial "LYRA_TENANT_ID" "$TENANT_ID"
  salvar_credencial "LYRA_API_KEY" "$LYRA_API_KEY"
  grava_env_n8n "LYRA_CENTRAL_URL" "$LYRA_CENTRAL_URL"
  grava_env_n8n "LYRA_TENANT_ID" "$TENANT_ID"
  grava_env_n8n "LYRA_API_KEY" "$LYRA_API_KEY"
  cd /home/ubuntu/n8n && docker compose up -d
  ok "Tenant Lyra provisionado e injetado no .env do Harmonia (ciclo fechado sozinho)"
else
  err "Falha ao provisionar/rotacionar tenant na Lyra Central (HTTP ${HTTP_STATUS}): ${HTTP_BODY}. Corrija e rode de novo — o script é idempotente."
fi

# =============================================================================
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
    ok "Workflows encontrados em ${WORKFLOWS_DIR} (o lyra_functions.json de lá é ignorado na importação — não é workflow, é o schema de tools consumido pela Lyra Central, não pelo Harmonia)"
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
  COOKIEJAR="/tmp/synapse_n8n_cookie_$$"

  HTTP_SETUP=$(curl -s -o /tmp/synapse_n8n_setup.json -w '%{http_code}' -c "$COOKIEJAR" \
    -X POST "${N8N_BASE}/rest/owner/setup" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${N8N_AUTOMACAO_EMAIL}\",\"firstName\":\"Synapse\",\"lastName\":\"Automacao\",\"password\":\"${SENHA}\"}")

  if [ "$HTTP_SETUP" != "200" ]; then
    curl -s -o /dev/null -w '%{http_code}' -c "$COOKIEJAR" \
      -X POST "${N8N_BASE}/rest/login" -H 'Content-Type: application/json' \
      -d "{\"email\":\"${N8N_AUTOMACAO_EMAIL}\",\"password\":\"${SENHA}\"}" > /tmp/synapse_n8n_login_code || true
  fi

  N8N_KEY_BODY=$(curl -s -b "$COOKIEJAR" -X POST "${N8N_BASE}/rest/api-keys" \
    -H 'Content-Type: application/json' -d '{"label":"synapse-provisionamento"}' || true)
  rm -f "$COOKIEJAR"

  N8N_API_KEY=$(echo "$N8N_KEY_BODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for k in ('rawApiKey', 'apiKey', 'key'):
        v = d.get(k) or (d.get('data') or {}).get(k)
        if v:
            print(v); break
except Exception:
    pass
" 2>/dev/null)

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
    if resultado and wf_id:
        chamar("POST", f"/api/v1/workflows/{wf_id}/activate")
        print(f"   {acao} e ativado: {nome}")
    else:
        print(f"   FALHOU: {nome} — revise o erro acima")
print("Pronto. Confira no editor do n8n se os webhooks path batem com o que os outros serviços chamam.")
PYEOF
  else
    warn "Não consegui gerar a API key pública do N8N automaticamente (endpoint interno pode ter mudado). Importação de workflows pulada. A UI do Harmonia não responde mais publicamente (GUI escondida de propósito) e a porta 5678 não é publicada no host — pra gerar a chave manualmente: (1) adicione 'ports: [\"127.0.0.1:5678:5678\"]' ao serviço n8n em /home/ubuntu/n8n/docker-compose.yml, (2) 'docker compose up -d', (3) na sua máquina: 'ssh -L 5678:localhost:5678 <usuario>@<ip-da-vps>' e abra http://localhost:5678 (Configurações > API), (4) remova a linha 'ports:' e rode 'docker compose up -d' de novo pra fechar o acesso. Depois: N8N_URL=https://${DOMINIO_N8N} N8N_API_KEY=<chave> python3 2_importar_workflows_harmonia.py ${WORKFLOWS_DIR}"
  fi
fi

# =============================================================================
# 13. VALIDAÇÃO FINAL
# =============================================================================
log "Validando serviços instalados..."
sleep 10
# nota: N8N/Chatwoot já não respondem 200 na raiz de propósito (GUI escondida
# atrás do blackhole404) — cada checagem abaixo aponta pra uma rota que
# continua liberada. Eco/Acorde ficam atrás de Basic Auth, então a checagem
# usa a credencial gerada nesta mesma execução.
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
check_service "ERPNext (Ritmo) — API"        "https://${DOMINIO_ERP}/api/method/ping"
check_service "N8N (Harmonia) — healthz"     "https://${DOMINIO_N8N}/healthz"
check_service "Chatwoot (Harpa) — widget"    "https://${DOMINIO_CHAT}/packs/js/sdk.js"
check_service "Uptime (Eco) — Basic Auth"    "https://${DOMINIO_UPTIME}" "${BASICAUTH_USER}:${BASICAUTH_PASS}"
CODE_STATUS_PUBLICA=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://${DOMINIO_UPTIME}/api/status-page/synapse" 2>/dev/null)
if [ "$CODE_STATUS_PUBLICA" = "401" ]; then
  err "Status page pública do Eco está pedindo Basic Auth (HTTP 401) — a exceção de Traefik não pegou. Revise o router 'eco-status-publico'."
else
  ok "Status page pública do Eco não exige Basic Auth (HTTP ${CODE_STATUS_PUBLICA} — 404 aqui é normal até a status page 'synapse' ser criada manualmente, passo 4 do resumo final)"
fi
check_service "Netdata (Acorde) — Basic Auth" "https://${DOMINIO_NETDATA}" "${BASICAUTH_USER}:${BASICAUTH_PASS}"
check_service "Lyra Central"                 "${LYRA_CENTRAL_URL}/healthz"
# Painel não entra condicionado a uma variável "instalado sim/não" — a
# seção 9.5 já aborta a instalação com fatal() se o conjunto completo não
# tiver sido publicado, então, se chegamos até aqui, ele está publicado.
check_service "Painel"                       "https://${DOMINIO_PAINEL}"
if [ "$PAINEL_VALIDADO" != "sim" ]; then
  err "Painel respondeu HTTP, mas a validação host=container=HTTPS da publicação (seção 9.5) tinha falhado — HTTP 200 aqui não significa que é a versão certa. Ver PANEL_DEPLOY_OK mais acima."
fi
if [ "$HOME_INSTALADO" = "sim" ]; then
  check_service "Home (raiz)"                "https://${DOMINIO_BASE}"
fi

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
# 13.5 VALIDAÇÃO DO CONTRATO PDV (seção 19 da instrução obrigatória)
#    "O script deve verificar explicitamente, antes de declarar sucesso,
#    que as estruturas críticas existem." Tudo abaixo já devia ter sido
#    criado pelas seções 8/9 acima — isto não tenta corrigir nada, só
#    confirma, e FALHA a instalação se alguma coisa não bateu (nunca
#    declara sucesso com uma estrutura crítica faltando).
# =============================================================================
log "Confirmando que o Ritmo tem todas as estruturas que o novo PDV exige..."
RESULT_VALIDACAO_PDV=$(ritmo_exec <<'PYEOF'
def main():
    import frappe
    faltando = []

    campos_esperados = {
        "Employee": ["synapse_pin_hash", "synapse_pin_salt", "synapse_pin_kdf_iteracoes", "synapse_pin_definido_em"],
        "POS Opening Entry": ["synapse_op_id"],
        "POS Closing Entry": ["synapse_op_id"],
        "POS Invoice": ["synapse_op_id", "synapse_operador_real", "synapse_identificacao_atendimento"],
        "Sales Order": ["synapse_op_id", "synapse_operador_real", "synapse_identificacao_atendimento"],
        "POS Invoice Item": ["synapse_item_generico", "synapse_preco_autorizado_por", "synapse_preco_motivo"],
        "Sales Order Item": ["synapse_item_generico", "synapse_preco_autorizado_por", "synapse_preco_motivo"],
        "POS Profile": ["synapse_conta_acrescimos"],
        "Customer": ["synapse_pedido_op_id"],
    }
    for doctype, campos in campos_esperados.items():
        for campo in campos:
            if not frappe.db.exists("Custom Field", f"{doctype}-{campo}"):
                faltando.append(f"Custom Field {doctype}.{campo}")

    for script in ["synapse_sincronizar_caixa", "synapse_definir_pin", "synapse_csrf_token"]:
        if not frappe.db.exists("Server Script", script):
            faltando.append(f"Server Script {script}")

    if not frappe.db.exists("Item", "ITEM-GENERICO"):
        faltando.append("Item ITEM-GENERICO")

    for wt in ["Loja", "Deposito"]:
        if not frappe.db.exists("Warehouse Type", wt):
            faltando.append(f"Warehouse Type {wt}")

    if faltando:
        for item in faltando:
            print(f"SYNAPSE_KV|faltando|{item}")
    else:
        print("SYNAPSE_KV|status|completo")
PYEOF
)
FALTANDO_PDV=$(echo "$RESULT_VALIDACAO_PDV" | grep '^SYNAPSE_KV|faltando|' | cut -d'|' -f3)
if [ -n "$FALTANDO_PDV" ]; then
  fatal "Validação final do contrato PDV (seção 19 da instrução obrigatória) encontrou estruturas faltando no Ritmo, mesmo depois dos passos de provisionamento acima:\n$(echo "$FALTANDO_PDV" | sed 's/^/  - /')\nA instalação NÃO pode ser declarada concluída com isso faltando — revise os logs das seções 8/9 acima e rode o script de novo (é idempotente)."
else
  ok "Contrato PDV confirmado no Ritmo: todos os campos de operador/PIN, POS Opening/Closing/Invoice, Sales Order, item genérico, POS Profile, endpoints do Caixa Offline e estruturas de apoio existem"
fi

log "Confirmando que os endpoints do Caixa Offline respondem como 'existem' (não como 'método inexistente')..."
# allow_guest=0 nos dois: uma chamada sem sessão tem que ser recusada por
# PERMISSÃO (prova que o Server Script existe e está registrado), nunca
# por "método não encontrado" (que provaria o contrário). Mesmo critério
# já usado no testar_endpoint_caixa_b.sh (item 9) — não é um mecanismo
# novo, é o mesmo teste aplicado aqui dentro do provisionador.
verificar_endpoint_caixa_existe() {
  local nome="$1"
  local corpo
  corpo=$(curl -s --max-time 10 "https://${DOMINIO_ERP}/api/method/${nome}" 2>/dev/null)
  if echo "$corpo" | grep -qiE "permission|not permitted|login|authentication|csrf"; then
    ok "/api/method/${nome} existe e está protegido (recusou chamada sem sessão, como esperado)"
  elif echo "$corpo" | grep -qiE "not found|não encontrado|does not exist|method not found|app methods"; then
    fatal "/api/method/${nome} respondeu como se NÃO existisse: ${corpo}"
  else
    fatal "/api/method/${nome} devolveu uma resposta que não bate com 'existe e está protegido' nem com 'não existe' — confirme manualmente antes de liberar o cliente: ${corpo}"
  fi
}
verificar_endpoint_caixa_existe "synapse_sincronizar_caixa"
verificar_endpoint_caixa_existe "synapse_definir_pin"

log "Confirmando que o Painel está servindo o conjunto novo (index.html + sw.js + manifest.json)..."
verificar_arquivo_painel_servido() {
  local nome="$1"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://${DOMINIO_PAINEL}/${nome}" 2>/dev/null)
  if [ "$code" = "200" ]; then
    ok "https://${DOMINIO_PAINEL}/${nome} respondeu HTTP 200"
  else
    fatal "https://${DOMINIO_PAINEL}/${nome} não respondeu HTTP 200 (HTTP ${code}) — o Painel/PDV não funciona sem este arquivo (seção 11/19 da instrução)."
  fi
}
verificar_arquivo_painel_servido "index.html"
verificar_arquivo_painel_servido "sw.js"
verificar_arquivo_painel_servido "manifest.json"

# =============================================================================
# 14. REINÍCIO (SE NECESSÁRIO PARA O PATCH DE KERNEL)
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
      warn "Reinício adiado — os containers têm restart:always e voltam sozinhos quando você reiniciar manualmente (sudo reboot)."
    fi
  fi
fi

# =============================================================================
# RESUMO FINAL
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   SYNAPSE — PROVISIONAMENTO CONCLUÍDO: ${DOMINIO_BASE}${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Ritmo (ERPNext)   → https://${DOMINIO_ERP}"
echo -e "  Harmonia (N8N)    → https://${DOMINIO_N8N}"
echo -e "  Harpa (Chatwoot)  → https://${DOMINIO_CHAT}"
echo -e "  Eco (Uptime)      → https://${DOMINIO_UPTIME}"
echo -e "  Acorde (Netdata)  → https://${DOMINIO_NETDATA}"
if [ "$PAINEL_VALIDADO" = "sim" ]; then
  echo -e "  Painel (PDV)      → https://${DOMINIO_PAINEL} (fonte: ${PAINEL_FONTE_USADA}, validado host=container=https)"
else
  echo -e "  Painel (PDV)      → ${RED}https://${DOMINIO_PAINEL} — PUBLICADO MAS NÃO VALIDADO${NC} (fonte: ${PAINEL_FONTE_USADA}) — ver PANEL_DEPLOY_OK acima antes de liberar pro cliente"
fi
if [ "$HOME_INSTALADO" = "sim" ]; then
  echo -e "  Home (raiz)       → https://${DOMINIO_BASE}"
else
  echo -e "  Home (raiz)       → ${RED}NÃO publicada nesta execução${NC} (ver pendência 9 abaixo)"
fi
echo -e "  Tenant Lyra       → ${TENANT_ID}"
echo -e "  Credenciais       → ${CRED_FILE} (chmod 600)"
echo ""
echo -e "  Basic Auth (Eco/Acorde) → usuário: ${BASICAUTH_USER}  senha: ver ${CRED_FILE}"
echo -e "  GUIs de Ritmo/Harmonia/Harpa → escondidas (404 em qualquer rota que não seja API/webhook/widget)"
echo ""
echo -e "${YELLOW}PRÓXIMOS PASSOS (fora do alcance de script):${NC}"
echo -e "  1. No painel de operações, cadastrar Melhor Envio / InfinitePay / 99 Empresas para '${NOME_LOJA}'."
echo -e "  2. Inbox de WhatsApp no Harpa: precisa de credenciais de um provedor (Meta Cloud API/Twilio/360dialog)."
echo -e "  3. Confirmar Plano de Contas BR no Setup Wizard do ERPNext, se o passo automático não achou o nome certo."
echo -e "  4. Configurar monitores/alertas no Uptime Kuma (Eco) pela interface web (Basic Auth: ${BASICAUTH_USER}) — crie a Status Page com slug 'synapse' (é o que o painel consulta, sem login, em /api/status-page/synapse)."
echo -e "  5. Se a importação de workflows (fase 12) foi pulada, gerar a API key do N8N via túnel SSH (ver aviso da fase 12) e rodar manualmente."
echo -e "  6. Confirmar que os 7 registros DNS (ritmo/harmonia/harpa/acorde/eco/painel + a raiz/apex ${DOMINIO_BASE}) apontam pro IP desta VPS."
echo -e "  7. Validar manualmente em outro navegador que https://${DOMINIO_ERP}/app, https://${DOMINIO_N8N}/ e https://${DOMINIO_CHAT}/app/login realmente devolvem 404 antes de liberar acesso ao cliente."
if [ "$PAINEL_VALIDADO" != "sim" ]; then
  echo -e "  8. ${RED}Painel publicado mas NÃO validado${NC} — host/container/HTTPS não bateram em algum dos 7 arquivos (ver PANEL_DEPLOY_OK). Rode: cd /home/ubuntu/painel && docker compose up -d --force-recreate, espere o certificado, e confira https://${DOMINIO_PAINEL}/sw.js manualmente antes de liberar pro cliente — NÃO declare o PDV pronto sem isso."
fi
if [ -z "$LYRA_API_KEY" ]; then
  echo -e "  8. ${RED}Onboarding da Lyra falhou — rode o script de novo (é idempotente) depois de corrigir LYRA_CENTRAL_URL/LYRA_ADMIN_API_KEY.${NC}"
fi
if [ "$HOME_INSTALADO" != "sim" ]; then
  echo -e "  9. ${RED}Home não publicada${NC} — rode de novo com a pasta/arquivo como 5º argumento, ou copie pra /root/home-site (pasta) ou /root/index.html (arquivo)."
fi
if [ "$BRAZIL_NF_CONFIRMADO" != "sim" ]; then
  echo -e "  10. ${RED}Brazil NF não confirmado${NC} — bench install-app rodou sem erro mas o app não aparece em 'bench list-apps'. Investigar antes de liberar nota fiscal pro cliente."
fi
echo -e "${GREEN}============================================================${NC}"

}

# Chamada única, na última linha do arquivo — só a partir daqui o bash
# executa qualquer coisa (ver comentário no início da função main acima).
main "$@"

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
err()  { echo -e "${RED}[ERRO]${NC} $1"; cancao_registra_erro "$1"; }
fatal(){ echo -e "${RED}[FATAL]${NC} $1"; exit 1; }

# =============================================================================
# CANCAO DA LYRA  (parte do Synapse: "Synapse instalado" == "Synapse completo")
#  - INSTALL = FAIL: qualquer err()/falha critica derruba o veredito e o exit code.
#  - O payload (app do Ritmo, workflows, Painel, patch da Lyra) vai ANEXADO a este
#    script, com sha256 verificado. Nao existe instalacao manual complementar.
# =============================================================================
CANCAO_BUNDLE_SHA256="487a201efc1dc77350ee78e48cb1563dadef771b8e30c0bd1de954205d40a282"
CANCAO_ROLE="nomen"
CANCAO_DIR="/home/ubuntu/cancao_bundle"
INSTALL_ERROS=0
INSTALL_ERROS_LISTA=()
cancao_registra_erro() { INSTALL_ERROS=$((INSTALL_ERROS+1)); INSTALL_ERROS_LISTA+=("$1"); }

cancao_trap_exit() {
  local rc=$?
  if [ "$rc" -eq 0 ] && { [ "${INSTALL_ERROS:-0}" -gt 0 ] || [ "${FALHA_CRITICA:-false}" = true ]; }; then
    echo ""
    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}  INSTALL = FAIL  (${INSTALL_ERROS} erro(s) obrigatorio(s))${NC}"
    local e; for e in "${INSTALL_ERROS_LISTA[@]:-}"; do [ -n "$e" ] && echo -e "${RED}   - ${e}${NC}"; done
    echo -e "${RED}  A instalacao NAO esta concluida. Corrija e rode de novo.${NC}"
    echo -e "${RED}============================================================${NC}"
    exit 1
  fi
}
trap cancao_trap_exit EXIT

# resultado de um check da Cancao: usa relatorio() quando existe (Nomen) e SEMPRE conta como erro se FAIL
cancao_check() {
  local status="$1" nome="$2" detalhe="${3:-}"
  if declare -F relatorio >/dev/null 2>&1; then relatorio "$status" "Cancao: ${nome}" "$detalhe"; fi
  if [ "$status" = "PASS" ]; then ok "Cancao: ${nome} ${detalhe}"; else err "Cancao: ${nome} - ${detalhe}"; FALHA_CRITICA=true; fi
}

cancao_extrair_bundle() {
  local self="${BASH_SOURCE[0]:-$0}"
  [ -f "$self" ] || fatal "Nao achei o proprio script para extrair o payload da Cancao (nao rode via 'curl | bash': salve o arquivo e execute)."
  grep -q '^#__CANCAO_PAYLOAD__$' "$self" || fatal "Payload da Cancao ausente neste instalador."
  rm -rf "$CANCAO_DIR"; mkdir -p "$CANCAO_DIR"
  sed -n '/^#__CANCAO_PAYLOAD__$/,$p' "$self" | tail -n +2 | tr -d '\r\n ' | base64 -d > /tmp/cancao_bundle.tgz 2>/dev/null \
    || fatal "Payload da Cancao corrompido (base64)."
  local got; got="$(sha256sum /tmp/cancao_bundle.tgz | cut -d' ' -f1)"
  [ "$got" = "$CANCAO_BUNDLE_SHA256" ] || fatal "sha256 do payload da Cancao NAO confere (esperado ${CANCAO_BUNDLE_SHA256}, obtido ${got})."
  tar xzf /tmp/cancao_bundle.tgz -C "$CANCAO_DIR" || fatal "Falha ao extrair o payload da Cancao."
  local req="ritmo-app/pyproject.toml workflows/cancao_ingestao.json workflows/cancao_flush_heartbeat.json workflows/cancao_aprovacao_harpa.json workflows/synapse_provisionar_cliente.json painel_patch/patch_painel_aprovacoes.py painel_patch/patch_painel_harmonia.py"
  [ "$CANCAO_ROLE" = "nomen" ] && req="$req lyra/lyra.patch semaphore/configurar_semaphore_synapse.sh semaphore/provisionar_cliente_synapse2.sh semaphore/playbooks/provisionar_cliente.yml semaphore/playbooks/validar_integracao.yml semaphore/scripts/registrar_inventario_com_retry.sh"
  for f in $req; do
    [ -s "$CANCAO_DIR/$f" ] || fatal "Payload da Cancao incompleto: falta $f"
  done
  ok "Payload da Cancao extraido e verificado (sha256 ${got:0:12}...)"
}

# Ritmo: instala synapse_core (DocTypes, hooks, APIs, Outbox, execucao). Obrigatorio.
cancao_instalar_ritmo() {
  log "Cancao: instalando synapse_core no Ritmo..."
  [ -n "${ERP_API_KEY:-}" ] && [ -n "${ERP_API_SECRET:-}" ] || fatal "Cancao: ERP_API_KEY/SECRET do usuario de automacao ausentes - nao da para instalar/validar a Cancao."
  local C=ritmo-backend-1 B=/home/frappe/frappe-bench
  docker exec -u root $C rm -rf $B/apps/synapse_core || fatal "Cancao: nao consegui limpar apps/synapse_core"
  docker exec -u root $C mkdir -p $B/apps/synapse_core || fatal "Cancao: mkdir apps/synapse_core"
  docker cp "$CANCAO_DIR/ritmo-app/." $C:$B/apps/synapse_core/ || fatal "Cancao: docker cp do app falhou"
  docker exec -u root $C chown -R frappe:frappe $B/apps/synapse_core
  docker exec -u frappe $C bash -c "cd $B && ./env/bin/pip install -e apps/synapse_core && (grep -qxF synapse_core sites/apps.txt || echo synapse_core >> sites/apps.txt)" \
    || fatal "Cancao: pip install -e synapse_core falhou"
  docker exec -u frappe $C bash -c "cd $B && (bench --site ${DOMINIO_ERP} list-apps | grep -qx synapse_core || bench --site ${DOMINIO_ERP} install-app synapse_core) && bench --site ${DOMINIO_ERP} migrate" \
    || fatal "Cancao: install-app/migrate do synapse_core falhou"
  docker exec -u frappe $C bash -c "cd $B && bench --site ${DOMINIO_ERP} list-apps" | grep -qx synapse_core \
    || fatal "Cancao: synapse_core NAO aparece em 'bench list-apps'"
  # papel + configuracao (URL da Harmonia e usuario de automacao = dono da API key)
  local R
  R=$(ritmo_exec <<PYEOF
def main():
    import frappe
    u = frappe.db.get_value("User", {"api_key": "${ERP_API_KEY}"}, "name")
    if not u:
        print("CANCAO_ERRO usuario da API key nao encontrado"); return
    frappe.get_doc("User", u).add_roles("Synapse Automacao")
    frappe.db.set_single_value("Synapse Autonomia", "usuario_automacao", u)
    frappe.db.set_single_value("Synapse Autonomia", "harmonia_ingest_url", "https://${DOMINIO_N8N}/webhook/synapse-evento")
    frappe.db.commit()
    print("CANCAO_OK", u)
PYEOF
)
  echo "$R" | grep -q "CANCAO_OK" || fatal "Cancao: configuracao do Synapse Autonomia falhou: ${R}"
  docker exec -u frappe $C bash -c "cd $B && bench --site ${DOMINIO_ERP} enable-scheduler" >/dev/null 2>&1 || fatal "Cancao: nao consegui habilitar o scheduler (relay do Outbox depende dele)"
  ( cd /home/ubuntu/ritmo 2>/dev/null || true; docker compose --project-name ritmo restart backend queue-short queue-long scheduler >/dev/null 2>&1 ) || fatal "Cancao: restart do Ritmo falhou"
  sleep 8
  ok "Cancao: synapse_core instalado e configurado no Ritmo (${DOMINIO_ERP})"
}

# Workflows: sobrepoe os 12 arquivos da Cancao em WORKFLOWS_DIR (3 novos + 9 existentes com dominio corrigido).
cancao_workflows_overlay() {
  [ -n "${WORKFLOWS_DIR:-}" ] && [ -d "$WORKFLOWS_DIR" ] || fatal "Cancao: pasta de workflows indisponivel (clone do repo json falhou) - INSTALL=FAIL."
  cp "$CANCAO_DIR"/workflows/*.json "$WORKFLOWS_DIR"/ || fatal "Cancao: nao consegui copiar os workflows para ${WORKFLOWS_DIR}"
  # regra: *_DOMAIN no .env e so o host; todo consumidor prefixa https://. Nenhum 'https://https://' nem URL sem esquema.
  if grep -rlE 'https://https://' "$WORKFLOWS_DIR"/*.json >/dev/null 2>&1; then fatal "Cancao: 'https://https://' encontrado nos workflows"; fi
  if grep -rEq '"=\{\{\$env\.(ERPNEXT|HARMONIA|CHATWOOT)_DOMAIN' "$WORKFLOWS_DIR"/*.json; then fatal "Cancao: workflow com *_DOMAIN sem esquema https://"; fi
  # n8n 2.40.7: em httpRequest typeVersion>=3 o parametro e `method`; `requestMethod` e IGNORADO e o no envia GET (verificado). Reprova.
  python3 - "$WORKFLOWS_DIR" <<'PYEOF' || fatal "Cancao: workflow(s) com httpRequest usando 'requestMethod' (vira GET no n8n 2.x). Corrija para 'method'."
import json, glob, sys
bad = []
for f in glob.glob(sys.argv[1] + "/*.json"):
    for n in json.load(open(f, encoding="utf-8")).get("nodes", []):
        if n.get("type", "").endswith(".httpRequest") and n.get("typeVersion", 0) >= 3 and "requestMethod" in n.get("parameters", {}):
            bad.append(f.split("/")[-1] + " :: " + n.get("name", "?"))
if bad:
    print("requestMethod em:", *bad[:10], sep="\n  "); sys.exit(1)
PYEOF
  cancao_cors_workflows "$WORKFLOWS_DIR" "https://${DOMINIO_PAINEL}"
  ok "Cancao: workflows da Cancao + dominios normalizados + CORS restrito ao Painel em ${WORKFLOWS_DIR}"
}

# ---------------------------------------------------------------------------------------------------------
# Painel (Aprovar/Rejeitar): a fonte do Painel e a que o instalador JA resolve (arquivo, pasta de 7 arquivos ou repo pinado).
# Sobre o index.html resultante aplica-se, no site/, o patch de Aprovacoes (ancoras verificadas; "ja aplicado" e idempotente;
# ancora ausente = FATAL: nao publica um Painel sem o ciclo humano). Roda ANTES do docker compose e das provas de SHA.
cancao_painel_aprovacoes_aplicar() {
  local idx="$1"
  [ -f "$idx" ] || fatal "Cancao: index.html do Painel ausente em ${idx}"
  command -v python3 >/dev/null 2>&1 || fatal "Cancao: python3 ausente (necessario para o patch de Aprovacoes do Painel)"
  python3 "$CANCAO_DIR/painel_patch/patch_painel_aprovacoes.py" "$idx" "${idx}.cancao.tmp" || { rm -f "${idx}.cancao.tmp"; fatal "Cancao: o patch de Aprovacoes NAO casou com este Painel (index.html mudou). INSTALL=FAIL: atualize o patcher, nao publique sem Aprovar/Rejeitar."; }
  mv "${idx}.cancao.tmp" "$idx"
  grep -q 'page-aprovacoes' "$idx" || fatal "Cancao: Painel sem a aba Aprovacoes apos o patch"
  # Harmonia: credentials omit (CORS), multipart e ligacao do anexo ao workflow existente atendimento/enviar-anexo
  python3 "$CANCAO_DIR/painel_patch/patch_painel_harmonia.py" "$idx" "${idx}.cancao.tmp" || { rm -f "${idx}.cancao.tmp"; fatal "Cancao: o patch Painel->Harmonia (anexo/CORS) NAO casou com este Painel. INSTALL=FAIL."; }
  mv "${idx}.cancao.tmp" "$idx"
  grep -q "Harmonia.chamarMultipart('atendimento/enviar-anexo'" "$idx" || fatal "Cancao: Painel sem a ligacao do anexo ao Harmonia apos o patch"
  ok "Cancao: Painel com Aprovar/Rejeitar (sha256 $(sha256sum "$idx" | cut -c1-12)...)"
}

# Migracao de instalacao existente (publicacao por DIRETORIO, nao por bind mount de arquivo): preserva backup do compose e do
# default.conf antes de qualquer reescrita.
cancao_backup_painel_config() {
  local ts; ts="$(date +%Y%m%d%H%M%S)"
  local f
  for f in /home/ubuntu/painel/docker-compose.yml /home/ubuntu/painel/conf/default.conf; do
    if [ -f "$f" ] && ! [ -f "${f}.bak.cancao" ]; then cp -p "$f" "${f}.bak.${ts}" && ok "Cancao: backup de ${f} -> ${f}.bak.${ts}"; fi
  done
  mkdir -p /home/ubuntu/painel/site /home/ubuntu/painel/conf
  if docker inspect painel >/dev/null 2>&1; then
    if docker inspect painel --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' | grep -q '/index.html:/usr/share/nginx/html/index.html'; then
      warn "Cancao: instalacao ANTIGA detectada (bind mount de arquivo unico). Sera migrada para diretorio com --force-recreate."
    fi
  fi
}

# Prova de que o container usa o DIRETORIO (e nunca o arquivo unico) apos o --force-recreate.
cancao_painel_verifica_mount() {
  local m; m="$(docker inspect painel --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' 2>/dev/null)"
  if echo "$m" | grep -q '/home/ubuntu/painel/site:/usr/share/nginx/html' && ! echo "$m" | grep -q 'index.html:/usr/share/nginx/html/index.html'; then
    ok "Cancao: Painel monta o DIRETORIO /home/ubuntu/painel/site em /usr/share/nginx/html (mounts: ${m})"
  else
    err "Cancao: o container painel NAO usa o diretorio site/ (mounts: ${m:-vazio}). Bind mount de arquivo unico e proibido."; FALHA_CRITICA=true
  fi
}

# CORS da Harmonia: SO os webhooks que o Painel chama pelo navegador recebem allowedOrigins = origem do Painel. Webhooks
# servidor-a-servidor (Ritmo, Chatwoot, InfinitePay, Lyra interna, Cancao, provisionamento) ficam sem CORS. Nunca '*'.
cancao_cors_workflows() {
  local dir="$1" origem="$2"
  [ -n "${DOMINIO_PAINEL:-}" ] || fatal "Cancao: DOMINIO_PAINEL ausente (CORS precisa da origem real do Painel)"
  python3 - "$dir" "$origem" <<'PYEOF' || fatal "Cancao: falha ao aplicar CORS nos workflows"
import json, glob, sys
d, origem = sys.argv[1], sys.argv[2]
PREFIXOS = ("fiscal/", "lyra/", "integracoes/", "marketing/", "consumo/", "envio/", "atendimento/", "endereco/", "monitoramento/", "pagamentos/")
assert origem.startswith("https://") and "*" not in origem, "origem invalida: " + origem
n = 0
for f in glob.glob(d + "/*.json"):
    wf = json.load(open(f, encoding="utf-8"))
    ch = False
    for node in wf.get("nodes", []):
        if node["type"].endswith(".webhook") and node["parameters"].get("path", "").startswith(PREFIXOS):
            opt = node["parameters"].setdefault("options", {})
            if opt.get("allowedOrigins") != origem:
                opt["allowedOrigins"] = origem; ch = True; n += 1
    if ch: json.dump(wf, open(f, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print("CORS aplicado em", n, "webhook(s) ->", origem)
PYEOF
}

# Lyra Central (somente Nomen): aplica o patch sobre o codigo clonado. Idempotente; falha = FATAL.
cancao_aplicar_patch_lyra() {
  log "Cancao: aplicando patch da Lyra Central em ${LYRA_APP_DIR}..."
  if grep -q 'decideOnce' "${LYRA_APP_DIR}/src/services/geminiService.js" 2>/dev/null && [ -f "${LYRA_APP_DIR}/src/routes/decide.js" ]; then
    ok "Cancao: patch da Lyra ja aplicado"; return 0
  fi
  command -v patch >/dev/null 2>&1 || apt-get install -y patch >/dev/null 2>&1 || fatal "Cancao: 'patch' indisponivel"
  ( cd "$LYRA_APP_DIR" && patch -p2 --dry-run < "$CANCAO_DIR/lyra/lyra.patch" >/dev/null ) \
    || fatal "Cancao: o patch da Lyra NAO aplica no codigo clonado (upstream mudou?). INSTALL=FAIL."
  ( cd "$LYRA_APP_DIR" && patch -p2 < "$CANCAO_DIR/lyra/lyra.patch" >/dev/null ) || fatal "Cancao: falha ao aplicar o patch da Lyra"
  grep -q '^GEMINI_MODEL=.\+' "${LYRA_APP_DIR}/.env" 2>/dev/null || fatal "Cancao: GEMINI_MODEL ausente no .env da Lyra (sem fallback por design)"
  ok "Cancao: patch da Lyra aplicado (/v1/decide, autonomia, sem fallback de modelo)"
}

# Validacao funcional: o ciclo real, nao so "o servico responde".
cancao_validar() {
  log "Cancao: validacao funcional (Ritmo -> Outbox -> Harmonia -> gate -> PROCESSED)..."
  local AUTH="Authorization: token ${ERP_API_KEY}:${ERP_API_SECRET}" R
  local RIT="https://${DOMINIO_ERP}/api/method/synapse_core.api"
  # 1) workflows da Cancao existem e estao ativos
  if [ -n "${N8N_API_KEY:-}" ]; then
    R=$(curl -s -m 30 -H "X-N8N-API-KEY: ${N8N_API_KEY}" "https://${DOMINIO_N8N}/api/v1/workflows?limit=250" | python3 -c "
import sys,json
try: d=json.load(sys.stdin).get('data',[])
except Exception: d=[]
need=['Synapse — Canção — Ingestão de Eventos (Harmonia)','Synapse — Canção — Flush, Heartbeat e Reconciliação (Harmonia)','Synapse — Canção — Aprovação Humana (Harpa)']
ativos={w['name'] for w in d if w.get('active')}
print('ok' if all(n in ativos for n in need) else 'faltando:'+','.join(n for n in need if n not in ativos))")
    [ "$R" = "ok" ] && cancao_check PASS "workflows ativos" "(ingestao, flush/heartbeat, aprovacao)" || cancao_check FAIL "workflows ativos" "$R"
  else
    cancao_check FAIL "workflows ativos" "sem N8N_API_KEY - nao foi possivel confirmar"
  fi
  # 2) Ritmo: synapse_core responde e o estado operacional e HEALTHY
  R=$(curl -s -m 30 -H "$AUTH" "${RIT}.state" | python3 -c "import sys,json
try: print(json.load(sys.stdin)['message']['estado_operacional'])
except Exception: print('erro')")
  [ "$R" = "HEALTHY" ] && cancao_check PASS "Ritmo estado operacional" "HEALTHY" || cancao_check FAIL "Ritmo estado operacional" "esperado HEALTHY, obtido ${R}"
  # 3) ciclo real: altera o Ritmo e espera o evento chegar a PROCESSED pela Harmonia
  local CODE="SYNAPSE-SMOKE-$(date +%s)" GRP
  GRP=$(curl -s -m 30 -H "$AUTH" -G "https://${DOMINIO_ERP}/api/resource/Item%20Group" --data-urlencode 'filters=[["is_group","=",0]]' --data-urlencode 'limit_page_length=1' | python3 -c "import sys,json
try: print(json.load(sys.stdin)['data'][0]['name'])
except Exception: print('')")
  if [ -z "$GRP" ]; then cancao_check FAIL "ciclo Ritmo->Harmonia" "nenhum Item Group folha para o teste"; else
    curl -s -m 30 -o /dev/null -H "$AUTH" -H 'Content-Type: application/json' -X POST "https://${DOMINIO_ERP}/api/resource/Item" \
      -d "{\"item_code\":\"${CODE}\",\"item_name\":\"${CODE}\",\"item_group\":\"${GRP}\",\"stock_uom\":\"Nos\",\"is_stock_item\":0}"
    local i ST="" GA=""
    for i in $(seq 1 40); do
      R=$(curl -s -m 30 -H "$AUTH" -G "https://${DOMINIO_ERP}/api/resource/Synapse%20Outbox" --data-urlencode "filters=[[\"entity_id\",\"=\",\"${CODE}\"]]" --data-urlencode 'fields=["status","gate_action","event_type"]' | python3 -c "import sys,json
try:
  d=json.load(sys.stdin)['data']; print((d[0]['status']+'|'+str(d[0].get('gate_action'))) if d else '')
except Exception: print('')")
      ST="${R%%|*}"; GA="${R##*|}"
      [ "$ST" = "PROCESSED" ] && break
      sleep 6
    done
    if [ "$ST" = "PROCESSED" ]; then cancao_check PASS "ciclo Ritmo->Outbox->Harmonia->gate" "evento de ${CODE} PROCESSED (gate=${GA})"
    else cancao_check FAIL "ciclo Ritmo->Outbox->Harmonia->gate" "evento de ${CODE} terminou em '${ST:-ausente}' apos ~4 min (relay do Outbox, webhook da Harmonia ou ACK falhou)"; fi
    curl -s -m 30 -o /dev/null -H "$AUTH" -X DELETE "https://${DOMINIO_ERP}/api/resource/Item/${CODE}"
  fi
  # 4) Lyra Central: rota /v1/decide instalada e autenticada (evento de controle - nao depende do Gemini)
  local LK="${LYRA_API_KEY:-${LYRA_TENANT_API_KEY:-}}" LT="${LYRA_TENANT_ID:-${TENANT_ID:-}}" LU="${LYRA_CENTRAL_URL:-}"
  if [ -n "$LK" ] && [ -n "$LT" ] && [ -n "$LU" ]; then
    R=$(curl -s -m 30 -X POST "${LU}/v1/decide" -H "Authorization: Bearer ${LK}" -H "X-Tenant-ID: ${LT}" -H 'Content-Type: application/json' \
      -d '{"event":{"event_id":"smoke","event_type":"intent_expired","entity_type":"Item","entity_id":"X","state_version":1,"payload":{"operation_id":"smoke","conversa_id":"0"}}}' | python3 -c "import sys,json
try:
  d=json.load(sys.stdin); print('ok' if d.get('notifications') and d['notifications'][0]['kind']=='reconfirm_intent' else 'resposta inesperada')
except Exception: print('sem JSON (rota /v1/decide ausente?)')")
    [ "$R" = "ok" ] && cancao_check PASS "Lyra /v1/decide" "rota ativa e autenticada" || cancao_check FAIL "Lyra /v1/decide" "$R"
  else
    cancao_check FAIL "Lyra /v1/decide" "credenciais/URL da Lyra Central ausentes para o teste"
  fi
  # 5) Painel publicado com Aprovar/Rejeitar
  if [ -n "${DOMINIO_PAINEL:-}" ]; then
    curl -s -m 30 "https://${DOMINIO_PAINEL}/" | grep -q 'page-aprovacoes' && cancao_check PASS "Painel Aprovar/Rejeitar" "publicado em https://${DOMINIO_PAINEL}" \
      || cancao_check FAIL "Painel Aprovar/Rejeitar" "a pagina publicada nao contem a aba Aprovacoes"
  fi
}
# n8n <-> Semaphore (so Nomen): grava no .env do Harmonia o contrato da Integration (token/paths gerados pelo script do
# Semaphore), recria o Harmonia e PROVA o ciclo real n8n -> Integration -> Task -> Ansible com o template "Validar Integracao"
# (localhost; nao toca VPS de cliente). Nada manual. Conferimos a TASK (o endpoint de disparo responde 204 mesmo com token errado).
cancao_integrar_n8n_semaphore() {
  log "Cancao: integrando n8n <-> Semaphore (contrato vps_ip/dominio/nome_loja)..."
  local ENVF="/root/.semaphore_synapse/integracao_n8n.env" CREDF="/root/.semaphore_synapse/credenciais.env"
  if [ "${SEMA_RC:-1}" -ne 0 ]; then cancao_check FAIL "Semaphore sem pendencias" "o script de configuracao saiu com ${SEMA_RC} (FAIL - AUTOMATIZACAO INCOMPLETA) - ver ${SEMA_LOG:-log}"; return; fi
  [ "${SEMA_CONFIG_OK:-false}" = true ] || { cancao_check FAIL "integracao n8n-Semaphore" "Semaphore nao configurado"; return; }
  [ -s "$ENVF" ] || { cancao_check FAIL "integracao n8n-Semaphore" "arquivo ${ENVF} ausente"; return; }
  local k v
  while IFS='=' read -r k v; do case "$k" in SEMAPHORE_INTEGRACAO_*) grava_env_n8n "$k" "$v";; esac; done < "$ENVF"
  grava_env_n8n "SEMAPHORE_INTERNAL_URL" "http://semaphore:3000"
  local PTOK; PTOK="$(grep '^SYNAPSE_PROVISION_TOKEN=' "$N8N_ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  [ -n "$PTOK" ] || PTOK="$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  grava_env_n8n "SYNAPSE_PROVISION_TOKEN" "$PTOK"; salvar_credencial "SYNAPSE_PROVISION_TOKEN" "$PTOK"
  ( cd /home/ubuntu/n8n && docker compose up -d --force-recreate >/dev/null 2>&1 ) || { cancao_check FAIL "Harmonia recriado com a integracao" "docker compose up falhou"; return; }
  local i; for i in $(seq 1 60); do curl -s -m 4 -o /dev/null -w '%{http_code}' "https://${DOMINIO_N8N}/healthz" 2>/dev/null | grep -q 200 && break; sleep 4; done
  local TOKEN_SEMA PROJ TPL N0 CODE ST="" PAYLOAD
  TOKEN_SEMA="$(grep '^SEMAPHORE_API_TOKEN=' "$CREDF" | cut -d= -f2-)"
  PROJ="$(curl -s -H "Authorization: Bearer ${TOKEN_SEMA}" "http://127.0.0.1:${SEMAPHORE_PORT}/api/projects" | jq -r '.[] | select(.name=="Synapse") | .id' | head -n1)"
  TPL="$(curl -s -H "Authorization: Bearer ${TOKEN_SEMA}" "http://127.0.0.1:${SEMAPHORE_PORT}/api/project/${PROJ}/templates" | jq -r '.[] | select(.name=="Validar Integracao") | .id' | head -n1)"
  [ -n "$PROJ" ] && [ -n "$TPL" ] || { cancao_check FAIL "integracao n8n-Semaphore" "projeto/template Validar Integracao nao encontrados via API"; return; }
  N0="$(curl -s -H "Authorization: Bearer ${TOKEN_SEMA}" "http://127.0.0.1:${SEMAPHORE_PORT}/api/project/${PROJ}/tasks" | jq 'length')"
  PAYLOAD="$(jq -nc --arg d "validacao.${DOMINIO_BASE}" '{operacao:"validar", vps_ip:"203.0.113.10", dominio:$d, nome_loja:"Validacao Synapse"}')"
  # o webhook so existe alguns segundos DEPOIS do healthz (verificado no n8n 2.40.7): retentativas
  for i in $(seq 1 25); do
    CODE="$(curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST "https://${DOMINIO_N8N}/webhook/synapse-provisionar-cliente" -H 'Content-Type: application/json' -H "X-Synapse-Provision-Token: ${PTOK}" -d "$PAYLOAD")"
    [ "$CODE" = "202" ] && break; sleep 6
  done
  [ "$CODE" = "202" ] || { cancao_check FAIL "n8n -> webhook de provisionamento" "HTTP ${CODE:-sem resposta} (esperado 202)"; return; }
  for i in $(seq 1 40); do
    ST="$(curl -s -H "Authorization: Bearer ${TOKEN_SEMA}" "http://127.0.0.1:${SEMAPHORE_PORT}/api/project/${PROJ}/tasks" | jq -r --argjson n "${N0:-0}" --argjson t "$TPL" 'if length>$n then ([.[]|select(.template_id==$t)]|.[0].status) else "sem-task" end')"
    case "$ST" in success|error) break;; esac; sleep 3
  done
  if [ "$ST" = "success" ]; then cancao_check PASS "n8n -> Semaphore -> Ansible" "task 'Validar Integracao' success (webhook 202; contrato vps_ip/dominio/nome_loja)"
  else cancao_check FAIL "n8n -> Semaphore -> Ansible" "task terminou em '${ST:-sem-task}' (token/Integration/playbook?)"; fi
}



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


cancao_extrair_bundle
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
cancao_aplicar_patch_lyra
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
systemctl restart lyra-central-api 2>/dev/null || err "Não consegui reiniciar lyra-central-api agora — reinicie manualmente se necessário."

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

cancao_instalar_ritmo
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
grava_env_n8n "ERPNEXT_DOMAIN" "${DOMINIO_ERP}"   # so o host: todo consumidor prefixa https://
grava_env_n8n "ERPNEXT_API_KEY" "${ERP_API_KEY:-}"
grava_env_n8n "ERPNEXT_API_SECRET" "${ERP_API_SECRET:-}"
grava_env_n8n "CHATWOOT_DOMAIN" "${DOMINIO_CHAT}"   # so o host: todo consumidor prefixa https://
grava_env_n8n "CHATWOOT_API_TOKEN" "${CW_API_TOKEN:-}"
grava_env_n8n "CHATWOOT_ACCOUNT_ID" "${CW_ACCOUNT_ID:-}"
grava_env_n8n "HARMONIA_DOMAIN" "${DOMINIO_N8N}"   # so o host: todo consumidor prefixa https://
grava_env_n8n "N8N_BLOCK_ENV_ACCESS_IN_NODE" "false"   # n8n 2.x bloqueia $env por padrao ("access to env vars denied", verificado no 2.40.7); os workflows leem credenciais via $env

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

  cancao_backup_painel_config

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
  cancao_painel_aprovacoes_aplicar /home/ubuntu/painel/site/index.html
  cd /home/ubuntu/painel && docker compose up -d --force-recreate
  cancao_painel_verifica_mount

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
  err "Painel NÃO foi publicado — nenhuma fonte de HTML disponível nesta execução. Rode de novo passando o caminho local como 4º argumento, copiando o arquivo pra /root/synapse_painel.html, ou criando github.com/${GITHUB_ORG}/painel com o index.html (o script é idempotente)."
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
    fatal "Falha ao clonar github.com/${GITHUB_ORG}/json (confirma GITHUB_TOKEN) - workflows sao obrigatorios: INSTALL=FAIL."
    WORKFLOWS_DIR=""
  fi
fi

cancao_workflows_overlay
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
    err "Não consegui gerar a API key pública do N8N automaticamente (endpoint interno pode ter mudado). Importação de workflows pulada. A UI do Harmonia não responde mais publicamente (GUI escondida de propósito) e a porta 5678 não é publicada no host — pra gerar a chave manualmente: (1) adicione 'ports: [\"127.0.0.1:5678:5678\"]' ao serviço n8n em /home/ubuntu/n8n/docker-compose.yml, (2) 'docker compose up -d', (3) na sua máquina: 'ssh -L 5678:localhost:5678 <usuario>@<ip-da-vps>' e abra http://localhost:5678 (Configurações > API), (4) remova a linha 'ports:' e rode 'docker compose up -d' de novo pra fechar o acesso. Depois: N8N_URL=https://${DOMINIO_N8N} N8N_API_KEY=<chave> python3 2_importar_workflows_harmonia.py ${WORKFLOWS_DIR}"
  fi
fi

# =============================================================================

cancao_validar
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
      - stack-network   # o Harmonia (n8n) precisa alcancar http://semaphore:3000 (Integration)
volumes:
  semaphore_config:
  semaphore_data:
networks:
  semaphore-network:
    external: true
  stack-network:
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
SEMA_BUNDLE_DIR="$CANCAO_DIR/semaphore"   # bundle fixado e verificado por sha256 (nao depende de arquivo local nem de repo privado)
[ -f "$SEMA_BUNDLE_DIR/configurar_semaphore_synapse.sh" ] || SEMA_BUNDLE_DIR=""

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
    SYNAPSE_PAINEL_REF="${SYNAPSE_PAINEL_REF:-}" \
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


cancao_integrar_n8n_semaphore
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
if [ "$FALHA_CRITICA" = true ] || [ "${INSTALL_ERROS:-0}" -gt 0 ]; then
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
exit $?
#__CANCAO_PAYLOAD__
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

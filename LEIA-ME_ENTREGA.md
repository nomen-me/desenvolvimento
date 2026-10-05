# Entrega — Workflows Harmonia avulsos (Synapse)

Gerado a partir de `instalar_nomen_completo.sh`, `provisionar_cliente_synapse2.sh` e `synapse_painel_18-09m.html`.
Nenhum workflow foi executado contra a infraestrutura real (sem acesso de rede neste ambiente). **Nenhum está como PASS.**

## Como importar
Os JSONs têm só `name`, `nodes`, `connections`, `settings` (compatível com a API pública do n8n e com o script de importação do provisionamento, que casa por nome, atualiza e ativa). Importar na UI também funciona. Depois: ativar e conferir CORS (ver Pendências, item 5).

## Credenciais / variáveis (nenhuma gravada nos JSONs)
Todas já existem no `/home/ubuntu/n8n/.env` do Harmonia (gravadas pelo instalador) e são lidas por `$env`:

| Variável | Usada por |
|---|---|
| `CHATWOOT_DOMAIN`, `CHATWOOT_API_TOKEN`, `CHATWOOT_ACCOUNT_ID` | WF-01, 02, 03, 04, 11 |
| `CHATWOOT_WHATSAPP_INBOX_ID` | WF-11 (preferência; ver Pendências, item 3) |
| `ERPNEXT_DOMAIN`, `ERPNEXT_API_KEY`, `ERPNEXT_API_SECRET` | WF-02, 06, 08, 09, 10, 12 |
| `HARMONIA_DOMAIN` (`https://<dominio-n8n>`, já gravada pelo instalador) | WF-08 (monta o `webhook_url`) |
| (nenhuma) | WF-05: Netdata é o container `acorde:19999` na `stack-network`; o Basic Auth fica só no Traefik |

InfinitePay: o handle (InfiniteTag) é lido do DocType `Synapse Credencial Externa`, registro `infinitepay` (campos `metadados.handle`, senão `conta_conectada`). Sem token no workflow.

## Convenções comuns
- Erro real → HTTP 502 (ou 4xx de validação / 424-501 para pendências) com `{sucesso:false, erro, message}`. O Painel lê `message`.
- Mensagens de erro removem URLs e tokens; WF-05 não revela o host interno.
- Config ausente devolve `PENDENTE_CONFIGURACAO_*` explicitamente.
- `$HARMONIA` nos curls = `https://harmonia.<dominio-base>`.

---

## WF-01 — `Synapse — Atendimento — Listar Conversas`
- **Webhook:** `POST /webhook/atendimento/conversas` · arquivo `01_atendimento_conversas.json`
- **Responsabilidade:** lista conversas reais do Harpa (todas as situações, até 10 páginas = 250) e converte para o contrato do Painel.
- **Entrada:** `{}`
- **Saída:** `{"conversas":[{"id":123,"nome":"…","canal":"whatsapp","nao_lida":true,"status":"open","contato":"+55…","ultima_mensagem":"…","atualizado_em":"ISO"}]}`; sem conversas → `{"conversas":[]}`. `canal` ∈ whatsapp/facebook/instagram/website/telegram/sms/outro (o Painel já mapeia).
- **Erros:** 500 `PENDENTE_CONFIGURACAO_CHATWOOT`; 502 Harpa indisponível/401 (nunca `conversas: []`).
- **Timeout/retry:** 15 s, 3 tentativas (GET).
- **Curl:** `curl -sS -X POST "$HARMONIA/webhook/atendimento/conversas" -H 'Content-Type: application/json' -d '{}'`
- **Status:** `ESTRUTURALMENTE_PRONTO_AGUARDANDO_TESTE_REAL`

## WF-02 — `Synapse — Atendimento — Mensagens`
- **Webhook:** `POST /webhook/atendimento/mensagens` · `02_atendimento_mensagens.json`
- **Responsabilidade:** histórico real da conversa (paginado por `before`, até 200 mensagens), contato, CPF e últimos 5 pedidos do Ritmo.
- **Entrada:** `{"conversa_id":123}`
- **Saída:** `{"mensagens":[{"autor":"cliente|agente|sistema","hora":"ISO","texto":"…"}],"cliente":{"nome":"…","cpf":null,"contato":"5521…"},"ultimos_pedidos":[{"id":"SAL-ORD-…"}]}`
- **Fontes:** mensagens/contato = Harpa; CPF = `Customer.tax_id` (só se tiver 11 dígitos); pedidos = `Sales Order` do cliente. Vínculo conversa→cliente = telefone (comparação pelos últimos 9 dígitos). Sem cliente único → `cpf:null`, `ultimos_pedidos:[]` (nunca adivinha).
- **Erros:** 400 `conversa_id` inválido; 404 conversa inexistente; 502 Harpa ou Ritmo indisponível.
- **Curl:** `curl -sS -X POST "$HARMONIA/webhook/atendimento/mensagens" -H 'Content-Type: application/json' -d '{"conversa_id":ID_REAL}'`
- **Status:** `ESTRUTURALMENTE_PRONTO_AGUARDANDO_TESTE_REAL` (vínculo por telefone = premissa a confirmar; ver Pendências, item 4)

## WF-03 — `Synapse — Atendimento — Enviar Mensagem`
- **Webhook:** `POST /webhook/atendimento/enviar` · `03_atendimento_enviar.json`
- **Entrada:** `{"conversa_id":123,"mensagem":"texto"}`
- **Saída:** `{"sucesso":true,"id":<id real da mensagem no Harpa>}`; erro → `{"sucesso":false,"erro":"…"}` com HTTP de erro.
- **Idempotência/retry:** sem retry no POST (reenviar poderia duplicar a mensagem ao cliente). Timeout 15 s.
- **Curl:** `curl -sS -X POST "$HARMONIA/webhook/atendimento/enviar" -H 'Content-Type: application/json' -d '{"conversa_id":ID_REAL,"mensagem":"Mensagem de teste real"}'` e conferir no Harpa.
- **Status:** `ESTRUTURALMENTE_PRONTO_AGUARDANDO_TESTE_REAL`

## WF-04 — `Synapse — Atendimento — Enviar Anexo`
- **Webhook:** `POST /webhook/atendimento/enviar-anexo` (multipart) · `04_atendimento_enviar_anexo.json`
- **Entrada:** campos `conversa_id` + 1 arquivo em `attachments[]`. Mais de um arquivo → 400 (um por requisição; o Painel envia `files[0]`).
- **Saída:** `{"sucesso":true,"id":<id real>}`
- **Detalhes:** o arquivo não é gravado; segue em memória ao Harpa com nome/conteúdo preservados. Sem retry. Timeout 60 s. Limite = `N8N_PAYLOAD_SIZE_MAX` (padrão 16 MB) e limite do Chatwoot.
- **Curl:** `curl -sS -X POST "$HARMONIA/webhook/atendimento/enviar-anexo" -F conversa_id=ID_REAL -F 'attachments[]=@./teste.pdf'`
- **Status:** `ESTRUTURALMENTE_PRONTO_AGUARDANDO_TESTE_REAL`. O Panel `synapse_painel_18-09n.html` já chama este webhook (`Harmonia.chamarComArquivo`, multipart com `attachments[]` + `conversa_id`, `credentials:'include'`, erro lido de `data.message`) e o contrato bate. Nenhuma alteração no workflow.

## WF-05 — `Synapse — Monitoramento — Métricas`
- **Webhook:** `POST /webhook/monitoramento/metricas` · `05_monitoramento_metricas.json`
- **Entrada:** `{"chart":"system.cpu","points":1,"format":"json","after":-1}` (defaults 1/json/-1; `format` só aceita `json`; `chart` só `[A-Za-z0-9_.-]`).
- **Fonte:** `GET http://acorde:19999/api/v1/data` (container `acorde`, compose do instalador).
- **Saída:** `{"labels":[…],"data":[[…]]}` reais do Netdata (aceita `labels/data` no topo ou dentro de `result`). Resposta sem labels/data (ex.: HTML) → 502.
- **Curl:** para cada um de `system.cpu`, `system.ram`, `disk_space._`: `curl -sS -X POST "$HARMONIA/webhook/monitoramento/metricas" -H 'Content-Type: application/json' -d '{"chart":"system.cpu","points":1,"format":"json","after":-1}'`
- **Status:** `ESTRUTURALMENTE_PRONTO_AGUARDANDO_TESTE_REAL` · ver `CONFLITO_DE_CONTRATO` potencial (Pendências, item 2).

## WF-06 — `Synapse — Consumo — Serviços`
- **Webhook:** `POST /webhook/consumo/servicos` · `06_consumo_servicos.json`
- **Entrada:** `{}`
- **Saída atual:** HTTP **501** `{"status":"PENDENTE_FONTE_DE_DADOS","pendencias":[ia, frete, freteVolume],"parcial":{"freteSaldo":"<cache real de Synapse Credencial Externa.saldo>"}}`.
- **Motivo:** nos arquivos não existe fonte de requisições de IA/dia, fretes/semana nem fretes/mês. Nenhum contador foi criado. `freteSaldo` vem do cache existente (provedor `melhorenvio`) e pode estar defasado (`cache_atualizado_em`).
- **Curl:** `curl -sS -X POST "$HARMONIA/webhook/consumo/servicos" -H 'Content-Type: application/json' -d '{}'`
- **Status:** `PENDENTE_FONTE_DE_DADOS`

## WF-08 — `Synapse — Pagamentos PDV — Criar Cobrança` (revisado)
- **Webhook:** `POST /webhook/pagamentos/pdv/criar-cobranca` · `08_pagamentos_pdv_criar_cobranca.json`
- **Entrada (como o Panel `18-09n` envia):** `{"valor":100.00,"order_nsu":"venda_<uuid>"}`. O `order_nsu` **é o `op_id` da venda**, gerado pelo PDV antes da cobrança; o Harmonia **não gera** identificador próprio (ausente → 400). `op_id` é aceito como alias.
- **Fonte:** `POST https://api.checkout.infinitepay.io/links` com `handle`, `order_nsu`, `items` e **`webhook_url` = `HARMONIA_DOMAIN` + `/webhook/pagamentos/pdv/infinitepay-webhook`** (novo nesta revisão). A criação do checkout **não** significa pagamento confirmado.
- **Saída:** `{"checkout_url":"…","order_nsu":"<mesmo op_id>"}`
- **Idempotência/retry:** sem retry; resposta ambígua nunca dispara 2ª cobrança. O reenvio seguro usa o mesmo `order_nsu`.
- **Env:** `ERPNEXT_*`, `HARMONIA_DOMAIN` (o instalador grava `https://<dominio-n8n>`).
- **Status:** `ESTRUTURALMENTE_PRONTO_AGUARDANDO_TESTE_REAL`

## WF-09 — `Synapse — Pagamentos PDV — Status` (revisado)
- **Webhook:** `POST /webhook/pagamentos/pdv/status` · `09_pagamentos_pdv_status.json`
- **Entrada:** `{"order_nsu":"…"}`; opcionais `transaction_nsu`, `slug` (alias `invoice_slug`), repassados à InfinitePay quando existirem.
- **Fonte:** `POST https://api.checkout.infinitepay.io/payment_check`.
- **Estados (HTTP 200):** `pago` (somente `success===true` e `paid===true`) · `pendente` (`paid===false`) · `recusado` (campo textual de status recusado/negado/cancelado, se a InfinitePay o enviar) · `indeterminado` (qualquer outra resposta; vem com `reconciliar:true`). Falha de rede/HTTP da InfinitePay → 502. Indeterminado e erro **nunca** viram `pago` e **não** justificam nova cobrança: o PDV reconcilia com o mesmo `order_nsu`.
- **Aberto até o teste real:** (1) se o `payment_check` aceita só `handle`+`order_nsu`; (2) como a InfinitePay representa recusa (o mapeamento de `recusado` é conservador, ainda não visto num payload real).
- **Status:** `ESTRUTURALMENTE_PRONTO_AGUARDANDO_TESTE_REAL`

## WF-12 — `Synapse — Pagamentos PDV — Webhook InfinitePay` (novo, complementar)
- **Webhook:** `POST /webhook/pagamentos/pdv/infinitepay-webhook` · `12_pagamentos_pdv_webhook_infinitepay.json`. É o `webhook_url` entregue à InfinitePay pelo WF-08.
- **Entrada (InfinitePay):** `order_nsu`, `transaction_nsu`, `invoice_slug`, `paid_amount`/`amount`, `capture_method`, …
- **Comportamento:** não confia no corpo. Reconfere com `payment_check` (`handle`, `order_nsu`, `transaction_nsu`, `slug`) e compara o valor. Resposta no contrato do Panel: sucesso → **200** `{"success":true,"message":null}`; qualquer falha → **400** `{"success":false,"message":"…"}` (a InfinitePay reenvia).
- **Idempotência:** o workflow **não grava nada**; 1, 2 ou 3 entregas do mesmo webhook repetem só a verificação, sem baixa, venda ou evento duplicado (coberto por teste unitário).
- **Limite (decisão pendente):** a venda ainda não existe no Ritmo quando o webhook chega (a `POS Invoice` nasce da fila do PDV, depois da confirmação). Nenhum registro existente do Ritmo guarda a cobrança nesse intervalo, e não criei estrutura nova. Consequência: o webhook confirma e responde, mas não "marca como pago" em lugar nenhum; a fonte do estado é a InfinitePay (WF-09). Se o PDV fechar após o pagamento, não há registro no Ritmo. Fechar isso exige decisão sua sobre onde gravar.
- **Curl (simula entrega; só passa com pagamento real confirmado):** `curl -sS -X POST "$HARMONIA/webhook/pagamentos/pdv/infinitepay-webhook" -H 'Content-Type: application/json' -d '{"order_nsu":"venda_…","transaction_nsu":"…","invoice_slug":"…","paid_amount":100}'`
- **Status:** `ESTRUTURALMENTE_PRONTO_AGUARDANDO_TESTE_REAL`

## WF-10 — `Synapse — Fiscal — Emitir NFC-e`
- **Webhook:** `POST /webhook/fiscal/emitir-nfce` · `10_fiscal_emitir_nfce.json`
- **Entrada:** `{"venda_op_id":"…"}` (o que o Painel envia).
- **Comportamento:** confirma a venda no Ritmo (`POS Invoice.synapse_op_id`) e responde 501 `{"status":"pendente","codigo":"PENDENTE_DEPENDENCIA_MECANISMO_FISCAL"}`; o Painel mantém `nfce.status='pendente'`. Nada é emitido/autorizado; sem certificado, XML ou assinatura. Há um nó HTTP **desabilitado e desconectado** marcando o ponto de encaixe.
- **Motivo:** o módulo `brazil_nf` é instalado no Ritmo, mas nenhum endpoint de emissão consta nos arquivos.
- **Curl:** `curl -sS -X POST "$HARMONIA/webhook/fiscal/emitir-nfce" -H 'Content-Type: application/json' -d '{"venda_op_id":"OP_REAL"}'`
- **Status:** `PENDENTE_DEPENDENCIA_MECANISMO_FISCAL` (não é PASS)

## WF-11 — `Synapse — Atendimento — Número WhatsApp`
- **Webhook:** `POST /webhook/atendimento/numero-whatsapp` · `11_atendimento_numero_whatsapp.json`
- **Entrada:** `{}` · **Saída:** `{"numero":"5521999999999"}` (dígitos, do inbox WhatsApp real).
- **Regra:** usa `CHATWOOT_WHATSAPP_INBOX_ID` só se for de fato um inbox WhatsApp; senão o único inbox WhatsApp; nenhum → 404 `PENDENTE_CONFIGURACAO_WHATSAPP`; vários sem preferência válida → 409. Sem fallback para número da Nomen.
- **Curl:** `curl -sS -X POST "$HARMONIA/webhook/atendimento/numero-whatsapp" -H 'Content-Type: application/json' -d '{}'`
- **Status:** `ESTRUTURALMENTE_PRONTO_AGUARDANDO_TESTE_REAL`

## WF-07 — CNPJ
`AGUARDANDO_ARQUIVO_EXISTENTE` — `fiscal_consultar_cnpj.json` não veio nos anexos; **nada foi duplicado**. Importar o existente e conferir `POST /webhook/fiscal/consultar-cnpj`. Correção da versão anterior deste documento: `bffConsultarCNPJ()` **não** é stub; o Panel já chama `fiscal/consultar-cnpj` pelo Harmonia. Falta só o workflow existente no pacote.

---

## Pendências e riscos (para o desenvolvedor principal)

1. **Pagamento PDV — persistência e `payment_check`.** (a) Se o `payment_check` exigir `transaction_nsu`/`slug` além de `order_nsu`, o WF-09 só os terá se alguém os guardar entre o webhook e a consulta; hoje nenhum registro existente do Ritmo serve (ver WF-12). Teste real decisivo: chamar `payment_check` só com `handle`+`order_nsu`. (b) Risco residual: pagamento feito e PDV fechado antes da venda ser enfileirada.
2. **`CONFLITO_DE_CONTRATO` potencial — conversão de RAM/disco no Painel.** `calcularPercentualNetdata` trata `linha[1]` como *usado* e `linha[2]` como *livre*. Pela documentação do Netdata, `system.ram` costuma vir como `time, free, used, …` e `disk_space._` como `time, avail, used, …` (invertido). **Não alterei o formato** (a ordem proíbe); conferir `labels` no payload real do teste do WF-05. Conferir também se `disk_space._` existe no container `acorde` (só `/proc`, `/sys` montados, sem `/` do host).
3. **`CHATWOOT_WHATSAPP_INBOX_ID=1`** gravado pelo instalador tende a apontar para o webchat "Site Synapse" (inbox criado no provisionamento). O WF-11 já se protege, mas o valor está incoerente.
4. **WF-02:** o vínculo conversa→Customer por telefone é premissa minha (os arquivos não definem outro). Confirmar/ajustar.
5. **CORS/`$env`:** (a) o instalador não configura CORS no Harmonia; copiar o `allowedOrigins` do webhook do `fiscal_consultar_cnpj.json` existente (não incluí para não inventar origem). (b) n8n 2.x bloqueia `$env` em nós por padrão (`N8N_BLOCK_ENV_ACCESS_IN_NODE=true`); o `.env` do instalador não define isso. Se os workflows existentes já usam `$env`, está resolvido; senão, adicionar `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` ao `.env` do Harmonia.
6. **InfinitePay `webhook_url`:** resolvido nesta revisão (WF-12). Depende de `HARMONIA_DOMAIN` ser acessível pela InfinitePay (HTTPS público).
7. **Handle InfinitePay:** a origem do handle na credencial (`metadados.handle` ou `conta_conectada`) é premissa; o campo `nome_loja` do Painel pode não ser a InfiniteTag.
8. **Rede:** o Harmonia chama o Harpa por `CHATWOOT_DOMAIN` (URL pública). Os caminhos `/api/v1` estão liberados no Traefik.

## Ordem sugerida de teste real
WF-01 → 02 → 03 → 04 → 05 (3 charts) → 11 → 08 → 12 → 09 → (06 e 10 aguardam fonte/mecanismo).

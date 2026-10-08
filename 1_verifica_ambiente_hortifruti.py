#!/usr/bin/env python3
"""
Passo 1 — verificação SOMENTE LEITURA do ambiente REAL (Ritmo/ERPNext).
Nenhum mock, nenhuma escrita, nenhuma estrutura criada. Só GET.

Uso:
  export RITMO_URL=https://ritmo.<dominio>        # o Ritmo real
  export ERP_USUARIO=<usuario>  ERP_SENHA=<senha> # usuário com leitura de Item, Item Group, Bin e POS Profile
  python3 1_verifica_ambiente_hortifruti.py
Saída: relatorio_ambiente_hortifruti.json + resumo no terminal.
Resultado final: PRONTO_PARA_E2E ou PENDENCIA_AMBIENTE (resolver por script de preparação via Semaphore — NÃO pelo Panel).
"""
import json, os, sys, unicodedata, urllib.request, urllib.parse, http.cookiejar

RITMO = (os.environ.get('RITMO_URL') or '').rstrip('/')
USR, PWD = os.environ.get('ERP_USUARIO'), os.environ.get('ERP_SENHA')
RAIZ = os.environ.get('GRUPO_RAIZ', 'Hortifrúti')   # mesma constante do Panel (PDV_HF_GRUPO_RAIZ)
LIMITE_CATALOGO_PANEL = 500                          # limite do Ritmo.listar em pdvCarregarCatalogo
if not (RITMO and USR and PWD):
    sys.exit('ABORTADO: defina RITMO_URL, ERP_USUARIO e ERP_SENHA (ambiente real). Nada foi testado.')

norm = lambda s: ''.join(c for c in unicodedata.normalize('NFD', str(s or '')) if unicodedata.category(c) != 'Mn').strip().lower()
cj = http.cookiejar.CookieJar(); op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
def req(path, params=None, data=None):
    url = RITMO + path + ('?' + urllib.parse.urlencode(params) if params else '')
    body = urllib.parse.urlencode(data).encode() if data else None
    with op.open(urllib.request.Request(url, data=body, headers={'Accept': 'application/json'}), timeout=30) as r:
        return json.loads(r.read().decode())
def listar(doctype, fields, filters=None, limit=5000):
    p = {'fields': json.dumps(fields), 'limit_page_length': limit}
    if filters: p['filters'] = json.dumps(filters)
    return req('/api/resource/' + urllib.parse.quote(doctype), p)['data']

req('/api/method/login', data={'usr': USR, 'pwd': PWD})
checks = []; rel = {'ritmo': RITMO, 'grupo_raiz': RAIZ}
def chk(nome, ok, det=''):
    checks.append({'check': nome, 'resultado': 'PASS' if ok else 'FAIL', 'detalhe': det}); print(('PASS' if ok else 'FAIL'), nome, '—', det)

grupos = listar('Item Group', ['name', 'parent_item_group'])
raiz = next((g for g in grupos if norm(g['name']) == norm(RAIZ)), None)
chk('A1 Item Group raiz "%s" existe' % RAIZ, raiz is not None, raiz['name'] if raiz else 'não encontrado')
filhos = [g['name'] for g in grupos if raiz and norm(g.get('parent_item_group')) == norm(raiz['name'])]
chk('A2 existem grupos filhos diretos', len(filhos) > 0, filhos)
rel['grupos_filhos'] = filhos

def categoria_de(nome):
    atual, guarda = next((g for g in grupos if g['name'] == nome), None), 0
    while atual and guarda < 20:
        guarda += 1
        if raiz and atual['name'] == raiz['name']: return '__outras__'
        if raiz and norm(atual.get('parent_item_group')) == norm(raiz['name']): return atual['name']
        atual = next((g for g in grupos if g['name'] == atual.get('parent_item_group')), None)
    return None

itens = listar('Item', ['item_code', 'item_name', 'standard_rate', 'image', 'disabled', 'item_group', 'stock_uom'])
rel['total_items_no_ritmo'] = len(itens)
hf = [dict(i, categoria=categoria_de(i['item_group'])) for i in itens if categoria_de(i['item_group'])]
chk('A3 existem Items reais classificados no Hortifrúti', len(hf) > 0, '%d item(ns)' % len(hf))
por_cat = {}
for i in hf: por_cat.setdefault(i['categoria'], []).append(i)
rel['itens_por_categoria'] = {k: [{'item_code': i['item_code'], 'item_name': i['item_name'], 'standard_rate': i['standard_rate'], 'image': i['image'], 'disabled': i['disabled']} for i in v] for k, v in por_cat.items()}
chk('A4 item_code real presente em todos', all(i['item_code'] for i in hf), 'PLU numérico (rótulo "PLU" no Panel): %d de %d' % (sum(1 for i in hf if str(i['item_code']).isdigit() and len(str(i['item_code'])) <= 6), len(hf)))
chk('A5 imagem cadastrada (quando existente)', True, '%d de %d com Item.image' % (sum(1 for i in hf if i['image']), len(hf)))
chk('A6 preço (standard_rate) cadastrado', all((i['standard_rate'] or 0) > 0 for i in hf), '%d de %d com preço > 0' % (sum(1 for i in hf if (i['standard_rate'] or 0) > 0), len(hf)))
# estoque pelo MESMO depósito que o Panel usa (primeiro POS Profile)
try:
    pos = listar('POS Profile', ['name', 'warehouse'], limit=1)
    wh = pos[0]['warehouse'] if pos else None
    bins = listar('Bin', ['item_code', 'actual_qty'], [['warehouse', '=', wh]]) if wh else []
    saldo = {b['item_code']: b['actual_qty'] for b in bins}
    for i in hf: i['estoque'] = saldo.get(i['item_code'])
    chk('A7 estoque do depósito do POS Profile (quando existente)', True, 'depósito=%s; %d de %d com saldo registrado' % (wh, sum(1 for i in hf if i.get('estoque') is not None), len(hf)))
except Exception as e:
    chk('A7 estoque do depósito do POS Profile (quando existente)', False, str(e)[:150])
ativos = [i for i in hf if not i['disabled']]
# o Panel carrega só os 500 primeiros Items: se o total passar disso, itens do Hortifrúti podem ficar fora do catálogo local
chk('A8 catálogo do Panel (limite %d) comporta o Hortifrúti' % LIMITE_CATALOGO_PANEL, len(itens) <= LIMITE_CATALOGO_PANEL, 'total de Items no Ritmo=%d%s' % (len(itens), '' if len(itens) <= LIMITE_CATALOGO_PANEL else ' — ATENÇÃO: o Panel só carrega 500; risco de itens do Hortifrúti fora do catálogo local'))
# escolha de itens reais para o E2E (nenhum dado inventado)
cat_teste = next((c for c, v in por_cat.items() if any(not i['disabled'] and (i.get('estoque') is None or i['estoque'] > 0) for i in v)), None)
cand = [i for i in por_cat.get(cat_teste, []) if not i['disabled'] and (i.get('estoque') is None or i['estoque'] > 0)] if cat_teste else []
rel['alvo_e2e'] = {'categoria': cat_teste, 'produto_mouse': cand[0] if cand else None, 'produto_plu': (cand[1] if len(cand) > 1 else cand[0]) if cand else None}
criticos = [c for c in checks if c['check'][:2] in ('A1', 'A2', 'A3', 'A4') and c['resultado'] == 'FAIL']
rel['checks'] = checks
rel['veredito'] = 'PRONTO_PARA_E2E' if not criticos and cand else 'PENDENCIA_AMBIENTE'
if rel['veredito'] == 'PENDENCIA_AMBIENTE':
    rel['pendencia'] = ('A estrutura Hortifrúti não está completa no ERPNext (grupo raiz, filhos e Items classificados, com pelo menos um Item ativo e com estoque). '
                        'NÃO alterar o Panel: resolver por script independente de preparação do ambiente via Semaphore.')
json.dump(rel, open('relatorio_ambiente_hortifruti.json', 'w'), ensure_ascii=False, indent=2)
print('\nVEREDITO:', rel['veredito']); print(rel.get('pendencia', ''))

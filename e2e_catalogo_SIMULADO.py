#!/usr/bin/env python3
"""
Teste do catálogo do PDV com MAIS DE 500 Items. Executa o Panel REAL (o HTML) num Chromium.
ATENÇÃO — o backend é um Ritmo SIMULADO localmente (reproduz a semântica da API REST do Frappe: fields, filters,
limit_page_length, limit_start, order_by, ordem padrão 'modified desc'). Prova a lógica do Panel; NÃO é evidência do Ritmo real.
Uso: python3 e2e_catalogo.py <arquivo.html> <pasta_saida>
"""
import os, json, re, sys, time, threading, http.server, socketserver, functools, urllib.parse
from playwright.sync_api import sync_playwright

ARQ = sys.argv[1]; SAIDA = sys.argv[2]; PORT = 8780 + (hash(ARQ) % 50)
# ---------------- dataset: 1.205 Items; alvos de teste FORA do primeiro bloco de 500 ----------------
ITENS = {}   # item_code -> dict
def add(code, nome, grupo, preco, img, modified):
    ITENS[code] = {'item_code': code, 'item_name': nome, 'standard_rate': preco, 'custom_composicao': None, 'item_group': grupo, 'image': img, 'modified': modified}
add('0411', 'Tomate', 'Legumes', 9.9, None, 5000)          # dentro do 1º bloco (ordem name asc)
add('0450', 'Cenoura', 'Raízes', 6.5, None, 5000)
NF = int(os.environ.get('N_FILLER', '1200'))
for i in range(1, NF + 1): add('1%05d' % i, 'Produto Filler %04d' % i, 'Bebidas', 3.0 + i / 100, None, 3000 + i)   # '10001'..'11200'
add('90001', 'Abacate Hass', 'Frutas', 12.5, None, 100)      # name asc: depois dos 1200 fillers → posição > 1200
add('90002', 'Alho Nacional', 'Temperos', 30.0, None, 101)   # estoque ZERO, Bin também fora do 1º bloco de 1000
add('ZETA-700', 'Zeta Seiscentos', 'Bebidas', 77.0, None, 102)   # item "normal" fora do 1º bloco
ORDEM_NOME = sorted(ITENS)                                    # ordem 'name asc' do servidor
POS = {c: ORDEM_NOME.index(c) for c in ('0411', '0450', '90001', '90002', 'ZETA-700')}
GRUPOS = [('All Item Groups', None), ('Hortifrúti', 'All Item Groups'), ('Raízes', 'Hortifrúti'), ('Temperos', 'Hortifrúti'), ('Frutas', 'Hortifrúti'), ('Legumes', 'Hortifrúti'), ('Bebidas', 'All Item Groups')]
BIN = [{'name': 'BIN-%05d' % i, 'item_code': c, 'actual_qty': 0 if c == '90002' else 100, 'warehouse': 'Loja - T'} for i, c in enumerate(ORDEM_NOME)]
REQ = []

def lista(rows, q):
    fields = json.loads(q.get('fields', ['["name"]'])[0]); filt = json.loads(q.get('filters', ['[]'])[0])
    for f in filt:
        rows = [r for r in rows if str(r.get(f[0])) == str(f[2])] if f[1] == '=' else rows
    ob = q.get('order_by', ['modified desc'])[0].strip(); campo, _, sentido = ob.partition(' ')
    rows = sorted(rows, key=lambda r: (r.get(campo) if campo in r else r.get('name', '')), reverse=(sentido.strip().lower() == 'desc'))
    ini = int(q.get('limit_start', ['0'])[0]); n = int(q.get('limit_page_length', ['20'])[0])
    return [{k: r.get(k) for k in fields} for r in rows[ini:ini + n]]

def mock(route, request):
    u = urllib.parse.urlparse(request.url); path = urllib.parse.unquote(u.path); q = urllib.parse.parse_qs(u.query)
    cors = {'Access-Control-Allow-Origin': f'http://localhost:{PORT}', 'Access-Control-Allow-Credentials': 'true', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': '*'}
    if request.method == 'OPTIONS': return route.fulfill(status=204, headers=cors)
    j = lambda o: route.fulfill(status=200, headers={**cors, 'Content-Type': 'application/json'}, body=json.dumps(o))
    if path.endswith('synapse_csrf_token'): return j({'message': 'tok'})
    if path.endswith('get_logged_user'): return j({'message': 'op@loja.com'})
    if path.startswith('/api/resource/User/'): return j({'data': {'full_name': 'Operador', 'roles': [{'role': 'Synapse Administrador'}]}})
    if path == '/api/resource/Item':
        d = lista([dict(v, name=v['item_code']) for v in ITENS.values()], q); REQ.append(('Item', int(q.get('limit_start', ['0'])[0]), int(q.get('limit_page_length', ['20'])[0]), len(d))); return j({'data': d})
    if path == '/api/resource/Item Group': return j({'data': lista([{'name': n, 'parent_item_group': p, 'modified': 1} for n, p in GRUPOS], q)})
    if path == '/api/resource/POS Profile': return j({'data': [{'name': 'PDV1', 'warehouse': 'Loja - T', 'company': 'T', 'currency': 'BRL', 'selling_price_list': 'Std'}]})
    if path.startswith('/api/resource/POS Profile/'): return j({'data': {'payments': [{'mode_of_payment': 'Dinheiro'}]}})
    if path == '/api/resource/Bin':
        d = lista([dict(b, modified=0) for b in BIN], q); REQ.append(('Bin', int(q.get('limit_start', ['0'])[0]), int(q.get('limit_page_length', ['20'])[0]), len(d))); return j({'data': d})
    return j({'data': [], 'message': None})

class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(('127.0.0.1', PORT), functools.partial(H, directory='/home/claude/hf')); threading.Thread(target=srv.serve_forever, daemon=True).start()

R = []
def passo(n, desc, fn):
    try: ok, det = fn()
    except Exception as e: ok, det = False, 'EXCEÇÃO: ' + str(e).split('\n')[0][:160]
    R.append({'teste': n, 'descricao': desc, 'resultado': 'PASS' if ok else 'FAIL', 'detalhe': det}); print('PASS' if ok else 'FAIL', n, desc, '—', str(det)[:260], flush=True)

with sync_playwright() as p:
    b = p.chromium.launch(); ctx = b.new_context(viewport={'width': 1366, 'height': 768}); pg = ctx.new_page(); pg.set_default_timeout(20000 if NF > 5000 else 8000)
    erros = []; pg.on('pageerror', lambda e: erros.append(str(e)))
    ctx.route(re.compile(r'https://(ritmo|harmonia|harpa|acorde|eco)\.localhost/.*'), mock)
    pg.goto(f'http://localhost:{PORT}/{ARQ}')
    pg.wait_for_function("document.getElementById('app-shell').style.display==='flex'", timeout=20000)
    pg.click('.htab[data-page="pdv"]'); pg.wait_for_selector('#pdv-caixa-gate', state='visible'); pg.fill('#pdv-troco-inicial', '0')
    pg.click('text=Abrir caixa e começar a vender'); pg.wait_for_function("document.getElementById('pdv-operacao').style.display==='flex'")
    try: pg.wait_for_function("(n)=>pdvCatalogoCache.length >= n", arg=len(ITENS), timeout=(180000 if NF > 5000 else 15000))
    except Exception: pass
    cart = lambda: pg.evaluate("pdvCarrinho.map(i=>({c:i.item_code,n:i.nome,q:i.qtd,p:i.preco}))")
    total = pg.evaluate("pdvCatalogoCache.length")
    print(f'\n[{ARQ}] itens no servidor={len(ITENS)}; no catálogo local após abrir o PDV={total}; posições (name asc) dos alvos={POS}\n', flush=True)
    pg.evaluate("window.__sync=async()=>{const t=performance.now();await pdvCarregarCatalogo();return Math.round(performance.now()-t)};0")

    passo('L0', 'Alvos de teste estão FORA do primeiro bloco de 500 (posição ≥ 500 na ordem do servidor)', lambda: (all(POS[c] >= 500 for c in ('90001', '90002', 'ZETA-700')) and all(POS[c] < 500 for c in ('0411', '0450')), POS))
    passo('L1', 'Sincronização traz TODOS os Items (sem teto de 500) e pagina em blocos', lambda: (total == len(ITENS) and len([r for r in REQ if r[0] == 'Item' and r[3] > 0]) >= 3 and max(r[2] for r in REQ if r[0] == 'Item') <= 500, f'catálogo local={total}/{len(ITENS)}; blocos Item (limit_start,tam,retornou)={[r[1:] for r in REQ if r[0]=="Item"]}'))
    # 1) busca normal — item fora do 1º bloco
    def busca():
        pg.fill('#pdv-busca-produto', 'zeta seiscentos'); pg.wait_for_selector('#pdv-produto-grid .pdv-produto-card:has-text("Zeta Seiscentos")')
        pg.click('#pdv-produto-grid .pdv-produto-card:has-text("Zeta Seiscentos")'); pg.wait_for_function("pdvCarrinho.some(i=>i.item_code==='ZETA-700')")
        return cart() == [{'c': 'ZETA-700', 'n': 'Zeta Seiscentos', 'q': 1, 'p': 77}], cart()
    passo('L2', 'Busca normal por nome: Item fora do 1º bloco é encontrado e lançado no PDV', busca)
    # 2) PLU/código exato
    def plu():
        pg.fill('#pdv-busca-produto', '90001'); pg.press('#pdv-busca-produto', 'Enter'); pg.wait_for_function("pdvCarrinho.some(i=>i.item_code==='90001')")
        return any(i['c'] == '90001' and i['n'] == 'Abacate Hass' and i['q'] == 1 for i in cart()), cart()
    passo('L3', 'PLU/item_code exato + Enter: Item fora do 1º bloco é lançado', plu)
    # 3) Hortifrúti
    def hf():
        pg.click('#pdv-btn-hf'); pg.wait_for_selector('#pdv-hf.open')
        cats = set(pg.eval_on_selector_all('#pdv-hf-lista .pdv-hf-cat', 'e=>e.map(x=>x.dataset.cat)'))
        pg.click('#pdv-hf-lista .pdv-hf-cat[data-cat="Frutas"]'); pg.click('#pdv-hf-lista .pdv-hf-prod[data-codigo="90001"]'); pg.wait_for_function("pdvCarrinho.find(i=>i.item_code==='90001').qtd===2")
        pg.keyboard.press('Escape'); pg.focus('#pdv-hf-plu'); pg.keyboard.type('90001'); pg.keyboard.press('Enter'); pg.wait_for_function("pdvCarrinho.find(i=>i.item_code==='90001').qtd===3")
        pg.click('#pdv-hf-lista .pdv-hf-cat[data-cat="Temperos"]'); esg = pg.is_disabled('#pdv-hf-lista .pdv-hf-prod[data-codigo="90002"]')
        txt = pg.inner_text('#pdv-hf-lista .pdv-hf-prod[data-codigo="90002"]'); pg.keyboard.press('Escape')
        return {'Frutas', 'Temperos', 'Raízes', 'Legumes'} <= cats and esg and 'Esgotado' in txt, f'categorias={sorted(cats)}; Alho (Bin fora do 1º bloco de 1000): esgotado={esg}; carrinho 90001 qtd=3'
    passo('L4', 'Hortifrúti: categoria → produto fora do 1º bloco; PLU+Enter; estoque (Bin paginado) correto', hf)
    # 4) sincronização incremental de mudanças
    def resync():
        ITENS['ZETA-700']['standard_rate'] = 88.0; ITENS['90001']['standard_rate'] = 13.0; add('ZETA-NOVO', 'Zeta Novo', 'Bebidas', 5.0, None, 999)
        ms = pg.evaluate("window.__sync()"); pr = pg.evaluate("(async()=>({z:(await pdvGet('catalogo','ZETA-700')).preco,a:(await pdvGet('catalogo','90001')).preco,n:!!(await pdvGet('catalogo','ZETA-NOVO')),total:(await pdvTodos('catalogo')).length}))()")
        return pr == {'z': 88, 'a': 13, 'n': True, 'total': len(ITENS)}, f'{pr}; re-sync em {ms} ms'
    passo('L5', 'Sincronização: preço alterado e Item novo (fora do 1º bloco) chegam ao catálogo local, sem duplicar', resync)
    # 5) offline após sincronização
    def offline():
        pg.evaluate("pdvHfAberto && pdvHfFechar()")  # volta à grade normal de busca
        ctx.set_offline(True); pg.evaluate("window.dispatchEvent(new Event('offline'))")
        ms = pg.evaluate("window.__sync()")  # offline: usa a cópia local
        n = pg.evaluate("pdvCatalogoCache.length"); pg.fill('#pdv-busca-produto', 'zeta novo'); pg.wait_for_selector('#pdv-produto-grid .pdv-produto-card:has-text("Zeta Novo")')
        pg.click('#pdv-produto-grid .pdv-produto-card:has-text("Zeta Novo")'); pg.wait_for_function("pdvCarrinho.some(i=>i.item_code==='ZETA-NOVO')")
        pg.fill('#pdv-busca-produto', '90001'); pg.press('#pdv-busca-produto', 'Enter'); q = pg.evaluate("pdvCarrinho.find(i=>i.item_code==='90001').qtd")
        ctx.set_offline(False); return n == len(ITENS) and q == 4, f'offline: catálogo local={n}/{len(ITENS)}; Zeta Novo lançado; PLU 90001 qtd={q}'
    passo('L6', 'Offline após sincronizar: Items fora do 1º bloco continuam buscáveis e lançáveis', offline)
    # 6) item fora do 1º bloco (coberto + posição) e performance
    passo('L7', 'Itens usados nos testes L2–L6 estavam nas posições ≥ 500 do servidor', lambda: (all(POS[c] >= 500 for c in ('90001', '90002', 'ZETA-700')), POS))
    # 7) regressão
    def regressao():
        pg.keyboard.press('Escape'); pg.evaluate("pdvHfAberto && pdvHfFechar()")
        n = sum(i['q'] for i in cart()); pg.fill('#pdv-busca-produto', '0411'); pg.press('#pdv-busca-produto', 'Enter'); pg.wait_for_function("(n)=>pdvCarrinho.reduce((s,i)=>s+i.qtd,0)>n", arg=n)
        pg.click('text=Categorias >> nth=0'); pg.wait_for_selector('#modal-overlay.open'); pg.evaluate('fecharModal()')
        pg.keyboard.press('F2'); pg.wait_for_selector('#modal-overlay.open'); pg.evaluate('fecharModal()')
        pg.click('#pdv-btn-hf'); pg.wait_for_selector('#pdv-hf.open'); pg.click('#pdv-hf-lista .pdv-hf-cat[data-cat="Raízes"]'); pg.click('#pdv-hf-lista .pdv-hf-prod[data-codigo="0450"]')
        pg.wait_for_function("pdvCarrinho.some(i=>i.item_code==='0450')"); pg.evaluate("pdvHfFechar()")
        return True, 'bipe 0411, botão Categorias, F2 e Hortifrúti (item do 1º bloco) OK'
    passo('L8', 'Sem regressão no PDV: bipe, Categorias, F2, Hortifrúti com Item do 1º bloco', regressao)
    passo('L9', 'Nenhum erro de JavaScript durante todo o roteiro', lambda: (not erros, erros[:2]))
    b.close()
srv.shutdown()
json.dump({'arquivo': ARQ, 'backend': 'Ritmo SIMULADO (semântica Frappe) — NÃO é evidência do Ritmo real', 'itens_servidor': len(ITENS), 'blocos_item': [r[1:] for r in REQ if r[0] == 'Item'], 'resultados': R}, open(SAIDA, 'w'), ensure_ascii=False, indent=2)
print('\nRESUMO %s: %d PASS / %d FAIL' % (ARQ, sum(r['resultado'] == 'PASS' for r in R), sum(r['resultado'] == 'FAIL' for r in R)))

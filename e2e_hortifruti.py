import json, re, struct, zlib, threading, http.server, socketserver, functools, sys, urllib.parse
from playwright.sync_api import sync_playwright

PORT = 8772; ARQ = sys.argv[1] if len(sys.argv) > 1 else 'synapse_painel_18-09s.html'
EVID = '/mnt/user-data/outputs/evidencia_hortifruti/'
def png(r, g, b):
    raw = b''.join(b'\x00' + bytes([r, g, b]) * 8 for _ in range(8))
    def ch(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', 8, 8, 8, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b'')

# ---------- dados que o "Ritmo" devolve (mock só da camada HTTP) ----------
GRUPOS = [('All Item Groups', None), ('Hortifrúti', 'All Item Groups'), ('Raízes', 'Hortifrúti'), ('Temperos', 'Hortifrúti'), ('Frutas', 'Hortifrúti'),
          ('Legumes', 'Hortifrúti'), ('Hortaliças', 'Hortifrúti'), ('Folhas', 'Hortaliças'), ('Bebidas', 'All Item Groups')]
ITENS = [
  ('4050', 'Cenoura', 'Raízes', '/files/cenoura.png', 6.5), ('4090', 'Batata Doce', 'Raízes', None, 8.9), ('4140', 'Mandioca', 'Raízes', '/files/mandioca.png', 7.2),
  ('4120', 'Cebolinha', 'Temperos', '/files/cebolinha.png', 3.0), ('4011', 'Tomate', 'Legumes', '/files/tomate.png', 9.9),
  ('4130', 'Alface Crespa', 'Hortaliças', '/files/alface.png', 4.5), ('4150', 'Couve', 'Folhas', '/files/couve.png', 5.0),
  ('4160', 'Gengibre', 'Hortifrúti', '/files/gengibre.png', 22.0), ('4087', 'Banana Prata', 'Frutas', '/files/banana.png', 7.9),
  ('COLA2L', 'Refrigerante Cola 2L', 'Bebidas', '/files/cola.png', 10.0),
] + [('50%02d' % i, 'Fruta Teste %02d' % i, 'Frutas', '/files/fruta.png', 5.0 + i) for i in range(1, 31)]
REQ = []  # log de requisições ao Ritmo

def mock(route, request):
    u = urllib.parse.urlparse(request.url); path = urllib.parse.unquote(u.path); q = urllib.parse.parse_qs(u.query)
    cors = {'Access-Control-Allow-Origin': f'http://localhost:{PORT}', 'Access-Control-Allow-Credentials': 'true',
            'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': '*'}
    if request.method == 'OPTIONS': return route.fulfill(status=204, headers=cors)
    REQ.append((request.method, path, q))
    if path.startswith('/files/'):
        cor = (hash(path) % 200 + 40, 120, 80)
        return route.fulfill(status=200, headers={**cors, 'Content-Type': 'image/png'}, body=png(*cor))
    def j(o, st=200): return route.fulfill(status=st, headers={**cors, 'Content-Type': 'application/json'}, body=json.dumps(o))
    if path.endswith('synapse_csrf_token'): return j({'message': 'tok'})
    if path.endswith('get_logged_user'): return j({'message': 'op@loja.com'})
    if path.startswith('/api/resource/User/'): return j({'data': {'full_name': 'Operador Teste', 'roles': [{'role': 'Synapse Administrador'}]}})
    if path == '/api/resource/Item': return j({'data': [{'item_code': c, 'item_name': n, 'standard_rate': p, 'custom_composicao': None, 'item_group': g, 'image': im} for c, n, g, im, p in ITENS]})
    if path == '/api/resource/Item Group': return j({'data': [{'name': n, 'parent_item_group': p} for n, p in GRUPOS]})
    if path == '/api/resource/POS Profile': return j({'data': [{'name': 'PDV1', 'warehouse': 'Loja - T', 'company': 'T', 'currency': 'BRL', 'selling_price_list': 'Std'}]})
    if path.startswith('/api/resource/POS Profile/'): return j({'data': {'payments': [{'mode_of_payment': 'Dinheiro'}]}})
    if path == '/api/resource/Bin': return j({'data': [{'item_code': c, 'actual_qty': 0 if c == '4140' else 100} for c, *_ in ITENS]})
    return j({'data': [], 'message': None})

class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(('127.0.0.1', PORT), functools.partial(Q, directory='/home/claude/hf')); srv.allow_reuse_address = True
threading.Thread(target=srv.serve_forever, daemon=True).start()

R = []  # resultados
def teste(n, titulo, cond, det=''):
    R.append((n, titulo, bool(cond), det)); print(('PASS' if cond else 'FAIL'), f'T{n}', titulo, ('— ' + str(det)) if det else '', flush=True)

with sync_playwright() as p:
    b = p.chromium.launch(); ctx = b.new_context(viewport={'width': 1366, 'height': 768}); pg = ctx.new_page()
    erros = []; pg.on('pageerror', lambda e: erros.append(str(e)))
    ctx.route(re.compile(r'https://(ritmo|harmonia|harpa|acorde|eco)\.localhost/.*'), mock)
    pg.goto(f'http://localhost:{PORT}/{ARQ}')
    pg.wait_for_function("document.getElementById('app-shell').style.display==='flex'", timeout=20000)
    pg.click('.htab[data-page="pdv"]')
    pg.wait_for_selector('#pdv-caixa-gate', state='visible', timeout=10000)
    pg.fill('#pdv-troco-inicial', '0'); pg.click('text=Abrir caixa e começar a vender')
    pg.wait_for_function("document.getElementById('pdv-operacao').style.display==='flex'", timeout=10000)
    pg.wait_for_function("pdvCatalogoCache.length >= 40", timeout=15000)
    pg.evaluate("window.__lanc=[]; const o=window.adicionarAoCarrinhoPDVPorCodigo; window.adicionarAoCarrinhoPDVPorCodigo=function(c,q){window.__lanc.push(c);return o.apply(this,arguments)};0")
    cart = lambda: pg.evaluate("pdvCarrinho.map(i=>({c:i.item_code,n:i.nome,q:i.qtd}))")

    # --- T1 abrir
    pg.click('#pdv-btn-hf'); pg.wait_for_selector('#pdv-hf.open', timeout=5000)
    teste(1, 'Abrir Hortifrúti/Pesáveis (botão de acesso rápido)', pg.is_visible('#pdv-hf') and 'Hortifrúti' in pg.inner_text('#pdv-hf-titulo') and not pg.is_visible('#pdv-produto-grid'))
    # --- T2 categorias sem rolagem
    tiles = pg.eval_on_selector_all('#pdv-hf-lista .pdv-hf-cat', 'els=>els.map(e=>({t:e.firstChild.nodeType===3?e.childNodes[e.childNodes.length-2].textContent:e.textContent,r:e.getBoundingClientRect().toJSON()}))')
    nomes = pg.eval_on_selector_all('#pdv-hf-lista .pdv-hf-cat', 'els=>els.map(e=>e.dataset.cat)')
    dentro = all(t['r']['bottom'] <= 768 and t['r']['right'] <= 1366 and t['r']['top'] >= 0 for t in tiles)
    sem_scroll = pg.evaluate("(()=>{const e=document.getElementById('pdv-hf');return e.scrollHeight<=e.clientHeight+1})()")
    esperado = {'Raízes', 'Temperos', 'Frutas', 'Legumes', 'Hortaliças', '__outras__'}
    teste(2, 'Categorias visíveis sem rolagem (e sem categorias de fora do Hortifrúti)', set(nomes) == esperado and dentro and sem_scroll, f'categorias={nomes}; dentro_da_tela={dentro}; sem_rolagem={sem_scroll}')
    pg.screenshot(path=EVID + '01_categorias.png')
    # --- T3 selecionar categoria por TECLADO (Tab → setas → Enter)
    pg.focus('#pdv-hf-plu'); pg.keyboard.press('Tab')
    foco0 = pg.evaluate("document.activeElement.dataset.cat||document.activeElement.id")
    ordem = nomes
    alvo = ordem.index('Raízes'); [pg.keyboard.press('ArrowRight') for _ in range(alvo)]
    foco1 = pg.evaluate("document.activeElement.dataset.cat"); pg.keyboard.press('Enter')
    pg.wait_for_selector('#pdv-hf-lista .pdv-hf-prod', timeout=5000)
    teste(3, 'Selecionar categoria por teclado (Tab/setas/Enter)', foco1 == 'Raízes' and 'Raízes' in pg.inner_text('#pdv-hf-titulo'), f'foco inicial={foco0}, foco ao dar Enter={foco1}')
    # --- T4 produtos da categoria com foto, nome, PLU
    prods = pg.eval_on_selector_all('#pdv-hf-lista .pdv-hf-prod', """els=>els.map(e=>({cod:e.dataset.codigo,nome:e.querySelector('.pdv-hf-nome').textContent,plu:e.innerText,
        img:!!e.querySelector('img.pdv-hf-foto'),carregou:e.querySelector('img.pdv-hf-foto')?e.querySelector('img.pdv-hf-foto').naturalWidth>0:false,sem:!!e.querySelector('.semfoto')}))""")
    por = {x['cod']: x for x in prods}
    ok4 = set(por) == {'4050', '4090', '4140'} and por['4050']['img'] and por['4050']['carregou'] and 'PLU 4050' in por['4050']['plu'] and por['4090']['sem'] and 'PLU 4090' in por['4090']['plu'] and 'Esgotado' in por['4140']['plu']
    teste(4, 'Produtos da categoria com foto (carregada), nome e PLU; sem foto → iniciais; esgotado marcado', ok4, json.dumps(prods, ensure_ascii=False))
    pg.screenshot(path=EVID + '02_produtos_raizes.png')
    # --- T5/T6 selecionar pela IMAGEM (mouse) e conferir lançamento no PDV
    antes = cart(); pg.click('#pdv-hf-lista .pdv-hf-prod[data-codigo="4050"] img.pdv-hf-foto')
    pg.wait_for_function("pdvCarrinho.some(i=>i.item_code==='4050')")
    depois = cart()
    teste(5, 'Selecionar produto pela imagem (mouse)', pg.evaluate("window.__lanc.slice()") == ['4050'])
    teste(6, 'Produto correto lançado no PDV (Cenoura, qtd 1, preço do Ritmo) e visível no carrinho', depois == [{'c': '4050', 'n': 'Cenoura', 'q': 1}] and 'Cenoura' in pg.inner_text('#pdv-cart-list') and '6,50' in pg.inner_text('#pdv-cart-list'), f'carrinho={depois}')
    # esgotado não lança
    pg.evaluate("document.querySelector('#pdv-hf-lista .pdv-hf-prod[data-codigo=\"4140\"]').click()")
    teste('6b', 'Produto esgotado não é lançado', not any(i['c'] == '4140' for i in cart()) and pg.is_disabled('#pdv-hf-lista .pdv-hf-prod[data-codigo="4140"]'))
    # --- T7/T8 PLU + Enter
    pg.keyboard.press('Escape'); pg.wait_for_selector('#pdv-hf-lista .pdv-hf-cat'); voltou = 'Hortifrúti / Pesáveis' == pg.inner_text('#pdv-hf-titulo')
    pg.focus('#pdv-hf-plu'); pg.keyboard.type('4087'); pg.keyboard.press('Enter')
    pg.wait_for_function("pdvCarrinho.some(i=>i.item_code==='4087')")
    c = cart(); b87 = [i for i in c if i['c'] == '4087']
    teste(7, 'Esc volta às categorias; PLU digitado + Enter', voltou and pg.input_value('#pdv-hf-plu') == '' and 'Banana Prata' in pg.inner_text('#pdv-hf-ultimo'))
    teste(8, 'Mesmo produto correto lançado pelo PLU (Banana Prata, qtd 1), cenoura intacta', b87 == [{'c': '4087', 'n': 'Banana Prata', 'q': 1}] and any(i['c'] == '4050' and i['q'] == 1 for i in c), f'carrinho={c}')
    # PLU inexistente não lança nada
    n0 = len(cart()); pg.keyboard.type('9999'); pg.keyboard.press('Enter')
    teste('8b', 'PLU inexistente avisa e não lança nada', len(cart()) == n0 and 'não encontrado' in pg.inner_text('#pdv-hf-ultimo'))
    pg.fill('#pdv-hf-plu', '')
    pg.screenshot(path=EVID + '03_carrinho_apos_mouse_e_plu.png')
    # --- T9 visão indisponível (+ offline real do navegador)
    pg.evaluate("pdvVisaoMarcarIndisponivel('timeout da identificação')")
    aviso = pg.inner_text('#pdv-hf-aviso'); off = 'off' in (pg.get_attribute('#pdv-hf-aviso', 'class') or '')
    teste(9, 'Indisponibilidade da visão sinalizada ao operador, sem bloquear a tela', off and 'indisponível' in aviso and pg.is_visible('#pdv-hf-plu'), aviso)
    ctx.set_offline(True); pg.evaluate("window.dispatchEvent(new Event('offline'))")
    # --- T10 operador segue registrando: fallback, offline, visão fora
    pg.keyboard.press('Escape'); pg.wait_for_function("!document.getElementById('pdv-hf').classList.contains('open')")
    pg.keyboard.press('F3'); pg.wait_for_selector('#pdv-hf.open')
    pg.click('#pdv-hf-lista .pdv-hf-cat[data-cat="Frutas"]'); pg.wait_for_selector('#pdv-hf-lista .pdv-hf-prod')
    area = pg.evaluate("(()=>{const a=document.getElementById('pdv-hf-lista');const r=a.getBoundingClientRect();const t=[...a.querySelectorAll('.pdv-hf-prod')].map(e=>e.getBoundingClientRect());return {sh:a.scrollHeight,ch:a.clientHeight,n:t.length,todos:t.every(x=>x.top>=r.top-1&&x.bottom<=r.bottom+1)}})()")
    pager = pg.inner_text('#pdv-hf-pager'); pg.screenshot(path=EVID + '04_frutas_offline_visao_indisponivel.png')
    cod1 = pg.get_attribute('#pdv-hf-lista .pdv-hf-prod >> nth=0', 'data-codigo'); pg.click('#pdv-hf-lista .pdv-hf-prod >> nth=0')
    pg.keyboard.press('PageDown'); pg.wait_for_function("document.getElementById('pdv-hf-pager').innerText.includes('Página 2')")
    cod2 = pg.get_attribute('#pdv-hf-lista .pdv-hf-prod >> nth=0', 'data-codigo'); pg.keyboard.press('Alt+1')
    pg.wait_for_function("(c)=>pdvCarrinho.some(i=>i.item_code===c)", arg=cod2)
    pg.focus('#pdv-hf-plu'); pg.keyboard.type('4011'); pg.keyboard.press('Enter'); pg.wait_for_function("pdvCarrinho.some(i=>i.item_code==='4011')")
    cf = [i['c'] for i in cart()]
    teste(10, 'Offline + visão indisponível: produtos paginados sem rolagem; mouse, PgDn/Alt+1 e PLU continuam lançando', area['sh'] <= area['ch'] + 1 and area['todos'] and 'Página 1 de' in pager and cod1 in cf and cod2 in cf and cod1 != cod2 and '4011' in cf and [i['q'] for i in cart() if i['c'] == cod1][0] >= 1, f'área={area}; pager={pager}; lançados={cf}')
    ctx.set_offline(False)
    # --- T11 mecanismos reais existentes
    fl = pg.evaluate("window.__lanc.slice()")
    itemreq = [r for r in REQ if r[1] == '/api/resource/Item']; campos = itemreq[0][2].get('fields', [''])[0] if itemreq else ''
    grpreq = [r for r in REQ if r[1] == '/api/resource/Item Group']
    idb = pg.evaluate("""new Promise(res=>{const r=indexedDB.open(Object.keys({}).length?'':'synapse_pdv');r.onsuccess=()=>{}; indexedDB.databases().then(async ds=>{const out=[];for(const d of ds){await new Promise(ok=>{const q=indexedDB.open(d.name);q.onsuccess=()=>{const db=q.result;out.push({nome:d.name,versao:db.version,stores:[...db.objectStoreNames]});db.close();ok()}})}res(out)})})""")
    cat_local = pg.evaluate("(async()=>{const x=await pdvGet('catalogo','4050');const g=await pdvGet('config','grupos_item');return {imagem:x.imagem,grupos:(g.itens||[]).length}})()")
    escrita_nova = [r for r in REQ if r[0] in ('POST', 'PUT') and re.search(r'Item Group|plu|PLU|Hortif', r[1])]
    ok11 = ('image' in campos and 'item_group' in campos) and len(grpreq) >= 1 and len(fl) >= 5 and set(fl) >= {'4050', '4087', '4011'} and cat_local['imagem'] == '/files/cenoura.png' and cat_local['grupos'] == len(GRUPOS) and not escrita_nova \
           and len(idb) == 1 and sorted(idb[0]['stores']) == sorted(['catalogo', 'fila', 'caixa', 'clientes', 'config', 'composicoes', 'vendas_suspensas', 'vendedores'])
    teste(11, 'Usa os mecanismos existentes: Ritmo.listar(Item/Item Group), catálogo local, adicionarAoCarrinhoPDVPorCodigo; sem nova store/DocType/tabela de PLU', ok11, f'fields_Item={campos}; lançamentos={fl}; idb={idb}; local={cat_local}')
    # --- preservação (funcionalidades existentes)
    pg.keyboard.press('Escape'); pg.keyboard.press('Escape'); pg.wait_for_function("!document.getElementById('pdv-hf').classList.contains('open')")
    n1 = len(cart()); pg.fill('#pdv-busca-produto', '4130'); pg.press('#pdv-busca-produto', 'Enter')
    ok_bipe = pg.evaluate("pdvCarrinho.some(i=>i.item_code==='4130')") and len(cart()) == n1 + 1
    pg.click('text=Categorias >> nth=0'); pg.wait_for_selector('#modal-overlay.open', timeout=3000); ok_cat = pg.is_visible('#modal-overlay.open'); pg.evaluate('fecharModal()')
    pg.keyboard.press('F2'); pg.wait_for_selector('#modal-overlay.open', timeout=3000); ok_f2 = True; pg.evaluate('fecharModal()')
    pg.click('#pdv-produto-grid .pdv-produto-card >> nth=0'); ok_grid = pg.is_visible('#pdv-produto-grid') and len(cart()) >= n1 + 1
    teste('12', 'Preservação: bipe por código + Enter, botão Categorias, F2 e grade original continuam funcionando', ok_bipe and ok_cat and ok_f2 and ok_grid)
    err_hf = [e for e in erros if 'pdvHf' in e or 'pdvVisao' in e]
    teste('13', 'Nenhum erro de JavaScript na página durante todo o roteiro', not erros, erros[:3])
    b.close()
srv.shutdown()
json.dump([{'teste': n, 'descricao': t, 'resultado': 'PASS' if ok else 'FAIL', 'detalhe': d} for n, t, ok, d in R], open(EVID + 'resultado_testes.json', 'w'), ensure_ascii=False, indent=2)
print('\nRESUMO:', sum(1 for r in R if r[2]), 'PASS /', sum(1 for r in R if not r[2]), 'FAIL')

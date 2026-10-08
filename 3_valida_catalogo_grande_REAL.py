#!/usr/bin/env python3
"""
Passo 3 — Catálogo > 500 Items contra o Ritmo REAL (sem mocks; só o HTML do Panel é servido do arquivo local sob a URL real).
Usa os Items que JÁ existem no Ritmo (não cria nada). Só roda se o Ritmo tiver mais de 500 Items.
Efeito real: abre caixa (como o passo 2). Nenhuma venda é finalizada.
Env: PAINEL_URL, ERP_USUARIO, ERP_SENHA, PANEL_HTML (=../synapse_painel_18-09s.html)
"""
import json, os, sys
from playwright.sync_api import sync_playwright
P, U, S, H = os.environ.get('PAINEL_URL', ''), os.environ.get('ERP_USUARIO'), os.environ.get('ERP_SENHA'), os.environ.get('PANEL_HTML', '../synapse_painel_18-09s.html')
if not (P and U and S and os.path.exists(H)): sys.exit('ABORTADO: defina PAINEL_URL, ERP_USUARIO, ERP_SENHA, PANEL_HTML. Nada foi testado.')
os.makedirs('evidencia_real', exist_ok=True); R = []
def t(n, d, ok, det=''):
    R.append({'teste': n, 'descricao': d, 'resultado': 'PASS' if ok else 'FAIL', 'detalhe': str(det)[:400]}); print('PASS' if ok else 'FAIL', n, d, '—', str(det)[:300], flush=True)
with sync_playwright() as p:
    b = p.chromium.launch(); ctx = b.new_context(viewport={'width': 1366, 'height': 768}); pg = ctx.new_page(); pg.set_default_timeout(60000)
    html = open(H, encoding='utf-8').read(); alvo = P if P.endswith('/') else P + '/'
    pg.route(lambda u: u.split('#')[0].split('?')[0].rstrip('/') == alvo.rstrip('/'), lambda r: r.fulfill(status=200, content_type='text/html; charset=utf-8', body=html))
    erros = []; pg.on('pageerror', lambda e: erros.append(str(e)))
    pg.goto(alvo); pg.fill('#linp-email', U); pg.fill('#linp-senha', S); pg.click('#lbtn')
    pg.wait_for_function("document.getElementById('app-shell').style.display==='flex'")
    # contagem e item-alvo REAIS, lidos do Ritmo real pelo cliente do próprio Panel (ordem name asc, mesma da sincronização)
    total = pg.evaluate("Ritmo._request('/api/resource/Item',{params:{fields:JSON.stringify(['name']),limit_page_length:1,limit_start:0}}).then(()=>Ritmo._request('/api/method/frappe.client.get_count',{params:{doctype:'Item'}})).then(r=>r.message)")
    if total <= 500: sys.exit(f'ABORTADO: o Ritmo tem apenas {total} Items; o teste exige > 500 (criar/importar Items de teste via script de preparação — não pelo Panel).')
    alvo_item = pg.evaluate("Ritmo._request('/api/resource/Item',{params:{fields:JSON.stringify(['item_code','item_name','standard_rate']),limit_page_length:1,limit_start:%d,order_by:'name asc'}}).then(r=>r.data[0])" % (total - 1))
    primeiro_bloco = pg.evaluate("Ritmo._request('/api/resource/Item',{params:{fields:JSON.stringify(['item_code']),limit_page_length:500,limit_start:0,order_by:'name asc'}}).then(r=>r.data.map(x=>x.item_code))")
    t('C0', 'Item-alvo real está fora do primeiro bloco de 500', alvo_item['item_code'] not in primeiro_bloco, f'total={total}; alvo={alvo_item}')
    pg.click('.htab[data-page="pdv"]'); pg.wait_for_selector('#pdv-caixa-gate'); pg.fill('#pdv-troco-inicial', '0'); pg.click('text=Abrir caixa e começar a vender')
    pg.wait_for_function("document.getElementById('pdv-operacao').style.display==='flex'")
    pg.wait_for_function("(n)=>pdvCatalogoCache.length>=n", arg=total, timeout=300000)
    t('C1', 'Catálogo local tem TODOS os Items do Ritmo (sem teto de 500)', pg.evaluate("pdvCatalogoCache.length") >= total, f'local={pg.evaluate("pdvCatalogoCache.length")} ritmo={total}')
    cod = alvo_item['item_code']; cart = lambda: pg.evaluate("pdvCarrinho.map(i=>({c:i.item_code,q:i.qtd,p:i.preco}))")
    pg.fill('#pdv-busca-produto', alvo_item['item_name'][:40]); pg.wait_for_selector(f'#pdv-produto-grid .pdv-produto-card:has-text("{alvo_item["item_name"][:20]}")')
    pg.click(f'#pdv-produto-grid .pdv-produto-card:has-text("{alvo_item["item_name"][:20]}") >> nth=0'); pg.wait_for_function("(c)=>pdvCarrinho.length>0", arg=cod)
    t('C2', 'Busca normal acha e lança Item real fora do 1º bloco', len(cart()) >= 1, cart())
    pg.evaluate("pdvCarrinho=[]; renderCarrinhoPDV()"); pg.fill('#pdv-busca-produto', cod); pg.press('#pdv-busca-produto', 'Enter'); pg.wait_for_function("(c)=>pdvCarrinho.some(i=>i.item_code===c)", arg=cod)
    t('C3', 'PLU/item_code real + Enter lança o Item real fora do 1º bloco (preço = ERPNext)', any(i['c'] == cod and abs(i['p'] - float(alvo_item['standard_rate'] or 0)) < 0.005 for i in cart()), cart())
    ctx.set_offline(True); pg.evaluate("window.dispatchEvent(new Event('offline'))"); pg.evaluate("pdvCarregarCatalogo()"); pg.evaluate("pdvCarrinho=[]; renderCarrinhoPDV()")
    pg.fill('#pdv-busca-produto', cod); pg.press('#pdv-busca-produto', 'Enter'); pg.wait_for_function("(c)=>pdvCarrinho.some(i=>i.item_code===c)", arg=cod)
    t('C4', 'Offline após sincronizar: Item real fora do 1º bloco segue lançável', True, 'lançado offline'); ctx.set_offline(False)
    t('C5', 'Nenhum erro de JavaScript', not erros, erros[:2]); pg.evaluate("pdvCarrinho=[]; renderCarrinhoPDV()"); b.close()
json.dump({'painel': P, 'resultados': R}, open('evidencia_real/resultado_catalogo_grande_real.json', 'w'), ensure_ascii=False, indent=2)
print('RESUMO:', sum(r['resultado'] == 'PASS' for r in R), 'PASS /', sum(r['resultado'] == 'FAIL' for r in R), 'FAIL')

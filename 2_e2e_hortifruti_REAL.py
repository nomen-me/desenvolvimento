#!/usr/bin/env python3
"""
Passo 2 — E2E do Hortifrúti contra o Ritmo/Harmonia REAIS, dirigindo o Panel 18-09s num navegador de verdade.
SEM MOCK: nenhuma rota de API é interceptada. A ÚNICA substituição é o documento HTML do Panel (servido do arquivo
local sob a URL real do painel, para o navegador ter a origem/CORS/cookies reais). Todo o resto vai para a rede real.

ATENÇÃO — efeito real: o PDV exige caixa aberto; abrir o caixa enfileira e sincroniza uma abertura de caixa NO RITMO.
Nenhuma venda é finalizada (o carrinho é descartado). Rode em homologação, ou defina FECHAR_CAIXA=1 p/ fechar ao final.

Uso:
  pip install playwright && playwright install chromium
  export PAINEL_URL=https://painel.<dominio>/     # URL real do painel (define o Ritmo real pelo hostname)
  export ERP_USUARIO=...  ERP_SENHA=...           # usuário real com acesso à Frente de Loja
  export PANEL_HTML=../synapse_painel_18-09s.html
  # opcional: VISAO_URL_GLOB='**/visao/**'  → bloqueia o serviço de IA de visão (falha real do serviço)
  # opcional: FECHAR_CAIXA=1   |  GRUPO_RAIZ_ESPERADO (já vem do relatório do passo 1)
  python3 2_e2e_hortifruti_REAL.py
Pré-requisito: rodar o passo 1 (relatorio_ambiente_hortifruti.json) com veredito PRONTO_PARA_E2E.
"""
import json, os, sys, re
from playwright.sync_api import sync_playwright

PAINEL = os.environ.get('PAINEL_URL', ''); USR = os.environ.get('ERP_USUARIO'); PWD = os.environ.get('ERP_SENHA')
HTML = os.environ.get('PANEL_HTML', '../synapse_painel_18-09s.html'); VISAO = os.environ.get('VISAO_URL_GLOB')
if not (PAINEL and USR and PWD and os.path.exists(HTML) and os.path.exists('relatorio_ambiente_hortifruti.json')):
    sys.exit('ABORTADO: defina PAINEL_URL, ERP_USUARIO, ERP_SENHA, PANEL_HTML e rode antes o passo 1. Nada foi testado.')
rel = json.load(open('relatorio_ambiente_hortifruti.json'))
if rel.get('veredito') != 'PRONTO_PARA_E2E': sys.exit('ABORTADO: ambiente não está PRONTO_PARA_E2E — ver pendência no relatório do passo 1.')
alvo = rel['alvo_e2e']; cat, prod_m, prod_p = alvo['categoria'], alvo['produto_mouse'], alvo['produto_plu']
esperadas = set(rel['itens_por_categoria'].keys())
R = []; os.makedirs('evidencia_real', exist_ok=True)
def t(n, desc, ok, det=''):
    R.append({'teste': n, 'descricao': desc, 'resultado': 'PASS' if ok else 'FAIL', 'detalhe': det}); print(('PASS' if ok else 'FAIL'), n, desc, '—', str(det)[:300], flush=True)

with sync_playwright() as p:
    b = p.chromium.launch(); ctx = b.new_context(viewport={'width': 1366, 'height': 768}); pg = ctx.new_page()
    erros = []; pg.on('pageerror', lambda e: erros.append(str(e)))
    html = open(HTML, encoding='utf-8').read()
    alvo_url = PAINEL if PAINEL.endswith('/') or PAINEL.endswith('.html') else PAINEL + '/'
    pg.route(lambda u: u.split('#')[0].split('?')[0].rstrip('/') == alvo_url.rstrip('/') or u.split('?')[0] == alvo_url, lambda r: r.fulfill(status=200, content_type='text/html; charset=utf-8', body=html))
    visao_falha = {'on': False}  # o serviço de IA só é derrubado na fase R6 (falha do serviço, não do navegador)
    if VISAO: pg.route(VISAO, lambda r: r.abort('failed') if visao_falha['on'] else r.continue_())
    pg.goto(alvo_url)
    pg.fill('#linp-email', USR); pg.fill('#linp-senha', PWD); pg.click('#lbtn')
    pg.wait_for_function("document.getElementById('app-shell').style.display==='flex'", timeout=30000)
    pg.click('.htab[data-page="pdv"]'); pg.wait_for_selector('#pdv-caixa-gate', state='visible', timeout=15000)
    pg.fill('#pdv-troco-inicial', '0'); pg.click('text=Abrir caixa e começar a vender')
    pg.wait_for_function("document.getElementById('pdv-operacao').style.display==='flex'", timeout=15000)
    pg.wait_for_function("pdvCatalogoCache.length > 0", timeout=30000)
    cart = lambda: pg.evaluate("pdvCarrinho.map(i=>({c:i.item_code,n:i.nome,q:i.qtd,p:i.preco}))")
    erp = lambda code: pg.evaluate("(c)=>Ritmo.obter(SYNAPSE_CONFIG.doctypes.produto, c).then(r=>r.data)", code)  # leitura REAL do Item pelo cliente do próprio Panel

    pg.click('#pdv-btn-hf'); pg.wait_for_selector('#pdv-hf.open')
    cats = set(pg.eval_on_selector_all('#pdv-hf-lista .pdv-hf-cat', 'els=>els.map(e=>e.dataset.cat)'))
    t('R1', 'Abrir Hortifrúti e exibir as categorias reais (mesmas do ERPNext, vistas no passo 1)', cats == esperadas, f'tela={sorted(cats)} erpnext={sorted(esperadas)}')
    pg.screenshot(path='evidencia_real/01_categorias_reais.png')
    pg.click(f'#pdv-hf-lista .pdv-hf-cat[data-cat="{cat}"]'); pg.wait_for_selector('#pdv-hf-lista .pdv-hf-prod')
    codigos = set(pg.eval_on_selector_all('#pdv-hf-lista .pdv-hf-prod', 'els=>els.map(e=>e.dataset.codigo)'))
    reais = {i['item_code'] for i in rel['itens_por_categoria'][cat]}
    t('R2', 'Categoria real selecionada mostra os Items reais dela', codigos <= reais and prod_m['item_code'] in codigos, f'categoria={cat}; na tela={sorted(codigos)}')
    foto = pg.evaluate("(c)=>{const i=document.querySelector(`#pdv-hf-lista .pdv-hf-prod[data-codigo=\"${c}\"] img.pdv-hf-foto`);return i?i.naturalWidth>0:null}", prod_m['item_code'])
    t('R3', 'Imagem real do Item carregada (ou iniciais se o Item não tem imagem)', (foto is True) if prod_m['image'] else (foto is None), f'Item.image={prod_m["image"]}; carregou={foto}')
    pg.screenshot(path='evidencia_real/02_produtos_reais.png')
    sel = f'#pdv-hf-lista .pdv-hf-prod[data-codigo="{prod_m["item_code"]}"]'
    pg.click(sel + (' img.pdv-hf-foto' if prod_m['image'] else ''))
    pg.wait_for_function("(c)=>pdvCarrinho.some(i=>i.item_code===c)", arg=prod_m['item_code'])
    c1 = cart(); doc = erp(prod_m['item_code'])
    t('R4', 'Produto real escolhido pela imagem entra no carrinho; nome/preço batem com o Item no ERPNext', len(c1) == 1 and c1[0]['c'] == doc['item_code'] and abs(c1[0]['p'] - float(doc['standard_rate'] or 0)) < 0.005 and c1[0]['q'] == 1, f'carrinho={c1}; ERPNext={doc["item_code"]}/{doc["item_name"]}/{doc["standard_rate"]}')
    pg.keyboard.press('Escape'); pg.focus('#pdv-hf-plu'); pg.keyboard.type(str(prod_p['item_code'])); pg.keyboard.press('Enter')
    pg.wait_for_function("(c)=>pdvCarrinho.some(i=>i.item_code===c)", arg=prod_p['item_code'])
    c2 = cart(); doc2 = erp(prod_p['item_code'])
    t('R5', 'item_code/PLU real + Enter lança o mesmo Item real (confere com o ERPNext)', any(i['c'] == doc2['item_code'] for i in c2) and doc2['item_code'] == prod_p['item_code'], f'PLU={prod_p["item_code"]}; carrinho={c2}')
    pg.screenshot(path='evidencia_real/03_carrinho_real.png')
    # falha do SERVIÇO DE IA (não é "navegador offline"): a rota do serviço é abortada e o estado é sinalizado
    visao_falha['on'] = True
    pg.evaluate("pdvVisaoMarcarIndisponivel('falha do serviço de IA')")
    if VISAO: pg.evaluate("(u)=>fetch(u.replace('**',''),{mode:'no-cors'}).catch(()=>0)", VISAO.replace('**', 'ping'))
    pg.keyboard.press('Escape'); pg.wait_for_function("!document.getElementById('pdv-hf').classList.contains('open')") if pg.evaluate("pdvHfCategoria===null") else None
    pg.keyboard.press('F3') if not pg.evaluate("pdvHfAberto") else None
    pg.wait_for_selector('#pdv-hf.open'); pg.click(f'#pdv-hf-lista .pdv-hf-cat[data-cat="{cat}"]'); pg.wait_for_selector(sel)
    n0 = sum(i['q'] for i in cart()); pg.click(sel); pg.wait_for_function("(n)=>pdvCarrinho.reduce((s,i)=>s+i.qtd,0)>n", arg=n0)
    pg.focus('#pdv-hf-plu'); pg.keyboard.type(str(prod_p['item_code'])); pg.keyboard.press('Enter')
    pg.wait_for_function("(n)=>pdvCarrinho.reduce((s,i)=>s+i.qtd,0)>n+1", arg=n0)
    aviso = pg.inner_text('#pdv-hf-aviso')
    t('R6', 'Com o serviço de IA em falha o PDV segue operando: categoria→produto e PLU+Enter continuam lançando' + ('' if VISAO else ' [NÃO VALIDADO p/ IA real: sem VISAO_URL_GLOB, só o estado foi sinalizado]'),
      'indisponível' in aviso and sum(i['q'] for i in cart()) >= n0 + 2, aviso)
    # regressão causada por esta alteração
    pg.keyboard.press('Escape'); pg.keyboard.press('Escape'); pg.wait_for_function("!document.getElementById('pdv-hf').classList.contains('open')")
    pg.fill('#pdv-busca-produto', str(prod_m['item_code'])); n1 = sum(i['q'] for i in cart()); pg.press('#pdv-busca-produto', 'Enter')
    ok_bipe = sum(i['q'] for i in cart()) == n1 + 1
    pg.click('text=Categorias >> nth=0'); pg.wait_for_selector('#modal-overlay.open'); pg.evaluate('fecharModal()')
    t('R7', 'Sem regressão: bipe por código + Enter e botão Categorias originais continuam funcionando', ok_bipe)
    t('R8', 'Nenhum erro de JavaScript durante o roteiro', not erros, erros[:3])
    pg.evaluate("pdvCarrinho=[]; renderCarrinhoPDV()")  # descarta o carrinho: nenhuma venda é finalizada
    if os.environ.get('FECHAR_CAIXA') == '1':
        pg.once('dialog', lambda d: d.accept()); pg.click('#pdv-btn-fechar-caixa')
    b.close()
json.dump({'painel': PAINEL, 'resultados': R}, open('evidencia_real/resultado_e2e_real.json', 'w'), ensure_ascii=False, indent=2)
print('\nRESUMO:', sum(r['resultado'] == 'PASS' for r in R), 'PASS /', sum(r['resultado'] == 'FAIL' for r in R), 'FAIL')

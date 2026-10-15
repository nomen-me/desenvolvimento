// =============================================================================
// Harness de teste SIMULADO para o nó "Monta resposta" de 06_consumo_servicos.json.
// Executa o jsCode real extraído do workflow (code_Monta_resposta.js), com
// $node/$env mockados — não é execução contra um Ritmo/Lyra real (isso está
// documentado separadamente nos testes reais, seção 8). Objetivo aqui é
// provar, por execução de código e não por leitura visual, que a lógica
// produz exatamente o status/HTTP/corpo esperado em cada cenário exigido.
// =============================================================================
const fs = require('fs');
const assert = require('assert');

const codigoFonte = fs.readFileSync(__dirname + '/code_Monta_resposta.js', 'utf-8');

function rodar(nodeMocks, envMocks) {
  const $node = new Proxy({}, {
    get(_, nome) {
      if (!(nome in nodeMocks)) {
        // Simula o comportamento real do n8n: acessar um nó que não executou
        // nesta execução lança erro.
        throw new Error(`Nó '${String(nome)}' não executou nesta execução (sem dados).`);
      }
      return { json: nodeMocks[nome] };
    }
  });
  const $env = envMocks || {};
  // eslint-disable-next-line no-new-func
  const fn = new Function('$node', '$env', codigoFonte + '\nreturn arguments[2] !== undefined ? null : (typeof arguments[2]);');
  // jsCode do n8n termina com "return [...]" direto no corpo — envolve numa função.
  const wrapped = new Function('$node', '$env', codigoFonte);
  return wrapped($node, $env);
}

const cenarios = [];
function cenario(nome, fn) { cenarios.push({ nome, fn }); }

// ---------------------------------------------------------------------------
// Cenário 1 — Fontes disponíveis, consultas concluídas com dados (tudo OK)
// ---------------------------------------------------------------------------
cenario('1. Todas as fontes disponíveis com dados reais', () => {
  const hoje = new Date();
  const d1 = hoje.toISOString().slice(0, 10);
  const d2 = new Date(hoje.getTime() - 86400000).toISOString().slice(0, 10);
  const nodeMocks = {
    'Calcula período': { ok: true, inicioMes: hoje.toISOString().slice(0, 8) + '01', seteDiasAtras: d2, desde: d2, mesVigente: hoje.toISOString().slice(0, 7) },
    'Ritmo — Credenciais de envio': { data: [{ provedor: 'melhorenvio', status: 'conectado', saldo: '123.45', cache_atualizado_em: '2026-10-15 08:00:00' }] },
    'Ritmo — Fretes do período': { data: [
      { name: 'SINV-1', creation: d1 + ' 10:00:00', custom_tracking_code: 'BR123' },
      { name: 'SINV-2', creation: d1 + ' 11:00:00', custom_tracking_code: 'BR124' },
      { name: 'SINV-3', creation: d2 + ' 09:00:00', custom_tracking_code: 'BR125' }
    ] },
    'Lyra configurada? (checagem)': { lyraConfigurada: true },
    'Lyra — Consultar uso IA': { tenant_id: 'loja_abc', mes_vigente: hoje.toISOString().slice(0, 7), atendimentos_usados: 380, atendimentos_incluidos_plano: 500, status_cota: 'dentro_do_plano' }
  };
  const out = rodar(nodeMocks);
  assert.strictEqual(out[0].json.status, 200, 'HTTP esperado 200');
  assert.strictEqual(out[0].json.body.status, 'OK');
  assert.strictEqual(out[0].json.body.sucesso, true);
  assert.strictEqual(out[0].json.body.freteSaldo, '123.45');
  assert.strictEqual(out[0].json.body.freteVolume, 3);
  assert.ok(Array.isArray(out[0].json.body.ia) && out[0].json.body.ia.length === 1 && out[0].json.body.ia[0].v === 380);
  assert.ok(Array.isArray(out[0].json.body.frete) && out[0].json.body.frete.length === 2);
  assert.ok(!out[0].json.body.pendencias);
  return out[0].json;
});

// ---------------------------------------------------------------------------
// Cenário 2 — Consulta concluída sem registros (zero real, não pendência)
// ---------------------------------------------------------------------------
cenario('2. Consulta concluída, zero fretes no período (zero real)', () => {
  const hoje = new Date();
  const nodeMocks = {
    'Calcula período': { ok: true, inicioMes: hoje.toISOString().slice(0, 8) + '01', seteDiasAtras: new Date(hoje.getTime() - 7 * 86400000).toISOString().slice(0, 10), desde: new Date(hoje.getTime() - 7 * 86400000).toISOString().slice(0, 10), mesVigente: hoje.toISOString().slice(0, 7) },
    'Ritmo — Credenciais de envio': { data: [{ provedor: 'melhorenvio', status: 'conectado', saldo: '0.00', cache_atualizado_em: '2026-10-15 08:00:00' }] },
    'Ritmo — Fretes do período': { data: [] },
    'Lyra configurada? (checagem)': { lyraConfigurada: false, motivo: 'Lyra Central não configurada neste Harmonia — variáveis ausentes: LYRA_CENTRAL_URL.' }
  };
  const out = rodar(nodeMocks);
  assert.strictEqual(out[0].json.status, 200);
  assert.strictEqual(out[0].json.body.status, 'PARCIAL');
  assert.strictEqual(out[0].json.body.freteVolume, 0, 'zero real, não "indisponível"');
  assert.deepStrictEqual(out[0].json.body.frete, []);
  assert.ok(out[0].json.body.pendencias.some(p => p.campo === 'ia' && p.codigo === 'FONTE_NAO_CONFIGURADA'));
  return out[0].json;
});

// ---------------------------------------------------------------------------
// Cenário 3 — Um indicador disponível, outro sem fonte confirmada
// ---------------------------------------------------------------------------
cenario('3. freteSaldo disponível; ia sem fonte confirmada (stub da Lyra)', () => {
  const hoje = new Date();
  const nodeMocks = {
    'Calcula período': { ok: true, inicioMes: hoje.toISOString().slice(0, 8) + '01', seteDiasAtras: new Date(hoje.getTime() - 7 * 86400000).toISOString().slice(0, 10), desde: new Date(hoje.getTime() - 7 * 86400000).toISOString().slice(0, 10), mesVigente: hoje.toISOString().slice(0, 7) },
    'Ritmo — Credenciais de envio': { data: [{ provedor: 'melhorenvio', status: 'conectado', saldo: '50.00', cache_atualizado_em: '2026-10-15 08:00:00' }] },
    'Ritmo — Fretes do período': { error: { description: "pymysql.err.OperationalError: (1054, \"Unknown column 'tabSales Invoice.custom_tracking_code' in 'field list'\")", httpCode: 417 } },
    'Lyra configurada? (checagem)': { lyraConfigurada: true },
    'Lyra — Consultar uso IA': { tenant_id: 'loja_abc', mes_vigente: hoje.toISOString().slice(0, 7), atendimentos_usados: null, atendimentos_incluidos_plano: null, status_cota: 'nao_implementado' }
  };
  const out = rodar(nodeMocks);
  assert.strictEqual(out[0].json.status, 200);
  assert.strictEqual(out[0].json.body.status, 'PARCIAL');
  assert.strictEqual(out[0].json.body.freteSaldo, '50.00');
  assert.ok(out[0].json.body.pendencias.some(p => p.campo === 'frete' && p.codigo === 'FONTE_NAO_CONFIGURADA'));
  assert.ok(out[0].json.body.pendencias.some(p => p.campo === 'freteVolume' && p.codigo === 'FONTE_NAO_CONFIGURADA'));
  assert.ok(out[0].json.body.pendencias.some(p => p.campo === 'ia' && p.codigo === 'FONTE_NAO_IMPLEMENTADA'));
  return out[0].json;
});

// ---------------------------------------------------------------------------
// Cenário 4 — Falha de autenticação/permissão
// ---------------------------------------------------------------------------
cenario('4. Falha de autenticação (401) no Ritmo e na Lyra', () => {
  const hoje = new Date();
  const nodeMocks = {
    'Calcula período': { ok: true, inicioMes: hoje.toISOString().slice(0, 8) + '01', seteDiasAtras: new Date(hoje.getTime() - 7 * 86400000).toISOString().slice(0, 10), desde: new Date(hoje.getTime() - 7 * 86400000).toISOString().slice(0, 10), mesVigente: hoje.toISOString().slice(0, 7) },
    'Ritmo — Credenciais de envio': { error: { description: 'AuthenticationError', httpCode: 401 } },
    'Ritmo — Fretes do período': { error: { description: 'AuthenticationError', httpCode: 401 } },
    'Lyra configurada? (checagem)': { lyraConfigurada: true },
    'Lyra — Consultar uso IA': { error: { description: 'AUTH_INVALID', httpCode: 401 } }
  };
  const out = rodar(nodeMocks);
  assert.strictEqual(out[0].json.status, 502, 'todas as fontes falharam por autenticação => 502');
  assert.strictEqual(out[0].json.body.status, 'FALHA_COMUNICACAO');
  assert.ok(out[0].json.body.pendencias.every(p => p.codigo === 'FALHA_AUTENTICACAO'));
  return out[0].json;
});

// ---------------------------------------------------------------------------
// Cenário 5 — Indisponibilidade/erro genérico da fonte (timeout, 5xx)
// ---------------------------------------------------------------------------
cenario('5. Indisponibilidade da fonte (timeout / 503) — parcial, não total', () => {
  const hoje = new Date();
  const nodeMocks = {
    'Calcula período': { ok: true, inicioMes: hoje.toISOString().slice(0, 8) + '01', seteDiasAtras: new Date(hoje.getTime() - 7 * 86400000).toISOString().slice(0, 10), desde: new Date(hoje.getTime() - 7 * 86400000).toISOString().slice(0, 10), mesVigente: hoje.toISOString().slice(0, 7) },
    'Ritmo — Credenciais de envio': { error: { description: 'ETIMEDOUT', httpCode: 0 } },
    'Ritmo — Fretes do período': { data: [] },
    'Lyra configurada? (checagem)': { lyraConfigurada: true },
    'Lyra — Consultar uso IA': { error: { description: 'service unavailable', httpCode: 503 } }
  };
  const out = rodar(nodeMocks);
  assert.strictEqual(out[0].json.status, 200, 'freteVolume/frete vieram reais (zero) => não é falha total');
  assert.strictEqual(out[0].json.body.status, 'PARCIAL');
  assert.ok(out[0].json.body.pendencias.some(p => p.campo === 'freteSaldo' && p.codigo === 'FALHA_COMUNICACAO'));
  assert.ok(out[0].json.body.pendencias.some(p => p.campo === 'ia' && p.codigo === 'FALHA_COMUNICACAO'));
  return out[0].json;
});

// ---------------------------------------------------------------------------
// Cenário 6 — Nunca retorna 501, em nenhum dos cenários acima
// ---------------------------------------------------------------------------
cenario('6. Nenhum cenário retorna 501', () => {
  // validado via os cenários 1-5 abaixo, no runner principal (ver checagem global)
  return { ok: true };
});

let falhas = 0;
const resultados = [];
for (const c of cenarios) {
  try {
    const r = c.fn();
    resultados.push({ cenario: c.nome, ok: true, resultado: r });
    console.log('OK  -', c.nome);
  } catch (e) {
    falhas++;
    resultados.push({ cenario: c.nome, ok: false, erro: e.message });
    console.log('FAIL-', c.nome, '→', e.message);
  }
}

// Checagem global do cenário 6: nenhum status obtido em nenhum teste é 501.
const statusObtidos = resultados.filter(r => r.ok && r.resultado && r.resultado.status).map(r => r.resultado.status);
const tem501 = statusObtidos.includes(501);
console.log('\nStatus HTTP observados nos cenários 1-5:', statusObtidos);
console.log('Algum 501 encontrado?', tem501);
if (tem501) { falhas++; }

fs.writeFileSync(__dirname + '/resultados_testes_consumo_servicos.json', JSON.stringify(resultados, null, 2), 'utf-8');

console.log('\n' + (falhas === 0 ? 'TODOS OS CENÁRIOS PASSARAM' : falhas + ' CENÁRIO(S) FALHARAM'));
process.exit(falhas === 0 ? 0 : 1);

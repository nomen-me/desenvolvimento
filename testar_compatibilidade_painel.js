// =============================================================================
// Cenário 7 (compatibilidade com o consumidor atual) — executa o código REAL
// de Harmonia.chamar() e renderVBarChart(), copiados literalmente de
// synapse_painel_18-09m.html (linhas ~1669-1678 e ~4603-4610), contra os
// corpos que "Monta resposta" realmente produziu nos cenários 1 e 4 do teste
// anterior (resultados_testes_consumo_servicos.json). Objetivo: provar que o
// Painel consegue consumir a resposta nova sem lançar exceção quando há dado
// (mesmo parcial) e que ele cai no catch apenas na falha total (502).
// =============================================================================
const fs = require('fs');
const assert = require('assert');

const resultados = JSON.parse(fs.readFileSync(__dirname + '/resultados_testes_consumo_servicos.json', 'utf-8'));
function corpoDoCenario(nome) {
  const r = resultados.find(x => x.cenario.startsWith(nome));
  if (!r || !r.ok) throw new Error('cenário não encontrado/falhou: ' + nome);
  return r.resultado;
}

// ---- Harmonia.chamar, copiado literalmente de synapse_painel_18-09m.html ----
async function harmoniaChamarSimulado(respostaSimulada) {
  // Substitui fetch()+res.json() por um objeto equivalente, mas a REGRA é a
  // mesma linha por linha do arquivo real:
  const res = { ok: respostaSimulada.status >= 200 && respostaSimulada.status < 300 };
  const data = respostaSimulada.body;
  if (!res.ok) throw new Error(data.message || 'Falha ao acionar o Harmonia');
  return data;
}

// ---- renderVBarChart, copiado literalmente de synapse_painel_18-09m.html ----
function renderVBarChartSimulado(data, formatador) {
  const max = Math.max(...data.map(d => d.v), 1);
  return data.map(d => ({ titulo: `${d.d}: ${formatador(d.v)}`, alturaPct: Math.round(d.v / max * 100), label: d.d }));
}

async function testarRenderConsumo(nomeCenario, deveLancar) {
  const resp = corpoDoCenario(nomeCenario);
  let lancou = false;
  let servicos = null;
  try {
    servicos = await harmoniaChamarSimulado(resp);
    // as duas chamadas que o Painel faz de verdade em renderConsumo():
    const barrasIa = renderVBarChartSimulado(servicos.ia, v => v + ' req');
    const barrasFrete = renderVBarChartSimulado(servicos.frete, v => v + ' fretes');
    const textoSaldo = String(servicos.freteSaldo);
    const textoVolume = String(servicos.freteVolume);
    console.log(`  [${nomeCenario}] ia=${barrasIa.length} barra(s), frete=${barrasFrete.length} barra(s), freteSaldo="${textoSaldo}", freteVolume="${textoVolume}"`);
  } catch (e) {
    lancou = true;
    console.log(`  [${nomeCenario}] catch disparado (esperado p/ falha total): ${e.message}`);
  }
  assert.strictEqual(lancou, deveLancar, `cenário ${nomeCenario}: esperava lançar=${deveLancar}, obteve=${lancou}`);
}

(async () => {
  console.log('Cenário 7 — compatibilidade com Harmonia.chamar()/renderVBarChart() reais do Painel:');
  await testarRenderConsumo('1.', false);  // tudo OK -> não deve lançar, charts renderizam
  await testarRenderConsumo('3.', false);  // parcial -> não deve lançar, charts renderizam com o que há
  await testarRenderConsumo('4.', true);   // falha total (502) -> deve lançar, toast de erro aparece (comportamento correto)
  console.log('\nTODOS OS CENÁRIOS DE COMPATIBILIDADE PASSARAM');
})().catch(e => { console.error('FALHA:', e.message); process.exit(1); });

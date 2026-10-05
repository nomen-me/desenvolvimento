const body = $input.first().json.body || $input.first().json;

// O Chatwoot dispara message_created tanto pra mensagem do cliente quanto
// pra mensagem que A PRÓPRIA Lyra/atendente manda de volta — sem esse
// filtro, a Lyra entraria num loop respondendo a si mesma.
if (body.event !== 'message_created' || body.message_type !== 'incoming') {
  return [{ json: { ignorar: true } }];
}

const conversation = body.conversation || {};
const sender = body.sender || {};
const inbox = body.inbox || conversation.inbox || {};

const tenant_id = $env.LYRA_TENANT_ID;
const conversa_id = String(conversation.id || body.conversation_id || '');
const mensagem = body.content || '';

// Chatwoot manda as mensagens recentes dentro de conversation.messages —
// tira a mensagem atual de lá (já vai separada em "mensagem") e mapeia
// pro formato {de, txt} que o resto do L1 já espera.
const historico = (conversation.messages || [])
  .filter(m => m.id !== body.id)
  .slice(-10)
  .map(m => ({ de: m.message_type === 'incoming' ? 'cliente' : 'atendente', txt: m.content }));

const perfil_cliente = {
  nome: sender.name || '',
  telefone: sender.phone_number || '',
  email: sender.email || '',
  erpnext_id: sender.identifier || null   // é o Customer.name do Ritmo — W1_cadastros já grava isso como identifier no contato
};

const CANAL_POR_TIPO = {
  'Channel::Whatsapp': 'whatsapp',
  'Channel::FacebookPage': 'facebook',
  'Channel::Instagram': 'instagram',
  'Channel::WebWidget': 'website',
  'Channel::Telegram': 'telegram',
  'Channel::Sms': 'sms'
};
const canal = CANAL_POR_TIPO[inbox.channel_type] || 'outro';

// Curto-circuito: humano já assumiu essa conversa (mesma regra de antes)
const ja_escalada = conversation.status === 'open' && !!conversation.assignee_id;

const FRASES_PEDIDO_HUMANO = [
  'falar com humano', 'falar com atendente', 'falar com uma pessoa',
  'falar com alguem', 'quero um atendente', 'quero falar com atendente',
  'atendimento humano', 'transferir para atendente', 'transferir pra atendente',
  'nao quero falar com robo', 'nao quero falar com bot', 'quero uma pessoa real'
];
const mensagemNormalizada = mensagem
  .toLowerCase()
  .normalize('NFD').replace(/[\u0300-\u036f]/g, '');
const pedido_explicito_humano = FRASES_PEDIDO_HUMANO.some(f => mensagemNormalizada.includes(f));

// O plano (essencial=sugestão / demais=autônomo) não vem do Chatwoot — é
// característica da VPS/tenant, não da mensagem. Fica como env var do
// Harmonia. PENDÊNCIA REAL: essa var não existe ainda em nenhum script —
// alguém precisa gravar PLANO_ATUAL no .env do N8N na hora do provisionamento.
// Até lá, o default abaixo assume "essencial" (mais conservador: sugestão
// pro humano revisar, em vez de autônomo).
const plano = $env.PLANO_ATUAL || 'essencial';
const ia_suggestion = plano === 'essencial';

return [{
  json: {
    tenant_id, conversa_id, mensagem, historico, perfil_cliente, canal,
    ja_escalada, pedido_explicito_humano, ia_suggestion,
    chatwoot_conversation_id: conversation.id
  }
}];

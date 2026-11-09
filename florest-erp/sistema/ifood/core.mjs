// Contrato puro do canal iFood: não acessa Supabase, estoque, caixa ou impressoras.
export const uuidPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function cents(value){
 if(typeof value!=='number'||!Number.isFinite(value)||value<0||value>99999999999.99)throw Error('Valor monetário inválido no pedido.');
 return Math.round((value+Number.EPSILON)*100);
}
const text=(v,max=500)=>typeof v==='string'?v.slice(0,max):'';
export function normalizeOrder(order,mappings=[]){
 if(!order||!uuidPattern.test(order.id)||!uuidPattern.test(order.merchant?.id))throw Error('Identificação do pedido ou loja inválida.');
 if(!['DELIVERY','TAKEOUT','DINE_IN'].includes(order.orderType))throw Error('Modalidade ainda não suportada.');
 if(!Array.isArray(order.items)||!order.items.length||order.items.length>200)throw Error('Itens inválidos.');
 const pending=cents(order.payments?.pending),prepaid=cents(order.payments?.prepaid),amount=cents(order.total?.orderAmount);
 const methods=order.payments?.methods;
 if(!Array.isArray(methods)||methods.length>30)throw Error('Pagamentos inválidos.');
 const warnings=[];
 const map=(code,kind)=>mappings.find(m=>m.ativo!==false&&m.tipo===kind&&m.codigo_externo===code)?.produto_id||null;
 const items=order.items.map((i,index)=>{
  if(typeof i.quantity!=='number'||!Number.isFinite(i.quantity)||i.quantity<=0)throw Error('Quantidade inválida.');
  const code=text(i.externalCode,100),product=map(code,'produto');
  if(!product)warnings.push('Produto sem vínculo: '+text(i.name,120));
  const options=(i.options||[]).map(o=>{if(typeof o.quantity!=='number'||!Number.isFinite(o.quantity)||o.quantity<=0)throw Error('Quantidade do adicional inválida.');const external=text(o.externalCode,100),id=map(external,'adicional');if(!id)warnings.push('Adicional sem vínculo: '+text(o.name,120));return {codigo:external,produto_id:id,nome:text(o.name,120),quantidade:o.quantity,unitario:cents(o.unitPrice)};});
  return {id:text(i.uniqueId||i.id||String(index),100),codigo:code,produto_id:product,nome:text(i.name,120),quantidade:i.quantity,unitario:cents(i.unitPrice),total:cents(i.totalPrice),observacao:text(i.observations),adicionais:options};
 });
 const payments=methods.map(m=>{
  const type=text(m.type).trim(),method=text(m.method).trim(),value=cents(m.value);
  if(!['ONLINE','OFFLINE'].includes(type)||(m.currency&&m.currency!=='BRL'))throw Error('Tipo ou moeda de pagamento inválido.');
  const changeFor=method==='CASH'&&type==='OFFLINE'&&m.cash?.changeFor!=null?cents(m.cash.changeFor):0;
  return {tipo:type,forma:method,valor:value,bandeira:text(m.card?.brand,80),troco_para:changeFor,troco:changeFor?Math.max(0,changeFor-value):0};
 });
 if(payments.filter(m=>m.tipo==='ONLINE').reduce((s,m)=>s+m.valor,0)!==prepaid||payments.filter(m=>m.tipo==='OFFLINE').reduce((s,m)=>s+m.valor,0)!==pending)warnings.push('Valores dos pagamentos precisam de conferência.');
 if(prepaid+pending!==amount)warnings.push('Total do pedido e pagamentos precisam de conferência.');
 const scheduled=order.orderTiming==='SCHEDULED';
 if(scheduled&&!Number.isFinite(Date.parse(order.preparationStartDateTime)))warnings.push('Agendamento sem início de preparo válido.');
 return {id:order.id,merchant_id:order.merchant.id,numero:text(order.displayId,50),tipo:order.orderType,agendado:scheduled,inicio_preparo:order.preparationStartDateTime||null,
  entrega_por:text(order.delivery?.deliveredBy,30),cliente:text(order.customer?.name,120),itens:items,pagamentos:payments,
  total:amount,pago_online:prepaid,a_cobrar:pending,dinheiro_a_cobrar:payments.filter(m=>m.tipo==='OFFLINE'&&m.forma==='CASH').reduce((s,m)=>s+m.valor,0),
  dinheiro_recebido:0,beneficios:order.benefits||[],avisos:warnings};
}
const states={PLC:'recebido',PLACED:'recebido',CFM:'confirmado',CONFIRMED:'confirmado',SPS:'em_preparo',PREPARATION_STARTED:'em_preparo',RTP:'pronto',READY_TO_PICKUP:'pronto',DSP:'despachado',DISPATCHED:'despachado',CON:'concluido',CONCLUDED:'concluido',CAN:'cancelado',CANCELLED:'cancelado'};
export function eventRecord(event){
 if(!event||!uuidPattern.test(event.id)||!uuidPattern.test(event.merchantId)||!uuidPattern.test(event.orderId)||!Number.isFinite(Date.parse(event.createdAt)))throw Error('Evento de pedido inválido.');
 return {id:event.id,merchant_id:event.merchantId,pedido_id:event.orderId,ocorrido_em:event.createdAt,estado:states[event.fullCode]||states[event.code]||'revisar',codigo:text(event.fullCode||event.code,100)};
}
export function applyEvent(previous,event){
 const next=eventRecord(event);
 if(!previous)return {...next,ids:[next.id]};
 if(previous.merchant_id!==next.merchant_id||previous.pedido_id!==next.pedido_id)throw Error('Evento pertence a outra loja ou pedido.');
 if(previous.ids.includes(next.id))return previous;
 const ids=[...previous.ids,next.id];
 if(Date.parse(next.ocorrido_em)<Date.parse(previous.ocorrido_em)||['cancelado','concluido'].includes(previous.estado))return {...previous,ids};
 return {...next,ids};
}
export function sampleOrder(offline=false){return {
 id:'00000000-0000-4000-8000-000000000001',displayId:'TESTE LOCAL',merchant:{id:'00000000-0000-4000-8000-000000000002'},orderType:'DELIVERY',orderTiming:'IMMEDIATE',customer:{name:'Cliente de demonstração'},delivery:{deliveredBy:'MERCHANT'},
 items:[{id:'demo',name:'Produto de demonstração',externalCode:'DEMO-001',quantity:1,unitPrice:30,totalPrice:30,observations:'Exemplo local; não enviar à cozinha',options:[]}],total:{orderAmount:35,subTotal:30,deliveryFee:5,benefits:0,additionalFees:0},payments:{prepaid:offline?0:35,pending:offline?35:0,methods:[{type:offline?'OFFLINE':'ONLINE',method:offline?'CASH':'CREDIT',currency:'BRL',value:35,card:{brand:'VISA'},...(offline?{cash:{changeFor:50}}:{})}]},benefits:[]};}

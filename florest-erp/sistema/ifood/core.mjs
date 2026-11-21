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
 const map=(code,kind,name)=>{const active=mappings.filter(m=>m.ativo!==false&&m.tipo===kind);return (order.isTest===true?active.find(m=>m.nome_teste&&m.nome_teste===name)?.produto_id:null)||active.find(m=>!m.nome_teste&&m.codigo_externo===code)?.produto_id||null};
 const items=order.items.map((i,index)=>{
  if(typeof i.quantity!=='number'||!Number.isFinite(i.quantity)||i.quantity<=0)throw Error('Quantidade inválida.');
  const code=text(i.externalCode,100),product=map(code,'produto',text(i.name,120));
  if(!product)warnings.push('Produto sem vínculo: '+text(i.name,120));
  function option(o,level=2){
   if(typeof o.quantity!=='number'||!Number.isFinite(o.quantity)||o.quantity<=0)throw Error('Quantidade do adicional inválida.');
   const external=text(o.externalCode,100),id=map(external,'adicional',text(o.name,120));if(!id)warnings.push('Adicional sem vínculo: '+text(o.name,120));
   const children=o.customizations??o.customization??[];if(!Array.isArray(children))throw Error('Complementos inválidos.');
   if(level>=3&&children.length)warnings.push('Complementos além do terceiro nível exigem revisão.');
   return {id:text(o.id,100),codigo:external,produto_id:id,nome:text(o.name,120),grupo:text(o.groupName,120),quantidade:o.quantity,unitario:cents(o.unitPrice),total:cents(o.price??o.quantity*(o.unitPrice+(o.addition||0))),adicionais:level<3?children.map(c=>option(c,level+1)):[]};
  }
  const options=(i.options||[]).map(o=>option(o));
  return {id:text(i.uniqueId||i.id||String(index),100),codigo:code,produto_id:product,nome:text(i.name,120),quantidade:i.quantity,unitario:cents(i.unitPrice),total:cents(i.totalPrice),observacao:text(i.observations,1024),adicionais:options};
 });
 const payments=methods.map(m=>{
  const type=text(m.type).trim(),method=text(m.method).trim(),value=cents(m.value);
  if(!['ONLINE','OFFLINE'].includes(type)||(m.currency&&m.currency!=='BRL'))throw Error('Tipo ou moeda de pagamento inválido.');
  const changeFor=method==='CASH'&&type==='OFFLINE'&&m.cash?.changeFor!=null?cents(m.cash.changeFor):0;
  return {tipo:type,forma:method,valor:value,bandeira:text(m.card?.brand,80),autorizacao:text(m.transaction?.authorizationCode,50),cnpj_adquirente:text(m.transaction?.acquirerDocument,20),carteira:text(m.wallet?.name,80),troco_para:changeFor,troco:changeFor?Math.max(0,changeFor-value):0};
 });
 if(payments.filter(m=>m.tipo==='ONLINE').reduce((s,m)=>s+m.valor,0)!==prepaid||payments.filter(m=>m.tipo==='OFFLINE').reduce((s,m)=>s+m.valor,0)!==pending)warnings.push('Valores dos pagamentos precisam de conferência.');
 if(prepaid+pending!==amount)warnings.push('Total do pedido e pagamentos precisam de conferência.');
 const fees=cents(order.total?.additionalFees??0),feeItems=(order.additionalFees||[]).reduce((sum,f)=>sum+cents(f.value),0);
 if(fees!==feeItems)warnings.push('Taxas do iFood precisam de conferência.');
 const benefits=order.benefits||[];if(!Array.isArray(benefits))throw Error('Benefícios inválidos.');
 let subsidy=0,merchantDiscount=0,benefitSum=0;const sponsors=[];
 for(const benefit of benefits){benefitSum+=cents(benefit.value);let sponsored=0;for(const sponsor of benefit.sponsorshipValues||[]){const name=text(sponsor.name,30),value=cents(sponsor.value);sponsored+=value;sponsors.push({nome:name,descricao:text(sponsor.description,160),valor:value});if(['IFOOD','EXTERNAL','CHAIN'].includes(name))subsidy+=value;else if(name==='MERCHANT')merchantDiscount+=value;else if(value)warnings.push('Patrocinador do cupom exige conferência: '+name)}if(sponsored!==cents(benefit.value))warnings.push('Patrocínio do cupom precisa de conferência.');}
 if(benefitSum!==cents(order.total?.benefits??0))warnings.push('Total dos cupons precisa de conferência.');
 const base=cents(order.total?.subTotal??items.reduce((sum,i)=>sum+i.total,0)/100)+cents(order.total?.deliveryFee??0);
 if(benefitSum>base&&subsidy&&merchantDiscount)warnings.push('Cupom maior que o pedido com mais de um patrocinador exige conferência.');
 subsidy=Math.min(subsidy,Math.max(0,base-Math.min(merchantDiscount,base)));
 const merchantTotal=amount-fees+subsidy;if(merchantTotal<0)throw Error('Taxas maiores que o pedido.');
 const onlineFees=Math.min(fees,prepaid),offlineFees=fees-onlineFees;if(offlineFees>pending)warnings.push('Taxas maiores que o saldo dos pagamentos.');
 const online=payments.map((p,index)=>({...p,index})).filter(p=>p.tipo==='ONLINE');
 let allocated=0;const split=online.map(p=>{const exact=prepaid?onlineFees*p.valor/prepaid:0,share=Math.floor(exact);allocated+=share;return {index:p.index,share,remainder:exact-share}}).sort((a,b)=>b.remainder-a.remainder||a.index-b.index);
 for(let n=0;n<Math.min(onlineFees-allocated,split.length);n++)split[n].share++;
 for(const [index,p]of payments.entries()){const fee=split.find(x=>x.index===index)?.share||0;p.taxa_ifood=fee;p.valor_empresa=p.valor-fee}
 if(subsidy)payments.push({tipo:'ONLINE',forma:'SUBSIDIO_IFOOD',valor:subsidy,valor_empresa:subsidy,taxa_ifood:0,origem:'BENEFICIO',bandeira:'',troco_para:0,troco:0});
 const scheduled=order.orderTiming==='SCHEDULED',preparation=order.preparationStartDateTime||order.schedule?.preparationStartDateTime||order.scheduled?.preparationStartDateTime||null;
 if(scheduled&&!Number.isFinite(Date.parse(preparation)))warnings.push('Agendamento sem início de preparo válido.');
 return {id:order.id,merchant_id:order.merchant.id,numero:text(order.displayId,50),tipo:order.orderType,agendado:scheduled,inicio_preparo:preparation,
  is_test:order.isTest===true,criado_em:text(order.createdAt,60),entrega_por:text(order.delivery?.deliveredBy,30),informacoes:orderInformation(order),patrocinadores:sponsors,subsidios:subsidy,desconto_loja:Math.min(merchantDiscount,base),cliente:text(order.customer?.name,120),itens:items,pagamentos:payments,
  total:amount,total_empresa:merchantTotal,taxas_ifood:fees,taxas_offline:offlineFees,pago_online_empresa:payments.filter(p=>p.tipo==='ONLINE').reduce((sum,p)=>sum+p.valor_empresa,0),pago_online:prepaid,a_cobrar:pending,dinheiro_a_cobrar:payments.filter(m=>m.tipo==='OFFLINE'&&m.forma==='CASH').reduce((s,m)=>s+m.valor,0),
  dinheiro_recebido:0,beneficios:order.benefits||[],avisos:warnings};
}
export function orderInformation(order){const d=order.delivery||{},a=d.deliveryAddress||{},customer=order.customer||{};return {
 endereco:text(a.formattedAddress||[a.streetName,a.streetNumber].filter(Boolean).join(', '),350),bairro:text(a.neighborhood,100),cidade:text(a.city,100),uf:text(a.state,20),cep:text(a.postalCode,20),complemento:text(a.complement,200),referencia:text(a.reference,300),instrucoes:text(d.observations||order.takeout?.observations||order.extraInfo,1024),observacoes:text(order.observations,1024),codigo_coleta:text(d.pickupCode,30),previsao:text(d.deliveryDateTime||order.takeout?.takeoutDateTime,60),telefone:text(customer.phone?.number,50),localizador:text(customer.phone?.localizer,50),documento:text(customer.documentNumber||customer.taxPayerIdentificationNumber||order.additionalInfo?.taxPayerIdentificationNumber,30)
}}
export function normalizeDispute(raw={}){return {...raw,disputeId:raw.disputeId||raw.id||null,acceptCancellationReasons:raw.acceptCancellationReasons||raw.metadata?.acceptCancellationReasons||[],alternatives:raw.alternatives||[]}}
const states={SPE:'pronto',SEPARATION_ENDED:'pronto',SEPARATION_STARTED:'em_preparo',PLC:'recebido',PLACED:'recebido',CFM:'confirmado',CONFIRMED:'confirmado',SPS:'em_preparo',PRS:'em_preparo',PREPARATION_STARTED:'em_preparo',RTP:'pronto',READY_TO_PICKUP:'pronto',DSP:'despachado',DISPATCHED:'despachado',CON:'concluido',CONCLUDED:'concluido',CAN:'cancelado',CANCELLED:'cancelado'};
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
 if(Date.parse(next.ocorrido_em)<Date.parse(previous.ocorrido_em)||(previous.estado==='cancelado'||(previous.estado==='concluido'&&next.estado!=='cancelado')))return {...previous,ids};
 return {...next,ids};
}
export function sampleOrder(offline=false){return {
 id:'00000000-0000-4000-8000-000000000001',displayId:'TESTE LOCAL',merchant:{id:'00000000-0000-4000-8000-000000000002'},orderType:'DELIVERY',orderTiming:'IMMEDIATE',customer:{name:'Cliente de demonstração'},delivery:{deliveredBy:'MERCHANT'},
 items:[{id:'demo',name:'Produto de demonstração',externalCode:'DEMO-001',quantity:1,unitPrice:30,totalPrice:30,observations:'Exemplo local; não enviar à cozinha',options:[]}],total:{orderAmount:35,subTotal:30,deliveryFee:5,benefits:0,additionalFees:0},payments:{prepaid:offline?0:35,pending:offline?35:0,methods:[{type:offline?'OFFLINE':'ONLINE',method:offline?'CASH':'CREDIT',currency:'BRL',value:35,card:{brand:'VISA'},...(offline?{cash:{changeFor:50}}:{})}]},benefits:[]};}

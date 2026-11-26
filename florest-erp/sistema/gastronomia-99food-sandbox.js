import {normalizeOrder} from './99food/normalize.mjs';
const labels={100:'Novo · aguardando confirmação',200:'Confirmado',400:'Despachado · em entrega',500:'Entregador no endereço',600:'Concluído'};
const stateLabel=order=>order.status_99food>=900?(order.status_99food===922?'Cancelado · prazo de confirmação expirado (922)':'Cancelado · '+order.status_99food):(labels[order.status_99food]||(order.estado==='aceito'?'Aceito na 99Food':'Recebido · aguardando consulta'));
const unavailable=order=>order.status_99food==null&&/12004/.test(order.ultimo_erro||'');
const money=value=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format(Number(value||0)/100);
const reasons=[[1010,'Produto esgotado'],[1020,'Loja fechada'],[1030,'Loja sem capacidade de preparo'],[1040,'Acidente ou falta de energia'],[1050,'Problema do cliente'],[1060,'Sem entregador'],[1070,'Cardápio precisa ser atualizado'],[1071,'Fora da área de entrega'],[1072,'Endereço em área insegura'],[1073,'Suspeita de fraude'],[1074,'Dúvida sobre taxas ou promoções'],[1080,'Outro motivo']];
export async function mountSandbox99Food(root,{list,accept,invoke,current,closed=false,canCancel=false,canReceive=false,sharedGrid=false,onCount=()=>{},day=null,showDiagnostics=false}){
 const el=(tag,text,className)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(className)n.className=className;return n};
 const section=el('section','','gs-card'),message=el('p','','gs-meta'),orders=sharedGrid?root:el('div','','gs-grid gs-orders-compact');let managed=[],initialRender=true;
 message.setAttribute('role','status');message.hidden=true;
 if(!sharedGrid){section.append(message,orders);root.append(section)}
 const diagnostics=el('details'),diagnosticTitle=el('summary'),diagnosticBody=el('div');diagnostics.append(diagnosticTitle,diagnosticBody);diagnostics.hidden=true;if(showDiagnostics&&!sharedGrid)section.append(diagnostics);
 const formatter=new Intl.DateTimeFormat('pt-BR',{dateStyle:'short',timeStyle:'short',timeZone:'America/Sao_Paulo'});
 const active=()=>current()&&(initialRender||(sharedGrid?root:section).isConnected);
 const notify=text=>{message.textContent=text;message.hidden=!text;if(sharedGrid&&text&&!message.isConnected){root.append(message);managed.push(message)}};
 const call=(action,values={})=>invoke?invoke(action,values):accept(values.order_id);
 let busy=false;
 function button(parent,label,fn){const b=el('button',label,'gs-btn');b.type='button';b.onclick=async()=>{if(!active()||busy)return;busy=true;b.disabled=true;try{await fn()}catch(e){if(active())notify(e.message||'Não foi possível concluir.')}finally{busy=false;b.disabled=false}};parent.append(b);return b}
 async function send(order,action,payload={}){
  const dialog=root.querySelector('.gs-99food-dialog[open]');if(dialog)dialog.dataset.editing='false';
  notify('Enviando operação à 99Food…');
  const result=await call(action,{order_id:order.order_id,chave:crypto.randomUUID(),payload,ambiente:order.ambiente??'teste'});
  if(!active())return;
  notify(result.erro||'Operação registrada. Aguardando confirmação da 99Food.');
  await refresh();
 }
 function field(parent,label,choices){const wrap=el('label',label),input=el(choices?'select':'input');if(choices)for(const [value,text]of choices){const option=el('option',text);option.value=String(value);input.append(option)}wrap.append(input);parent.append(wrap);return input}
 function actionForm(card,title,build){const box=el('details'),summary=el('summary',title),form=el('form','','gs-form-grid');box.append(summary,form);card.append(box);build(form)}
 function submit(form,label,fn){const b=el('button',label,'gs-btn');b.type='submit';form.append(b);form.onsubmit=async event=>{event.preventDefault();if(busy||!active())return;busy=true;b.disabled=true;try{await fn()}catch(e){if(active())notify(e.message||'Não foi possível enviar.')}finally{busy=false;b.disabled=false}}}
 function items(parent,lines,depth=0){if(depth>8)return;const ul=el('ul');for(const line of (Array.isArray(lines)?lines:[]).slice(0,200)){const li=el('li',`${line.amount??1} × ${line.name||'Item'} · ${money(line.total_price)}`);if(line.remark)li.append(el('p',line.remark));if(line.sub_item_list?.length)items(li,line.sub_item_list,depth+1);ul.append(li)}parent.append(ul)}
 function print(order){const d=order.detalhe??{},dialog=el('dialog'),article=el('article'),printKey=crypto.randomUUID();article.append(el('h2',order.ambiente==='producao'?'99Food · PEDIDO':'99Food · PEDIDO DE TESTE'),el('p','#'+(order.order_index??'')+' · '+order.order_id),el('p',stateLabel(order)),el('p',d.receive_address?.name||'Cliente'),el('p',d.receive_address?.poi_address||''));items(article,d.order_items);finance(article,order);dialog.append(article);button(dialog,'Imprimir',async()=>{const r=await call('imprimir',{order_id:order.order_id,chave:printKey,ambiente:order.ambiente??'teste'});if(r.erro)throw Error(r.erro);notify('Vias enviadas ao Print Agent. Confira a confirmação da impressora.');dialog.close();dialog.remove()});button(dialog,'Fechar',()=>{dialog.close();dialog.remove()});document.body.append(dialog);dialog.showModal()}
 function finance(parent,order){
  let n=order.normalizado;try{n??=normalizeOrder(order.detalhe??{})}catch{}
  if(!n){if(order.detalhe?.price)parent.append(el('p','Total informado pela 99Food: '+money(order.detalhe.price.real_pay_price)));return}
  const labels={itens:'Subtotal dos itens',subsidio_loja:'Promoção custeada pela loja',entrega_original:'Entrega antes dos descontos',desconto_itens:'Desconto dos itens',entrega:'Entrega',desconto_entrega:'Desconto da entrega',servico:'Taxa de serviço',pedido_minimo:'Taxa de pedido mínimo',complemento_minimo:'Complemento do pedido mínimo',gorjeta:'Gorjeta',cupom:'Cupom informado (já incluído nos descontos)',reembolso:'Reembolso',cancelamento_parcial:'Ajuste por cancelamento parcial',total_cliente:'Total do cliente',total_loja:'Valor informado para a loja'};
  for(const [key,label]of Object.entries(labels))if(n.precos[key]||['itens','total_cliente','total_loja'].includes(key))parent.append(el('p',label+': '+(n.precos[key]==null?'Não informado pela 99Food':money(n.precos[key])),'gs-meta'));
  parent.append(el('p','Pago/repasse pela plataforma: '+money(n.pago_online)),el('p','A conferir presencialmente: '+money(n.a_cobrar)));
  if(n.aguardando_valor_presencial)parent.append(el('p','Aguardando o valor que será recebido do entregador.','msg error'));
  for(const warning of n.avisos||[])parent.append(el('p',warning,'msg error'));
  for(const promo of n.promocoes||[])parent.append(el('p','Promoção 99Food · tipo '+(promo.promo_type??'')+(promo.promo_discount!=null?' · desconto '+money(promo.promo_discount):''),'gs-meta'));
 }
 async function refresh(){
  const received=await list();if(!active())return;const opened=root.querySelector('.gs-99food-dialog[open]'),openId=opened?.dataset.pedido,scroll=opened?.querySelector('.gs-ifood-dialog-body')?.scrollTop||0;if(opened?.dataset.editing==='true')return;if(sharedGrid){for(const node of managed)node.remove();managed=[]}else orders.replaceChildren();
  const missing=received.filter(unavailable);diagnostics.hidden=!missing.length;diagnosticTitle.textContent='Registros sem consulta na 99Food ('+missing.length+')';diagnosticBody.replaceChildren(el('p','Estes registros retornaram código 12004 e ficam separados dos pedidos em aberto. O histórico foi preservado.','gs-meta'));for(const o of missing)diagnosticBody.append(el('p','Pedido #'+(o.order_index??'—')+' · ID '+o.order_id+' · '+formatter.format(new Date(o.recebido_em))+' · Não disponível para consulta na 99Food.','gs-meta'));
  const visible=received.filter(o=>!unavailable(o)&&(!day||new Intl.DateTimeFormat('en-CA',{timeZone:'America/Sao_Paulo',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(Number(o.detalhe?.create_time)*1000||o.recebido_em))===day)).filter(o=>closed?(o.status_99food===600||o.status_99food>=900):!(o.status_99food===600||o.status_99food>=900));
  onCount(visible.length);
  if(!sharedGrid&&!visible.length)orders.append(el('p',closed?'Nenhum pedido 99Food encerrado.':'Nenhum pedido 99Food em aberto.','gs-meta'));
  for(const order of visible){
   const d=order.detalhe??{},card=el('article','','gs-card gs-order gs-order--99food'),actions=el('div','','gs-actions'),s=order.status_99food,pickup=d.fulfillment_mode===1||d.delivery_type===0,self=d.delivery_type===2;
   card.append(el('div','99Food','gs-order-channel gs-order-channel--99food'),el('h4','Pedido #'+(order.order_index??'—')),el('p','ID 99Food: '+order.order_id,'gs-meta'),el('p',formatter.format(new Date(order.recebido_em)),'gs-meta'),el('strong',stateLabel(order)),el('p',pickup?'Retirada pelo cliente':self?'Entrega da loja':d.delivery_type===1?'Entrega da 99Food':'Modalidade aguardando consulta','gs-meta'));
   if(order.pronto)card.append(el('p','Pronto · confirmado pelo evento da 99Food'));
   if(s===100){const seconds=Math.max(0,300-Math.floor((Date.now()-(Number(d.create_time)*1000||Date.parse(order.recebido_em)))/1000));card.append(el('p',seconds?'Confirme em até '+Math.ceil(seconds/60)+' minuto(s).':'Prazo de confirmação pode ter encerrado; consulte a 99Food.','gs-meta'))}
   if(d.receive_address){const a=d.receive_address;card.append(el('p',a.name||[a.first_name,a.last_name].filter(Boolean).join(' ')||'Cliente'),el('p',a.virtual_phone_number||a.phone||''),el('p',[a.poi_address||a['formatted Address'],a.house_number,a.complement,a.reference].filter(Boolean).join(' · ')))}
   items(card,d.order_items);if(d.remark)card.append(el('p','Observações: '+d.remark));
   finance(card,order);if(order.revisao_motivo)card.append(el('p',order.revisao_motivo,'msg error'));for(const job of order.impressao||[])card.append(el('p','Impressão: '+job.status+(job.erro?' · '+job.erro:''),'gs-meta'));
   if(order.ultimo_erro)card.append(el('p',order.ultimo_erro,'msg error'));
   const pending=(order.comandos||[]).some(c=>['pendente','enviando','enviado','incerto'].includes(c.estado));
   if(!closed&&!pending&&!order.ultimo_erro?.includes('12004')){
    if(s===100||(!s&&order.estado==='recebido'))button(actions,'Confirmar pedido',()=>send(order,'confirmar'));
    if(s===200&&!order.pronto)button(actions,'Pedido pronto',()=>send(order,'pronto'));
    if(s===200&&pickup)button(actions,'Confirmar retirada pelo cliente',()=>send(order,'retirada'));
    if(s===200&&self&&!pickup)actionForm(card,'Despachar entrega da loja',form=>{const name=field(form,'Nome completo do entregador'),phone=field(form,'Telefone com DDD'),minutes=field(form,'Prazo de entrega em minutos');name.required=phone.required=minutes.required=true;minutes.type='number';minutes.min=1;minutes.max=240;minutes.value=30;submit(form,'Confirmar despacho',()=>send(order,'despachar',{nome:name.value,telefone:phone.value,minutos:Number(minutes.value)}))});
    if([400,500].includes(s)&&self&&!pickup){button(actions,'Informar entrega realizada',()=>send(order,'entregue'));actionForm(card,'Concluir com código do cliente',form=>{const code=field(form,'Código de quatro dígitos');code.required=true;code.pattern='[0-9]{4}';code.inputMode='numeric';code.maxLength=4;submit(form,'Validar código e concluir',()=>send(order,'concluir',{codigo:code.value}))})}
    if(canCancel)actionForm(card,'Cancelar pedido na 99Food',form=>{const reason=field(form,'Motivo',reasons.filter(([id])=>self||![1060,1071,1072].includes(id))),text=field(form,'Descrição do motivo');text.maxLength=500;text.required=true;submit(form,'Confirmar cancelamento',()=>send(order,'cancelar',{motivo_id:Number(reason.value),motivo:text.value}))});
   }
    if(canCancel&&!pending)for(const event of (order.eventos||[]).filter(e=>e.dados&&['orderCancelApply','orderRefundApply'].includes(e.tipo))){const req=event.dados,refund=event.tipo==='orderRefundApply';actionForm(card,(refund?'Pedido de reembolso':'Solicitação de cancelamento')+' · '+(req.apply_reason||''),form=>{const decision=field(form,'Resposta',[['true','Aceitar solicitação'],['false','Recusar solicitação']]),options=refund?(req.base_reason_list||[]).map(r=>[r.base_reason_id,r.base_reason]):(req.reason_list||[]).map(r=>[r.reason,r.reason]),reason=field(form,'Motivo para recusar',options);submit(form,'Enviar resposta',()=>send(order,refund?'responder_reembolso':'responder_cancelamento',{apply_id:String(req.apply_id),concordar:decision.value==='true',motivo:refund?'':reason.value,motivo_id:refund?reason.value:undefined}))})}
   if(canReceive&&order.ambiente==='producao'&&order.atendimento_id&&!order.recebimento_confirmado&&order.normalizado?.a_cobrar>0)actionForm(card,'Confirmar recebimento presencial',form=>{const method=field(form,'Forma recebida',[['Dinheiro','Dinheiro'],['Pix','Pix'],['Cartão de Débito','Cartão de Débito'],['Cartão de Crédito','Cartão de Crédito']]),proof=field(form,'Confirmo que o valor foi efetivamente recebido');proof.type='checkbox';proof.required=true;form.append(el('p','Valor: '+money(order.normalizado.a_cobrar)));submit(form,'Registrar recebimento',()=>send(order,'receber',{forma:method.value,valor:order.normalizado.a_cobrar/100,confirmado:proof.checked}))});
   button(actions,'Imprimir conferência',()=>print(order));card.append(actions);
   const history=el('details');history.append(el('summary','Histórico da integração'));
   for(const c of order.comandos||[])history.append(el('p',`${c.acao}: ${c.estado}${c.erro?' · '+c.erro:''}${c.request_id?' · protocolo '+c.request_id:''}`));
   for(const e of order.eventos||[])history.append(el('p',e.tipo+' · '+formatter.format(new Date(e.recebido_em))));card.append(history);
   if(sharedGrid){
    const compact=el('article','','gs-card gs-order gs-order--99food'),preview=el('div','','gs-order-preview'),customer=d.receive_address?.name||[d.receive_address?.first_name,d.receive_address?.last_name].filter(Boolean).join(' ')||'Cliente 99Food';
    compact.append(el('div','99Food','gs-order-channel gs-order-channel--99food'),preview);
    preview.append(el('h3','#'+(order.order_index??'—')+' · '+stateLabel(order)),el('b',customer),el('p',(d.order_items||[]).reduce((sum,item)=>sum+Number(item.amount||0),0)+' itens · '+(d.price?.real_pay_price==null?'Total do cliente não informado':money(d.price?.real_pay_price)),'gs-meta'),el('p',formatter.format(new Date(order.recebido_em)),'gs-meta'));
    if(order.pronto)preview.append(el('p','Pedido pronto','gs-meta'));if(pending)preview.append(el('p','Operação aguardando confirmação','gs-meta'));if(order.ultimo_erro)preview.append(el('p','Requer conferência','gs-meta'));
    const dialog=el('dialog','','gs-ifood-dialog gs-99food-dialog'),head=el('div','','gs-ifood-dialog-head'),content=el('div','','gs-ifood-dialog-body'),close=el('button','Fechar');dialog.dataset.pedido=order.order_id;dialog.setAttribute('aria-label','Pedido 99Food #'+(order.order_index??'—'));close.type='button';close.onclick=()=>dialog.close();head.append(el('h2','Pedido 99Food #'+(order.order_index??'—')),close);content.append(card);dialog.append(head,content);dialog.addEventListener('input',()=>{dialog.dataset.editing='true'});dialog.addEventListener('change',()=>{dialog.dataset.editing='true'});
    button(compact,'Abrir pedido',()=>dialog.showModal());compact.append(dialog);orders.append(compact);managed.push(compact);if(openId===order.order_id){dialog.showModal();content.scrollTop=scroll}
   }else{orders.append(card);managed.push(card)}
  }
 }
 try{await refresh()}catch(e){if(active())notify(e.message||'Não foi possível carregar os pedidos da 99Food.')}finally{initialRender=false}
 // Atualiza somente a lista local; não consulta a API da 99Food a cada tela.
 async function poll(){if(!active())return;if(!busy&&!document.hidden&&!(sharedGrid?root:section).querySelector('details[open]'))try{await refresh()}catch{}if(active())setTimeout(poll,15000)}
 setTimeout(poll,15000);
}

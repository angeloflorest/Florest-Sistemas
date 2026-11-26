const labels={100:'Novo · aguardando confirmação',200:'Confirmado',400:'Despachado · em entrega',500:'Entregador no endereço',600:'Concluído'};
const stateLabel=order=>order.status_99food>=900?(order.status_99food===922?'Cancelado · prazo de confirmação expirado (922)':'Cancelado · '+order.status_99food):(labels[order.status_99food]||(order.estado==='aceito'?'Aceito na 99Food':'Recebido · aguardando consulta'));
const unavailable=order=>order.status_99food==null&&/12004/.test(order.ultimo_erro||'');
const money=value=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format(Number(value||0)/100);
const reasons=[[1010,'Produto esgotado'],[1020,'Loja fechada'],[1030,'Loja sem capacidade de preparo'],[1040,'Acidente ou falta de energia'],[1050,'Problema do cliente'],[1060,'Sem entregador'],[1070,'Cardápio precisa ser atualizado'],[1071,'Fora da área de entrega'],[1072,'Endereço em área insegura'],[1073,'Suspeita de fraude'],[1074,'Dúvida sobre taxas ou promoções'],[1080,'Outro motivo']];
export async function mountSandbox99Food(root,{list,accept,invoke,current,closed=false,canCancel=false,sharedGrid=false,onCount=()=>{},day=null,showDiagnostics=false}){
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
  notify('Enviando operação à 99Food…');
  const result=await call(action,{order_id:order.order_id,chave:crypto.randomUUID(),payload});
  if(!active())return;
  notify(result.erro||'Operação registrada. Aguardando confirmação da 99Food.');
  await refresh();
 }
 function field(parent,label,choices){const wrap=el('label',label),input=el(choices?'select':'input');if(choices)for(const [value,text]of choices){const option=el('option',text);option.value=String(value);input.append(option)}wrap.append(input);parent.append(wrap);return input}
 function actionForm(card,title,build){const box=el('details'),summary=el('summary',title),form=el('form','','gs-form-grid');box.append(summary,form);card.append(box);build(form)}
 function submit(form,label,fn){const b=el('button',label,'gs-btn');b.type='submit';form.append(b);form.onsubmit=async event=>{event.preventDefault();if(busy||!active())return;busy=true;b.disabled=true;try{await fn()}catch(e){if(active())notify(e.message||'Não foi possível enviar.')}finally{busy=false;b.disabled=false}}}
 function items(parent,lines,depth=0){if(depth>8)return;const ul=el('ul');for(const line of (Array.isArray(lines)?lines:[]).slice(0,200)){const li=el('li',`${line.amount??1} × ${line.name||'Item'} · ${money(line.total_price)}`);if(line.remark)li.append(el('p',line.remark));if(line.sub_item_list?.length)items(li,line.sub_item_list,depth+1);ul.append(li)}parent.append(ul)}
 function print(order){const d=order.detalhe??{},dialog=el('dialog'),article=el('article');article.append(el('h2','99Food · PEDIDO DE TESTE'),el('p','#'+(order.order_index??'')+' · '+order.order_id),el('p',stateLabel(order)),el('p',d.receive_address?.name||'Cliente'),el('p',d.receive_address?.poi_address||''));items(article,d.order_items);article.append(el('p','Total informado pela 99Food: '+money(d.price?.real_pay_price)));dialog.append(article);button(dialog,'Imprimir',()=>{const frame=document.createElement('iframe');frame.hidden=true;dialog.append(frame);const doc=frame.contentDocument;doc.body.replaceChildren(article.cloneNode(true));const style=doc.createElement('style');style.textContent='body{color:#000;background:#fff;font:15px monospace}h2{font-size:18px}';doc.head.append(style);frame.contentWindow.focus();frame.contentWindow.print();frame.remove()});button(dialog,'Fechar',()=>{dialog.close();dialog.remove()});document.body.append(dialog);dialog.showModal()}
 async function refresh(){
  const received=await list();if(!active())return;if(sharedGrid){for(const node of managed)node.remove();managed=[]}else orders.replaceChildren();
  const missing=received.filter(unavailable);diagnostics.hidden=!missing.length;diagnosticTitle.textContent='Registros sem consulta na 99Food ('+missing.length+')';diagnosticBody.replaceChildren(el('p','Estes registros retornaram código 12004 e ficam separados dos pedidos em aberto. O histórico foi preservado.','gs-meta'));for(const o of missing)diagnosticBody.append(el('p','Pedido #'+(o.order_index??'—')+' · ID '+o.order_id+' · '+formatter.format(new Date(o.recebido_em))+' · Não disponível para consulta na 99Food.','gs-meta'));
  const visible=received.filter(o=>!unavailable(o)&&(!day||new Intl.DateTimeFormat('en-CA',{timeZone:'America/Sao_Paulo',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(Number(o.detalhe?.create_time)*1000||o.recebido_em))===day)).filter(o=>closed?(o.status_99food===600||o.status_99food>=900):!(o.status_99food===600||o.status_99food>=900));
  onCount(visible.length);
  if(!sharedGrid&&!visible.length)orders.append(el('p',closed?'Nenhum pedido de teste encerrado.':'Nenhum pedido de teste em aberto.','gs-meta'));
  for(const order of visible){
   const d=order.detalhe??{},card=el('article','','gs-card gs-order gs-order--99food'),actions=el('div','','gs-actions'),s=order.status_99food,pickup=d.fulfillment_mode===1||d.delivery_type===0,self=d.delivery_type===2;
   card.append(el('div','99Food','gs-order-channel gs-order-channel--99food'),el('h4','Pedido #'+(order.order_index??'—')),el('p','ID 99Food: '+order.order_id,'gs-meta'),el('p',formatter.format(new Date(order.recebido_em)),'gs-meta'),el('strong',stateLabel(order)),el('p',pickup?'Retirada pelo cliente':self?'Entrega da loja':d.delivery_type===1?'Entrega da 99Food':'Modalidade aguardando consulta','gs-meta'));
   if(order.pronto)card.append(el('p','Pronto · confirmado pelo evento da 99Food'));
   if(s===100){const seconds=Math.max(0,300-Math.floor((Date.now()-(Number(d.create_time)*1000||Date.parse(order.recebido_em)))/1000));card.append(el('p',seconds?'Confirme em até '+Math.ceil(seconds/60)+' minuto(s).':'Prazo de confirmação pode ter encerrado; consulte a 99Food.','gs-meta'))}
   if(d.receive_address){const a=d.receive_address;card.append(el('p',a.name||[a.first_name,a.last_name].filter(Boolean).join(' ')||'Cliente'),el('p',a.virtual_phone_number||a.phone||''),el('p',[a.poi_address||a['formatted Address'],a.house_number,a.complement,a.reference].filter(Boolean).join(' · ')))}
   items(card,d.order_items);if(d.remark)card.append(el('p','Observações: '+d.remark));
   if(d.price){card.append(el('p','Total do cliente: '+money(d.price.real_pay_price)),el('p','Valor a receber informado à loja: '+money(d.price.real_price),'gs-meta'));const due=self?d.price.customer_need_paying_money:d.price.shop_paid_money;if(Number(due)>0)card.append(el('strong','Valor a conferir no recebimento: '+money(due)+' · não baixado automaticamente.'))}
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
   button(actions,'Imprimir conferência',()=>print(order));card.append(actions);
   const history=el('details');history.append(el('summary','Histórico da integração'));
   for(const c of order.comandos||[])history.append(el('p',`${c.acao}: ${c.estado}${c.erro?' · '+c.erro:''}${c.request_id?' · protocolo '+c.request_id:''}`));
   for(const e of order.eventos||[])history.append(el('p',e.tipo+' · '+formatter.format(new Date(e.recebido_em))));card.append(history);orders.append(card);managed.push(card);
  }
 }
 try{await refresh()}catch(e){if(active())notify(e.message||'Não foi possível carregar os pedidos da 99Food.')}finally{initialRender=false}
 // Atualiza somente a lista local; não consulta a API da 99Food a cada tela.
 async function poll(){if(!active())return;if(!busy&&!document.hidden&&!(sharedGrid?root:section).querySelector('details[open]'))try{await refresh()}catch{}if(active())setTimeout(poll,15000)}
 setTimeout(poll,15000);
}

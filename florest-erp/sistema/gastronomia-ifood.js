import {normalizeOrder,sampleOrder,applyEvent} from './ifood/core.mjs';
const el=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e};
const money=v=>(v/100).toLocaleString('pt-BR',{style:'currency',currency:'BRL'});
export async function mountIFood(root,{rpc,catalog,current=()=>true,notice=()=>{},invoke=async()=>{throw Error('Conexão indisponível.')}}){
 let data,sim=null,history=null;
 const call=async(action,values={})=>{const r=await rpc(action,values);if(!current())throw Error('A tela ou a empresa mudou. Reabra a preparação.');return r};
 const section=(title,description)=>{const s=el('section');s.className='gs-section';s.append(el('h3',title));if(description)s.append(el('p',description));root.append(s);return s};
 function field(parent,label,value='',type='text'){const wrap=el('div'),input=el('input'),lab=el('label',label);input.type=type;input.value=value||'';input.id='ifood-'+crypto.randomUUID();lab.htmlFor=input.id;wrap.className='field';wrap.append(lab,input);parent.append(wrap);return input}
 function button(parent,label,fn){const b=el('button',label);b.type='button';b.className='btn-secondary';b.onclick=async()=>{b.disabled=true;try{await fn()}catch(e){notice(e.message||String(e))}finally{b.disabled=false}};parent.append(b);return b}
 function select(parent,label,choices,value){const s=el('select'),wrap=el('div'),lab=el('label',label);s.id='ifood-'+crypto.randomUUID();lab.htmlFor=s.id;for(const [v,t]of choices){const o=el('option',t);o.value=v;s.append(o)}s.value=value;wrap.className='field';wrap.append(lab,s);parent.append(wrap);return s}
 async function reload(){data=await call('obter');if(current())render()}
 function submit(form,label,fn){const b=el('button',label);b.type='submit';b.className='btn';form.append(b);form.onsubmit=async event=>{event.preventDefault();if(b.disabled)return;b.disabled=true;try{await fn()}catch(e){notice(e.message||String(e))}finally{b.disabled=false}}}
 function render(){
  root.replaceChildren();root.append(el('h2','iFood · Integração da Gastronomia'));
  const banner=el('p',data.conectado?'Conexão de testes ativa. Última consulta: '+(data.ultimo_poll?new Date(data.ultimo_poll).toLocaleString('pt-BR'):'aguardando'):'Conexão desativada. Configure as credenciais e teste a comunicação.');banner.className='msg';banner.setAttribute('role','status');root.append(banner);
  const cfg=section('Preparar loja','Você pode salvar a preparação sem CNPJ e sem credenciais. Selecionar produção não ativa a conexão.'),form=el('form');form.className='gs-form-grid';cfg.append(form);
  const name=field(form,'Nome da loja (opcional)',data.config.nome_loja);name.maxLength=120;
  const merchant=field(form,'ID da loja no iFood (opcional)',data.config.merchant_id);merchant.placeholder='Preencher quando o iFood fornecer';merchant.pattern='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
  const env=select(form,'Ambiente planejado',[['teste','Testes / homologação'],['producao','Produção — conexão bloqueada']],data.config.ambiente);
  submit(form,'Salvar preparação',async()=>{await call('salvar',{versao:data.versao,nome_loja:name.value.trim(),merchant_id:merchant.value.trim(),ambiente:env.value});await reload();notice('Preparação salva. A conexão continua desativada.')});
  if(data.ultimo_erro)root.append(el('p',data.ultimo_erro));
  const credentials=section('Conexão com o iFood','Credenciais protegidas no servidor e vinculadas somente a esta empresa. A ativação inicial é exclusiva da loja de testes autorizada.'),cf=el('form');cf.className='gs-form-grid';credentials.append(cf);
  const clientId=field(cf,'Client ID'),secret=field(cf,'Client Secret','','password');secret.autocomplete='new-password';clientId.required=secret.required=true;
  submit(cf,data.credenciais_configuradas?'Substituir credenciais':'Salvar credenciais',async()=>{try{await call('credenciais',{clientId:clientId.value.trim(),clientSecret:secret.value.trim()});notice('Credenciais salvas no servidor.')}finally{secret.value=''}await reload()});
  if(data.credenciais_configuradas){
   button(credentials,'Testar conexão e ativar testes',async()=>{await invoke('conectar');await reload();notice('Autenticação e acesso à loja validados. Conexão de testes ativada.')});
   if(data.conectado){button(credentials,'Consultar pedidos agora',async()=>{await invoke('sincronizar');await reload()});button(credentials,'Pausar conexão',async()=>{await call('pausar');await reload()})}
  }
  const mappings=section('Vínculo dos produtos e adicionais','Use o código externo do item no iFood para relacioná-lo ao produto desta empresa. Os preços recebidos no pedido serão preservados.'),mapForm=el('form');mapForm.className='gs-form-grid';mappings.append(mapForm);
  const kind=select(mapForm,'Tipo',[['produto','Produto'],['adicional','Adicional']],'produto'),code=field(mapForm,'Código externo no iFood');code.required=true;code.maxLength=100;
  const product=select(mapForm,'Produto do Gastronomia',[['','Selecione'],...catalog.filter(p=>p.ativo!==false).map(p=>[p.id,p.nome])],'');product.required=true;
  submit(mapForm,'Salvar vínculo',async()=>{await call('vincular',{versao:data.versao,tipo:kind.value,codigo_externo:code.value.trim(),produto_id:product.value,ativo:true});await reload();notice('Vínculo salvo.')});
  const list=el('div');mappings.append(list);
  if(!data.vinculos.length)list.append(el('p','Nenhum vínculo cadastrado.'));
  for(const m of data.vinculos){const row=el('p');row.append(el('span',(m.tipo==='produto'?'Produto':'Adicional')+' · '+m.codigo_externo+' → '+m.nome+(m.ativo?'':' · Desativado')+' '));button(row,m.ativo?'Desativar vínculo':'Reativar vínculo',async()=>{await call('vincular',{versao:data.versao,...m,ativo:!m.ativo});await reload()});list.append(row)}
  const test=section('Simulador local','Os exemplos existem apenas nesta tela. Não criam vendas, não movimentam estoque ou caixa e não imprimem.'),preview=el('div');preview.setAttribute('aria-live','polite');
  function show(offline){sim=normalizeOrder(sampleOrder(offline),data.vinculos);history=null;draw()}
  function draw(){preview.replaceChildren();if(!sim)return;preview.append(el('h4','SIMULAÇÃO · '+sim.numero),el('p','Total: '+money(sim.total)+' · Pago online: '+money(sim.pago_online)+' · A cobrar: '+money(sim.a_cobrar)),el('p','Dinheiro a cobrar: '+money(sim.dinheiro_a_cobrar)+' · Dinheiro lançado no caixa: '+money(sim.dinheiro_recebido)));
   for(const p of sim.pagamentos)if(p.troco_para)preview.append(el('p','Troco para '+money(p.troco_para)+': '+money(p.troco)));
   for(const i of sim.itens)preview.append(el('p',i.quantidade+' × '+i.nome+' · '+(i.produto_id?'Produto vinculado':'Pendente de vínculo')));
   for(const warning of sim.avisos)preview.append(el('p',warning));
   preview.append(el('p','Impressão prevista após confirmação: 2 vias na impressora única da Gastronomia.'));
   preview.append(el('p','Situação simulada: '+(history?.estado||'recebido')));
  }
  button(test,'Simular pedido pago online',()=>show(false));button(test,'Simular dinheiro com troco',()=>show(true));
  button(test,'Simular confirmação repetida',()=>{if(!sim)show(false);const event={id:'00000000-0000-4000-8000-000000000003',merchantId:sim.merchant_id,orderId:sim.id,code:'CFM',fullCode:'CONFIRMED',createdAt:new Date().toISOString()};history=applyEvent(applyEvent(history,event),event);draw();preview.append(el('p','Evento repetido ignorado: uma única confirmação.'))});test.append(preview);
  const pending=section('Antes de usar em produção','Esta liberação é de testes. A loja de produção depende da homologação do iFood e de liberação por empresa.');const ul=el('ul');for(const text of ['Cadastrar a aplicação centralizada no iFood Developer e autorizar a loja.','Configurar as credenciais somente no servidor.','Validar produtos, adicionais e modalidades com a loja de testes.','Concluir o processamento de eventos, presença, cancelamentos e negociações com a API real.','Validar caixa, estoque e duas vias de impressão na homologação antes da ativação.'])ul.append(el('li',text));pending.append(ul);
  const link=el('a','Documentação oficial do iFood');link.href='https://developer.ifood.com.br/pt-BR/';link.target='_blank';link.rel='noopener noreferrer';pending.append(link);
 }
 root.append(el('p','Carregando integração iFood…'));try{await reload()}catch(e){if(current()){root.replaceChildren(el('p','Não foi possível carregar a preparação iFood.'));throw e}}
}

export async function mountIFoodOrders(root,{rpc,current=()=>root.isConnected,notice=()=>{},open=()=>{},invoke=async()=>{throw Error('Consulta indisponível.')},canCancel=false}){
 async function reload(){
  const data=await rpc('pedidos');if(!current())return;root.replaceChildren();
  if(!data.conectado&&!data.pedidos.length&&!(data.falhas||[]).length)return;
  const title=el('h3','Pedidos iFood');root.append(title);for(const f of data.falhas||[])root.append(el('p','Pedido iFood '+(f.pedido_id||'')+' requer revisão: '+(f.erro||f.codigo)));
  const refresh=el('button','Atualizar pedidos iFood');refresh.type='button';refresh.onclick=()=>reload().catch(e=>notice(e.message));root.append(refresh);
  for(const p of data.pedidos){
   const box=el('article');box.className='gs-card gs-order gs-order--ifood';const n=p.normalizado||{};
   box.append(el('div','iFood','gs-order-channel gs-order-channel--ifood'),el('h4','#'+(n.numero||p.pedido_id)+' · '+p.estado_ifood),el('p',n.cliente||'Cliente iFood'),el('p','Total: '+money(n.total||0)+' · Pago no iFood: '+money(n.pago_online||0)+' · A cobrar: '+money(n.a_cobrar||0)));
   if(n.agendado)box.append(el('p','Agendado: '+new Date(n.inicio_preparo).toLocaleString('pt-BR')));
   for(const i of n.itens||[])box.append(el('p',i.quantidade+' × '+i.nome+' · Código iFood: '+(i.codigo||'não informado')+(i.produto_id?'':' — Pendente de vínculo')));
   for(const message of [...(n.avisos||[]),p.revisao_motivo,p.erro].filter(Boolean))box.append(el('p',message));
   if(p.negociacao)box.append(el('p','Negociação iFood: '+(p.negociacao.message||p.negociacao.status||'Requer atenção')+' · Prazo: '+(p.negociacao.expiresAt||'consulte o iFood')));
   if(p.atendimento_id){const b=el('button','Abrir atendimento');b.type='button';b.onclick=()=>open(p.atendimento_id);box.append(b)}
   const next={recebido:['confirmar','Confirmar pedido'],confirmado:['preparar','Iniciar preparo'],em_preparo:['pronto','Pedido pronto']};
   if(p.estado_ifood==='pronto'&&n.tipo==='DELIVERY'&&n.entrega_por==='MERCHANT')next.pronto=['despachar','Saiu para entrega'];
   const action=next[p.estado_ifood];
   if(action&&data.conectado){const [acao,label]=action,b=el('button',label);b.type='button';b.disabled=(acao==='confirmar'&&(n.avisos||[]).length>0)||(p.comandos||[]).some(c=>c.acao===acao&&['pendente','enviado','incerto','confirmado'].includes(c.estado));b.onclick=async()=>{b.disabled=true;try{await rpc('comando',{pedido_id:p.pedido_id,acao,chave:crypto.randomUUID()});notice('Comando registrado. Aguarde a confirmação do iFood.');await reload()}catch(e){notice(e.message);b.disabled=false}};box.append(b)}
   if(canCancel&&data.conectado&&!['cancelado','concluido'].includes(p.estado_ifood)){
    const cancel=el('button','Solicitar cancelamento no iFood');cancel.type='button';cancel.onclick=async()=>{cancel.disabled=true;try{
     const response=await invoke('motivos_cancelamento',{pedido_id:p.pedido_id});
     const reasons=Array.isArray(response.motivos)?response.motivos:(response.motivos?.reasons||response.motivos?.cancellationReasons||[]);
     if(!reasons.length)throw Error('O iFood não disponibilizou motivos de cancelamento para este pedido.');
     const select=el('select');for(const r of reasons){const o=el('option',r.description||r.reason||r.cancelCode||r.cancellationCode);o.value=r.cancelCode||r.cancellationCode||r.code||'';select.append(o)}
     const submit=el('button','Confirmar solicitação de cancelamento');submit.type='button';submit.onclick=async()=>{submit.disabled=true;try{if(!select.value)throw Error('Motivo inválido.');await rpc('comando',{pedido_id:p.pedido_id,acao:'solicitar_cancelamento',chave:crypto.randomUUID(),payload:{cancellationCode:select.value,reason:select.selectedOptions[0].textContent}});notice('Cancelamento solicitado. Aguarde o evento do iFood.');await reload()}catch(e){notice(e.message);submit.disabled=false}};
     box.append(select,submit);
    }catch(e){notice(e.message);cancel.disabled=false}};box.append(cancel);
   }
   if(canCancel&&p.negociacao?.disputeId&&Date.parse(p.negociacao.expiresAt)>Date.now()&&!p.negociacao.status){
    for(const [acao,label]of [['aceitar_negociacao','Aceitar negociação'],['recusar_negociacao','Recusar negociação']]){
     const b=el('button',label);b.type='button';b.disabled=(p.comandos||[]).some(c=>c.acao===acao&&['pendente','enviado','incerto','confirmado'].includes(c.estado));
     b.onclick=async()=>{b.disabled=true;try{const payload={disputeId:p.negociacao.disputeId};const reason=window.prompt('Informe o motivo da resposta à negociação:');if(!reason){b.disabled=false;return}payload.reason=reason;
      if(acao==='aceitar_negociacao'&&p.negociacao.acceptCancellationReasons?.length){notice('Esta negociação exige um motivo específico. Responda no Gestor iFood para selecionar o motivo correto.');b.disabled=false;return}
      await rpc('comando',{pedido_id:p.pedido_id,acao,chave:crypto.randomUUID(),payload});notice('Resposta registrada; aguarde a confirmação do iFood.');await reload()
     }catch(e){notice(e.message);b.disabled=false}};box.append(b);
    }
   }
   for(const c of p.comandos||[])box.append(el('p',c.acao+': '+c.estado+(c.estado==='incerto'?' — aguarde reconciliação; não repita o pedido.':'')));
   root.append(box);
  }
 }
 await reload();
}

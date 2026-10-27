const $=id=>document.getElementById(id),money=n=>Number(n||0).toLocaleString('pt-BR',{style:'currency',currency:'BRL'}),token=new URLSearchParams(location.hash.slice(1)).get('loja')||'',endpoint='https://etulhyboogqhyyevpnlo.supabase.co/functions/v1/gastronomia-cardapio',key='florest-cardapio:'+token;
let catalog,cart=[],pending=null,receipt=null,busy=false,category='',polling=false,tableIdentity=null;try{const saved=JSON.parse(localStorage.getItem(key)||'{}');cart=saved.cart||[];pending=saved.pending||null;receipt=saved.receipt||null}catch{}
const confirmationProtocol='cardapio-confirmacao-v2';
// Tentativas recuperadas sem prova v2 de recusa são incertas, inclusive as gravadas pela versão antiga.
if(pending){pending.resultado=pending.protocolo===confirmationProtocol&&pending.resultado==='rejeitado'?'rejeitado':'incerto';pending.protocolo=confirmationProtocol;save()}
function save(){localStorage.setItem(key,JSON.stringify({cart,pending,receipt}))}function el(tag,text,cls){const e=document.createElement(tag);if(text!=null)e.textContent=text;if(cls)e.className=cls;return e}function button(text,fn,cls){const b=el('button',text,cls);b.type='button';b.onclick=()=>Promise.resolve().then(fn).catch(error);return b}function error(e){$('erro').textContent=e.message||String(e);let s=$('conteudo').querySelector('[role=status]');if(!s){s=el('p','','notice');s.setAttribute('role','status');$('conteudo').prepend(s)}s.textContent=e.message||String(e)}
function validConfirmation(data,chave){return data&&typeof data==='object'&&!Array.isArray(data)&&data.protocolo===confirmationProtocol&&data.chave===chave&&Number.isInteger(data.numero)&&data.numero>0&&['mesa','entrega','retirada'].includes(data.tipo)&&typeof data.segredo==='string'&&/^[a-f0-9]{64}$/.test(data.segredo)&&typeof data.total==='number'&&Number.isFinite(data.total)&&data.total>=0&&typeof data.pagamento_confirmado==='boolean'}
async function api(acao,dados={},chave=null){const r=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({acao,token,dados,chave}),signal:AbortSignal.timeout(25000)});let data;try{data=await r.json()}catch{throw Error('Resultado desconhecido. Preserve a tentativa e repita a mesma confirmação.')}if(!r.ok||!data||data.error){const e=Error(typeof data?.error==='string'?data.error:'Não foi possível confirmar o resultado.');e.definitive=acao==='confirmar'&&r.status===422&&data?.protocolo===confirmationProtocol&&data.chave===chave&&data.resultado==='rejeitado'&&data.transacao==='revertida'&&data.codigo==='P0001';throw e}if(acao==='confirmar'&&!validConfirmation(data,chave))throw Error('Resposta incompleta ou incompatível. Preserve a tentativa e repita a mesma confirmação.');return data}
async function confirmPending(){if(!pending)throw Error('Não há confirmação pendente.');const attempt=pending,previouslyUnknown=attempt.resultado!=='novo'&&attempt.resultado!=='rejeitado';attempt.protocolo=confirmationProtocol;attempt.resultado='incerto';save();let response;try{response=await api('confirmar',attempt.dados,attempt.chave)}catch(e){if(pending===attempt){attempt.resultado=e.definitive&&!previouslyUnknown?'rejeitado':'incerto';save()}throw e}if(pending!==attempt)throw Error('A tentativa em andamento mudou. Reabra seu pedido para conferir.');receipt={...response,chave:attempt.chave};cart=[];pending=null;update();return response}
function discardRejectedAttempt(chave){if(!pending||pending.chave!==chave||pending.protocolo!==confirmationProtocol||pending.resultado!=='rejeitado')throw Error('O resultado continua pendente. Repita a mesma confirmação para recuperá-lo.');pending=null;save();cartView()}
function field(parent,name,type='text',value=''){const label=el('label',name),input=el(type==='select'?'select':type==='textarea'?'textarea':'input');input.id='campo-'+crypto.randomUUID();label.htmlFor=input.id;if(input.tagName==='INPUT')input.type=type;input.value=value;parent.append(label,input);return input}function select(parent,name,options){const s=field(parent,name,'select');for(const [v,t]of options){const o=el('option',t);o.value=v;s.append(o)}return s}function modal(title){$('conteudo').replaceChildren(el('h2',title));if(!$('modal').open)$('modal').showModal();return $('conteudo')}
function totals(type){const subtotal=cart.reduce((s,x)=>s+x.quantidade*x.preco,0),service=Math.round(subtotal*catalog.servico_percentual)/100,delivery=type==='entrega'?Number(catalog.taxa_entrega):0;return{subtotal,service,delivery,total:Math.round((subtotal+service+delivery)*100)/100}}
function update(){if(catalog&&!catalog.mesa)return deliveryUpdate();const n=cart.reduce((n,x)=>n+x.quantidade,0);$('ver-carrinho').textContent='Ver pedido ('+n+') · '+money(totals(catalog.mesa?'mesa':'retirada').total);$('acompanhar').hidden=!!catalog.mesa||!receipt;save()}
function render(){if(catalog.mesa&&!tableIdentity)return;const term=$('busca').value.trim().toLocaleLowerCase(),cats=catalog.categorias||[],ids=category?new Set([category]):null;if(ids){let size;do{size=ids.size;for(const c of cats)if(ids.has(c.pai))ids.add(c.id)}while(ids.size!==size)}const rows=catalog.produtos.filter(p=>term?p.nome.toLocaleLowerCase().includes(term):!ids||ids.has(p.categoria));for(const b of $('categorias').children)b.classList.toggle('active',b.dataset.category===category);$('produtos').replaceChildren();for(const p of rows){const card=el('article',null,'product');if(p.foto?.startsWith('https://')){const img=el('img');img.src=p.foto;img.alt=p.nome;img.loading='lazy';img.referrerPolicy='no-referrer';card.append(img)}else card.append(el('div',p.nome[0],'photo-empty'));const info=el('div',null,'info');info.append(el('h3',p.nome),el('p',cats.find(c=>c.id===p.categoria)?.nome||'Cardápio'),el('div',money(p.preco),'price'),button('Escolher',()=>choose(p)));card.append(info);$('produtos').append(card)}if(!rows.length)$('produtos').append(el('p','Nenhum produto disponível nesta seleção.'))}
function choose(p){if(!catalog.mesa)return deliveryChoose(p);if(catalog.mesa&&!tableIdentity)return tableIdentify();if(catalog.mesa&&(pending||cart.length))return tableCart();if(pending)throw Error('Resolva a confirmação pendente no carrinho antes de alterar o pedido.');const body=modal(p.nome),form=el('form');body.append(form,el('p','Preço-base '+money(p.preco)+'. Opções incluídas, sem adicional separado.'));const qty=field(form,'Quantidade','number',1);qty.min=1;qty.max=100;qty.step=1;qty.required=true;const choices=[];for(const g of p.grupos){form.append(el('h3',g.nome+' · escolha de '+g.minimo+' a '+g.maximo));for(let i=0;i<g.maximo;i++){const s=select(form,'Opção '+(i+1),[['','Selecione'],...g.opcoes.map(o=>[o.produto_id,o.nome])]);s.required=i<g.minimo;choices.push({g:g.id,nome:g.nome,s})}}const obs=field(form,'Observação','textarea');obs.maxLength=150;const add=el('button',catalog.mesa?'Enviar pedido':'Adicionar ao pedido');add.type='submit';form.append(add);form.onsubmit=async e=>{e.preventDefault();if(busy||!form.reportValidity())return;cart.push({bar_produto_id:p.id,nome:p.nome,preco:Number(p.preco),quantidade:Number(qty.value),observacao:obs.value,escolhas:choices.filter(x=>x.s.value).map(x=>({grupo_id:x.g,produto_id:x.s.value,nome:x.s.selectedOptions[0].textContent,grupo:x.nome}))});update();if(catalog.mesa){await tableSend();return}$('modal').close()}}
function cartView(){if(catalog.mesa)return tableCart();return deliveryCheckout()}
async function tracking(){if(catalog.mesa)return tableSuccess();if(!receipt||polling)return;polling=true;try{const r=await api('acompanhar',{segredo:receipt.segredo},receipt.chave),body=modal('Pedido #'+r.numero);body.append(el('p',(r.tipo==='mesa'?'Pedido enviado à sua mesa':r.tipo==='entrega'?'Entrega':'Retirada')+' · '+({pendente:'Recebido pelo estabelecimento',aguardando_retirada:'Pronto para retirada',aguardando_despacho:'Pronto, aguardando saída',saiu_entrega:'Saiu para entrega',retirado:'Retirado',entregue:'Entregue'}[r.andamento]||r.andamento)),el('p','Situação: '+r.estado),el('p','Valor deste pedido: '+money(r.total_pedido)),el('p',r.pagamento_confirmado?'Pagamento confirmado pelo estabelecimento.':'Forma escolhida: '+r.forma_escolhida+'. Confira o pagamento com o estabelecimento.'));body.append(button('Atualizar acompanhamento',tracking,'secondary'))}catch(e){error(e)}finally{polling=false}}

// O número da mesa vem somente do catálogo resolvido pelo token existente.
function tableIdentify(){
 try{const saved=JSON.parse(sessionStorage.getItem(key+':identificacao')||'null');if(saved&&saved.nome?.trim().length>=2&&saved.nome.length<=160&&/^[0-9]{10,13}$/.test(String(saved.telefone||'').replace(/\D/g,'')))tableIdentity={nome:saved.nome.trim(),telefone:saved.telefone}}catch{}
 const locked=!tableIdentity;for(const id of ['busca','categorias','produtos','ver-carrinho'])$(id).hidden=locked;$('acompanhar').hidden=true;$('fechar').hidden=locked;
 if(!locked){render();update();return}
 const body=modal('Identifique-se para acessar a Mesa '+catalog.mesa),form=el('form');body.append(form);
 const name=field(form,'Seu nome'),phone=field(form,'Telefone com DDD','tel');name.required=phone.required=true;name.minLength=2;name.maxLength=160;phone.maxLength=20;phone.autocomplete='tel';name.autocomplete='name';
 body.append(el('p','Seus dados identificam os pedidos desta sessão. O estabelecimento vincula seu cadastro ao confirmar o pedido.'));
 const submit=el('button','Acessar cardápio');submit.type='submit';form.append(submit);
 form.onsubmit=e=>{e.preventDefault();name.setCustomValidity(name.value.trim().length<2?'Informe seu nome.':'');phone.setCustomValidity(/^[0-9]{10,13}$/.test(phone.value.replace(/\D/g,''))?'':'Informe telefone com DDD.');if(!form.reportValidity())return;tableIdentity={nome:name.value.trim(),telefone:phone.value};try{sessionStorage.setItem(key+':identificacao',JSON.stringify(tableIdentity))}catch{}$('modal').close();tableIdentify()};name.oninput=()=>name.setCustomValidity('');phone.oninput=()=>phone.setCustomValidity('');
}
function tableSuccess(){const body=modal('Pedido enviado com sucesso!');body.append(button('Voltar ao cardápio',()=>{$('modal').close();render()}));$('erro').textContent='';}
function tableCart(){
 if(!tableIdentity)return tableIdentify();const body=modal(pending?'Recuperar envio à mesa':'Seu pedido');
 if(!cart.length&&!pending){body.append(el('p','Seu carrinho está vazio.'));return}
 for(const [i,x]of cart.entries()){const row=el('div',null,'cart-row');row.append(el('b',x.quantidade+' × '+x.nome+' · '+money(x.quantidade*x.preco)));for(const c of x.escolhas||[])row.append(el('p',c.grupo+': '+c.nome));if(x.observacao)row.append(el('p',x.observacao));if(!pending)row.append(button('Remover',()=>{cart.splice(i,1);update();tableCart()},'secondary'));body.append(row)}
 body.append(el('b','Total: '+money(pending?pending.dados.expected_total:totals('mesa').total)));
 const send=button(pending?'Repetir envio pendente':'Enviar pedido',tableSend);send.disabled=busy;body.append(send);
 if(pending){body.append(el('p','Repita para recuperar o resultado com a mesma chave e os mesmos dados, sem duplicar o pedido.','notice'));if(pending.resultado==='rejeitado'){const chave=pending.chave;body.append(button('Revisar após recusa confirmada',()=>discardRejectedAttempt(chave),'secondary'))}}
}
async function tableSend(){
 if(busy)return;if(!tableIdentity)return tableIdentify();if(!pending&&!cart.length)return;
 if(!pending){pending={chave:crypto.randomUUID(),protocolo:confirmationProtocol,resultado:'novo',dados:{tipo:'mesa',nome:tableIdentity.nome,telefone:tableIdentity.telefone,expected_total:totals('mesa').total,itens:cart.map(x=>({bar_produto_id:x.bar_produto_id,quantidade:x.quantidade,preco:x.preco,observacao:x.observacao,escolhas:x.escolhas.map(c=>({grupo_id:c.grupo_id,produto_id:c.produto_id}))}))}};save()}
 busy=true;for(const input of $('conteudo').querySelectorAll('button,input,select,textarea'))input.disabled=true;
 try{await confirmPending();tableSuccess()}catch(e){tableCart();error(e)}finally{busy=false;for(const b of $('conteudo').querySelectorAll('button'))b.disabled=false}
}

// Fluxo exclusivo do link geral; as rotinas de mesa permanecem independentes.
let deliveryDraft={},deliveryStorageWarning='';
const deliveryMethods=['Dinheiro','Pix','Cartão de Débito','Cartão de Crédito'];
function deliveryPersist(required=false){try{save();deliveryStorageWarning='';return true}catch{deliveryStorageWarning='Não foi possível salvar o pedido neste navegador. Libere o armazenamento antes de enviar.';if(required)throw Error(deliveryStorageWarning);return false}}
function deliveryDraftSave(){try{sessionStorage.setItem(key+':checkout',JSON.stringify(deliveryDraft))}catch{}}
function deliveryInit(){
 document.body.classList.add('delivery-menu');
 try{deliveryDraft=JSON.parse(sessionStorage.getItem(key+':checkout')||'null')||JSON.parse(sessionStorage.getItem(key+':identificacao')||'{}')}catch{deliveryDraft={}}
 if(!deliveryDraft||typeof deliveryDraft!=='object'||Array.isArray(deliveryDraft))deliveryDraft={};
 if(!['entrega','retirada'].includes(deliveryDraft.tipo)||catalog[deliveryDraft.tipo]===false)deliveryDraft.tipo=catalog.entrega?'entrega':'retirada';
 if(!Array.isArray(cart))cart=[];
 const summary=el('section',null,'delivery-order');summary.id='resumo-pedido';summary.setAttribute('aria-label','Resumo do pedido');$('produtos').after(summary);
 // Uma recusa comprovada pode voltar à edição. Um resultado incerto conserva a tentativa.
 deliveryReleaseRejected();
}
function deliveryItems(){return pending?pending.dados.itens.map(x=>({...x,nome:catalog.produtos.find(p=>p.id===x.bar_produto_id)?.nome||'Produto do pedido',escolhas:x.escolhas||[]})):cart}
function deliveryReleaseRejected(){if(pending?.protocolo===confirmationProtocol&&pending.resultado==='rejeitado'){
 if(!cart.length)cart=deliveryItems();pending=null;deliveryPersist();return true
}return false}
function deliveryTotals(){return totals(deliveryDraft.tipo||'retirada')}
function deliveryUpdate(){
 const items=deliveryItems(),n=items.reduce((sum,x)=>sum+Number(x.quantidade),0);$('ver-carrinho').textContent=(pending?'Recuperar envio pendente':'Finalizar pedido')+' ('+n+') · '+money(pending?pending.dados.expected_total:deliveryTotals().total);$('acompanhar').hidden=!receipt;
 deliveryPersist();deliverySummary($('resumo-pedido'),true);
}
function deliverySummary(parent,editable=false){
 if(!parent)return;parent.replaceChildren(el('h3','Resumo do pedido'));
 const items=deliveryItems();if(!items.length){parent.append(el('p','Nenhum produto selecionado. Escolha os produtos acima.'));return}
 for(const [i,x]of items.entries()){
  const row=el('div',null,'delivery-item'),info=el('div');info.append(el('b',x.nome),el('p',money(x.preco)+' por unidade · Subtotal '+money(x.quantidade*x.preco)));
  if(x.observacao)info.append(el('p',x.observacao));for(const c of x.escolhas||[])if(c.nome)info.append(el('p',(c.grupo?c.grupo+': ':'')+c.nome));row.append(info);
  if(editable&&!pending){const qty=field(row,'Quantidade de '+x.nome,'number',x.quantidade);qty.min=1;qty.max=100;qty.step=1;qty.required=true;qty.onchange=()=>{const value=Number(qty.value);qty.setCustomValidity(Number.isInteger(value)&&value>=1&&value<=100?'':'Informe uma quantidade de 1 a 100.');if(!qty.reportValidity())return;cart[i].quantidade=value;deliveryUpdate()};row.append(button('Remover '+x.nome,()=>{if(busy||pending)return;cart.splice(i,1);deliveryUpdate()},'secondary'))}else row.append(el('span','Quantidade: '+x.quantidade));
  parent.append(row);
 }
 if(pending){parent.append(el('b','Total da tentativa: '+money(pending.dados.expected_total)));return}
 const t=deliveryTotals(),box=el('div',null,'summary');box.append(el('div','Subtotal dos itens: '+money(t.subtotal)));if(t.service)box.append(el('div','Serviço '+catalog.servico_percentual+'%: '+money(t.service)));if(deliveryDraft.tipo==='entrega')box.append(el('div','Taxa de entrega: '+money(t.delivery)));box.append(el('b','Total: '+money(t.total)));parent.append(box);
}
function deliveryChoose(p){
 if(busy)return;if(pending&&!deliveryReleaseRejected())return deliveryCheckout();
 const body=modal(p.nome),form=el('form',null,'delivery-product-form');body.append(form);const qty=field(form,'Quantidade','number',1);qty.min=1;qty.max=100;qty.step=1;qty.required=true;const choices=[];
 for(const g of p.grupos||[]){form.append(el('h3',g.nome+' · escolha de '+g.minimo+' a '+g.maximo));for(let i=0;i<g.maximo;i++){const s=select(form,'Opção '+(i+1),[['','Selecione'],...g.opcoes.map(o=>[o.produto_id,o.nome])]);s.required=i<g.minimo;choices.push({g:g.id,nome:g.nome,s})}}
 const obs=field(form,'Observação (opcional)','textarea');obs.rows=2;obs.maxLength=150;const add=el('button','Adicionar ao pedido');add.type='submit';form.append(add);
 form.onsubmit=e=>{e.preventDefault();if(busy||pending||!form.reportValidity())return;cart.push({bar_produto_id:p.id,nome:p.nome,preco:Number(p.preco),quantidade:Number(qty.value),observacao:obs.value,escolhas:choices.filter(x=>x.s.value).map(x=>({grupo_id:x.g,produto_id:x.s.value,nome:x.s.selectedOptions[0].textContent,grupo:x.nome}))});deliveryUpdate();$('modal').close();$('erro').textContent=''};
}
function deliveryCheckout(){
 if(busy)return;deliveryReleaseRejected();const body=modal(pending?'Recuperar envio pendente':'Finalizar pedido');
 if(!cart.length&&!pending){body.append(el('p','Escolha pelo menos um produto para finalizar.'));return}
 const form=el('form',null,'delivery-checkout');form.noValidate=true;body.append(form);const fields={},messages={};
 function input(name,label,type='text',required=false,options){const wrap=el('div',null,'delivery-field'),id='checkout-'+name,lab=el('label',label+(required?' *':'')),node=el(options?'select':'input');node.id=id;lab.htmlFor=id;if(!options)node.type=type;else for(const [value,text]of options){const option=el('option',text);option.value=value;node.append(option)}node.value=deliveryDraft[name]||'';node.required=required;
  const message=el('small',null,'field-error');message.id=id+'-erro';node.setAttribute('aria-describedby',message.id);wrap.append(lab,node,message);form.append(wrap);fields[name]=node;messages[name]=message;
  node.oninput=()=>{deliveryDraft[name]=node.value;deliveryDraftSave();node.removeAttribute('aria-invalid');message.textContent=''};return node;
 }
 const type=input('tipo','Tipo de pedido','text',true,[...(catalog.entrega?[['entrega','Entrega']]:[]),...(catalog.retirada?[['retirada','Retirada no estabelecimento']]:[])]);
 const name=input('nome','Nome do cliente','text',true),phone=input('telefone','Telefone com DDD','tel',true);name.maxLength=160;name.autocomplete='name';phone.maxLength=20;phone.autocomplete='tel';
 const street=input('rua','Rua/Avenida','text',true),number=input('numero_endereco','Número (ou S/N)','text',true),district=input('bairro','Bairro','text',true),ref=input('referencia','Complemento ou referência (opcional)');street.maxLength=200;number.maxLength=20;district.maxLength=120;ref.maxLength=300;
 const method=input('forma','Forma de pagamento','text',true,[['','Selecione'],...deliveryMethods.map(x=>[x,x])]);
 const summary=el('section',null,'delivery-checkout-summary'),notice=el('p',null,'notice');notice.setAttribute('role','status');form.append(summary,notice,el('p','A forma escolhida não confirma pagamento. O estabelecimento confirma o recebimento.','delivery-help'));
 function show(){const delivery=type.value==='entrega';for(const f of [street,number,district,ref]){f.parentElement.hidden=!delivery;f.required=delivery&&f!==ref;if(!delivery){f.removeAttribute('aria-invalid');messages[Object.keys(fields).find(k=>fields[k]===f)].textContent=''}}deliveryDraft.tipo=type.value;deliveryDraftSave();deliverySummary(summary);deliveryUpdate()}
 type.onchange=()=>{deliveryDraft.tipo=type.value;show()};show();
 const submit=el('button',pending?'Repetir envio pendente':'Enviar pedido','wide');submit.type='submit';form.append(submit);
 if(pending){for(const [n,f]of Object.entries(fields)){f.value=pending.dados[n]||'';f.disabled=true}type.value=pending.dados.tipo;for(const f of [street,number,district,ref])f.parentElement.hidden=type.value!=='entrega';if(pending.dados.endereco)summary.append(el('p','Endereço enviado: '+pending.dados.endereco));notice.textContent='O resultado anterior ainda não foi confirmado. Repita a mesma tentativa para recuperar o pedido, sem duplicar. Os dados enviados serão preservados.'}
 const back=button('Continuar escolhendo produtos',()=>{$('modal').close();render()},'secondary');back.disabled=!!pending;body.append(back);
 function invalid(n,message){messages[n].textContent=message;fields[n].setAttribute('aria-invalid','true')}
 function validate(){for(const n of Object.keys(fields)){messages[n].textContent='';fields[n].removeAttribute('aria-invalid')}if(name.value.trim().length<2)invalid('nome','Informe seu nome (pelo menos 2 caracteres).');if(!/^(?:55)?[1-9][0-9][0-9]{8,9}$/.test(phone.value.replace(/\D/g,'')))invalid('telefone','Informe um telefone válido com DDD.');if(!deliveryMethods.includes(method.value))invalid('forma','Selecione uma forma de pagamento.');if(!['entrega','retirada'].includes(type.value)||catalog[type.value]===false)invalid('tipo','Selecione um tipo de pedido disponível.');if(type.value==='entrega'){if(street.value.trim().length<2)invalid('rua','Informe a rua ou avenida.');if(!/^(?:[0-9]+[A-Za-z0-9 /.-]*|S\s*\/?\s*N)$/i.test(number.value.trim()))invalid('numero_endereco','Informe o número ou S/N quando não houver número.');if(district.value.trim().length<2)invalid('bairro','Informe o bairro.')}const first=Object.keys(fields).find(n=>fields[n].getAttribute('aria-invalid')==='true');if(first)fields[first].focus();return !first}
 form.onsubmit=async e=>{
  e.preventDefault();if(busy)return;if(!pending&&!validate())return;
  for(const [n,f]of Object.entries(fields))if(!pending)deliveryDraft[n]=f.value;deliveryDraftSave();
  if(!pending){const delivery=type.value==='entrega';pending={chave:crypto.randomUUID(),protocolo:confirmationProtocol,resultado:'novo',dados:{tipo:type.value,nome:name.value.trim(),telefone:phone.value,rua:delivery?street.value.trim():'',numero_endereco:delivery?number.value.trim():'',bairro:delivery?district.value.trim():'',endereco:delivery?street.value.trim()+', '+number.value.trim()+' — '+district.value.trim():'',referencia:delivery?ref.value.trim():'',forma:method.value,expected_total:deliveryTotals().total,itens:cart.map(x=>({bar_produto_id:x.bar_produto_id,quantidade:x.quantidade,preco:x.preco,observacao:x.observacao,escolhas:x.escolhas.map(c=>({grupo_id:c.grupo_id,produto_id:c.produto_id}))}))}}}
  busy=true;submit.disabled=true;back.disabled=true;for(const f of Object.values(fields))f.disabled=true;notice.textContent='Enviando pedido…';
  try{await deliveryConfirmPending();deliverySuccess()}
  catch(e){notice.textContent=e.message||'Não foi possível confirmar o envio.';if(pending?.resultado==='rejeitado'){deliveryReleaseRejected();submit.textContent='Enviar pedido';for(const f of Object.values(fields))f.disabled=false;back.disabled=false}else{submit.textContent='Repetir envio pendente';back.disabled=true}deliveryUpdate()}
  finally{busy=false;submit.disabled=false}
 };
}
async function deliveryConfirmPending(){
 const attempt=pending;if(!attempt)throw Error('Não há envio pendente.');const previouslyUnknown=attempt.resultado!=='novo'&&attempt.resultado!=='rejeitado';attempt.protocolo=confirmationProtocol;
 // A chave e o conteúdo precisam estar salvos ANTES de qualquer requisição.
 deliveryPersist(true);attempt.resultado='incerto';deliveryPersist(true);let response;
 try{response=await api('confirmar',attempt.dados,attempt.chave)}catch(e){if(pending===attempt){attempt.resultado=e.definitive&&!previouslyUnknown?'rejeitado':'incerto';deliveryPersist()}throw e}
 if(pending!==attempt)throw Error('A tentativa em andamento mudou. Reabra a finalização.');receipt={...response,chave:attempt.chave};cart=[];pending=null;deliveryUpdate();return response;
}
function deliverySuccess(){const body=modal('Pedido recebido com sucesso!');body.append(el('p','Seu pedido foi recebido pelo estabelecimento.'),button('Voltar ao cardápio',()=>{$('modal').close();render()}));$('erro').textContent=''}

$('fechar').onclick=()=>{if(!busy&&(!catalog.mesa||tableIdentity))$('modal').close()};$('modal').addEventListener('cancel',e=>{if(busy||(catalog.mesa&&!tableIdentity))e.preventDefault()});$('busca').oninput=render;$('ver-carrinho').onclick=cartView;$('acompanhar').onclick=tracking;
try{if(!/^[a-f0-9]{64}$/.test(token))throw Error('Use o link ou QR Code fornecido pelo estabelecimento.');catalog=await api('catalogo');$('nome').textContent=catalog.nome;$('mesa').textContent=catalog.mesa?'Você está na Mesa '+catalog.mesa:'Entrega e retirada';const nav=$('categorias');const all=button('Todos',()=>{category='';render()});all.dataset.category='';nav.append(all);for(const c of [...catalog.categorias].sort((a,b)=>(a.ordem||0)-(b.ordem||0))){const b=button((c.pai?'↳ ':'')+c.nome,()=>{category=c.id;render()});b.dataset.category=c.id;nav.append(b)}if(catalog.mesa)tableIdentify();else{deliveryInit();render();update()}}catch(e){$('nome').textContent='Cardápio indisponível';error(e)}

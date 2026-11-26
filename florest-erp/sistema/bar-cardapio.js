const $=id=>document.getElementById(id),token=new URLSearchParams(location.hash.slice(1)).get('loja')||'',storage='florest-bar-menu:'+token,endpoint='https://etulhyboogqhyyevpnlo.supabase.co/functions/v1/bar-cardapio';
const el=(tag,text,cls)=>{const e=document.createElement(tag);if(text!=null)e.textContent=text;if(cls)e.className=cls;return e;},money=n=>Number(n).toLocaleString('pt-BR',{style:'currency',currency:'BRL'});
const novaPonteDigest='a0c20cd97e867886f2939a055ab06cda0631be85704fd6d9a395f550f3fe3118';
let cart=[],pending=null,receipt=null,busy=false,page=0,seq=0,timer;
try{const saved=JSON.parse(localStorage.getItem(storage)||'{}');cart=Array.isArray(saved.cart)?saved.cart:[];pending=saved.pending||null;receipt=saved.receipt||null;}catch{}
function save(){localStorage.setItem(storage,JSON.stringify({cart,pending,receipt}));}
function error(e){const text=e.message||String(e);$('erro').textContent=text;if($('modal').open){let box=$('conteudo').querySelector('[role=alert]');if(!box){box=el('p');box.setAttribute('role','alert');$('conteudo').prepend(box);}box.textContent=text;}}
function button(text,fn){const b=el('button',text);b.type='button';b.onclick=async()=>{if(b.disabled)return;b.disabled=true;try{await fn();}catch(e){error(e);}finally{if(b.isConnected)b.disabled=false;}};return b;}
function field(parent,label,type='text',value=''){const l=el('label',label),i=el(type==='select'?'select':type==='textarea'?'textarea':'input');i.setAttribute('aria-label',label);if(i.tagName==='INPUT')i.type=type;i.value=value;l.append(i);parent.append(l);return i;}
function select(parent,label,options){const s=field(parent,label,'select');for(const[v,t]of options)s.append(new Option(t,v));return s;}
function modal(title){$('conteudo').replaceChildren(el('h2',title));if(!$('modal').open)$('modal').showModal();$('erro').textContent='';return $('conteudo');}
const subtotal=x=>Math.round(Math.round(x.quantidade*10000)*Math.round(x.preco*100)/10000)/100,total=()=>Math.round(cart.reduce((n,x)=>n+Math.round(x.quantidade*10000)*Math.round(x.preco*100),0)/10000)/100;
function update(){save();$('carrinho').textContent=`Ver pedido (${cart.length}) · ${money(total())}`;$('acompanhar').hidden=!receipt;}
async function api(acao,dados={},chave=null){const res=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({acao,token,dados,chave}),signal:AbortSignal.timeout(25000)});let data;try{data=await res.json();}catch{throw Error('Não foi possível confirmar a resposta. Recupere o mesmo envio.');}if(!res.ok||data?.error){const e=Error(data?.error||'Falha ao consultar o estabelecimento.');e.definitive=res.status===422&&data?.resultado==='rejeitado'&&data?.chave===chave;throw e;}if(acao==='confirmar'&&(!Number.isInteger(data?.numero)||data.numero<=0||!/^[a-f0-9]{64}$/.test(data.segredo||'')||!Number.isFinite(data.total)))throw Error('Resposta incompleta. Recupere o mesmo envio.');return data;}
function imageSource(value){return typeof value==='string'&&(/^data:image\/(jpeg|png|webp);base64,/.test(value)||/^https:\/\//i.test(value))?value:null;}
function productPhoto(product,className='picture',eager=false){
 const src=imageSource(product.foto);if(!src)return el('div',product.nome.slice(0,2).toUpperCase(),className+' picture-placeholder');
 const img=el('img',null,className);img.src=src;img.alt=product.nome;img.loading=eager?'eager':'lazy';img.decoding='async';img.onerror=()=>img.replaceWith(el('div',product.nome.slice(0,2).toUpperCase(),className+' picture-placeholder'));return img;
}
async function applyNovaPonteTheme(){
 if(!globalThis.crypto?.subtle)return;
 const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(token));
 const hex=Array.from(new Uint8Array(digest),byte=>byte.toString(16).padStart(2,'0')).join('');
 if(hex!==novaPonteDigest)return;
 document.body.classList.add('nova-ponte');
 const scrollToMenu=()=>document.querySelector('.menu-section').scrollIntoView({block:'start'});
 const heroButton=$('nova-ponte-ver');
 heroButton.hidden=false;
 heroButton.onclick=scrollToMenu;
 const highlights=$('nova-ponte-destaques');
 for(const [name,query,image] of [
  ['Jantinha com espeto','JANTINHA','jantinha'],
  ['Picanha na chapa','PICANHA','picanha'],
  ['Torresmo com mandioca','TORRESMO','torresmo'],
 ]){
  const highlight=button(name,async()=>{
   $('busca').value=query;
   page=0;
   await render();
   $('produtos').scrollIntoView({block:'start'});
  });
  const photo=el('img');
  photo.src='./assets/nova-ponte/'+image+'.webp';
  photo.alt='';
  photo.loading='lazy';
  highlight.prepend(photo);
  highlights.append(highlight);
 }
 highlights.hidden=false;
 $('nova-ponte-fotos').hidden=false;
}
function storeIdentity(data){
 const themed=document.body.classList.contains('nova-ponte');
 $('loja').textContent=themed?'Restaurante Nova Ponte':data.nome;
 document.title=data.nome+' · Cardápio';
 $('descricao').textContent=themed&&data.descricao==='ABERTO DE TERÇA A DOMINGO, PEDIU CHEGOU'?'Aberto de terça a domingo. Pediu, chegou.':data.descricao||'';
 const initials=String(data.nome||'').split(/\s+/).filter(w=>w&&!['RESTAURANTE','BAR','DA','DE','DO','DOS','DAS','E'].includes(w.toUpperCase())).slice(0,2).map(w=>w[0]).join('').toUpperCase();
 $('marca-loja').textContent=initials||String(data.nome||'').slice(0,2).toUpperCase();
 const logo=$('logo-loja'),source=imageSource(data.logo);logo.hidden=!source;$('marca-loja').hidden=Boolean(source);
 if(source){logo.alt='Logo de '+data.nome;logo.src=source;logo.onerror=()=>{logo.hidden=true;$('marca-loja').hidden=false;};}else logo.removeAttribute('src');
 if(/^#[a-f0-9]{6}$/i.test(data.cor||'')){document.documentElement.style.setProperty('--brand',data.cor);$('cor-navegador').content=themed?'#8b2720':data.cor;}
 if(/^#[a-f0-9]{6}$/i.test(data.fundo||''))document.documentElement.style.setProperty('--paper',data.fundo);
 document.body.classList.toggle('grade',data.layout==='grade');
}
async function render(){
 const request=++seq,r=await api('catalogo',{busca:$('busca').value,pagina:page});if(request!==seq)return;storeIdentity(r);
 const products=r.produtos.slice(0,20);$('resumo-produtos').textContent=products.length?(r.produtos.length>20?'20 opções nesta página':products.length+' '+(products.length===1?'opção':'opções')):'Explore nossos sabores';
 $('produtos').replaceChildren();for(const [index,p]of products.entries()){
  const card=el('article',null,'product');card.append(productPhoto(p,'picture',index<4));if(p.categoria)card.append(el('small',p.categoria));card.append(el('h2',p.nome));if(p.descricao)card.append(el('p',p.descricao));
  const price=el('p',money(p.preco),'product-price');price.append(el('span','/ '+p.unidade));
  const chooseButton=button('Escolher',()=>choose(p));chooseButton.setAttribute('aria-label','Escolher '+p.nome);card.append(price,chooseButton);$('produtos').append(card);
 }
 if(!products.length)$('produtos').append(el('p','Nenhum produto disponível nesta busca.','menu-empty'));
 $('paginas').replaceChildren();if(page)$('paginas').append(button('Anteriores',async()=>{page--;await render();}));if(r.produtos.length>20)$('paginas').append(button('Próximos',async()=>{page++;await render();}));
}
function choose(p){if(pending)throw Error('Recupere o envio pendente antes de alterar seu pedido.');const body=modal(p.nome),form=el('form');if(imageSource(p.foto))body.append(productPhoto(p,'detail-picture',true));body.append(form);if(p.descricao)form.append(el('p',p.descricao));const kg=String(p.unidade).toUpperCase()==='KG',fractional=['KG','G','LT','L','M'].includes(String(p.unidade).toUpperCase()),qty=field(form,kg?'Peso desejado (gramas)':`Quantidade (${p.unidade})`,'number',kg?'500':'1');qty.min=kg?1:fractional?.0001:1;qty.max=kg?99000:99;qty.step=kg?1:fractional?.0001:1;qty.required=true;form.append(el('p',money(p.preco)+(kg?' por kg':'')));const fields=[];for(const g of p.grupos||[]){const box=el('fieldset');box.append(el('legend',g.nome));form.append(box);for(let n=0;n<g.quantidade;n++){const s=select(box,`${g.nome} · escolha ${n+1}`,[['','Selecione'],...g.opcoes.map(o=>[o.id,o.nome])]);s.required=true;fields.push({s,g});}}
 const note=field(form,'Observação do item','textarea');note.maxLength=300;const add=el('button','Adicionar ao pedido');add.type='submit';form.append(add);form.onsubmit=e=>{e.preventDefault();try{if(pending)throw Error('Recupere o envio pendente.');if(cart.length>=30)throw Error('O pedido aceita até 30 itens.');if(!form.reportValidity())return;const amount=Number(qty.value)/(kg?1000:1);if(!Number.isFinite(amount)||amount<=0||amount>99)throw Error('Informe uma quantidade válida.');cart.push({bar_produto_id:p.id,nome:p.nome,unidade:p.unidade,quantidade:amount,preco:Number(p.preco),observacao:note.value.trim(),escolhas:fields.map(({s,g})=>({grupo_id:g.id,produto_id:s.value})),escolhas_nomes:fields.map(({s,g})=>g.opcoes.find(o=>o.id===s.value).nome)});update();$('modal').close();}catch(e){error(e);}};}
function checkout(){const body=modal(pending?'Recuperar envio do pedido':'Seu pedido');if(!cart.length&&!pending){body.append(el('p','Seu pedido está vazio.'));return;}for(const[i,x]of cart.entries()){const row=el('div',null,'cart-line');row.append(el('strong',`${x.quantidade} × ${x.nome} · ${money(subtotal(x))}`));if(x.escolhas_nomes?.length)row.append(el('small',x.escolhas_nomes.join(', ')));if(x.observacao)row.append(el('small',x.observacao));if(!pending)row.append(button('Remover '+x.nome,()=>{cart.splice(i,1);update();checkout();}));body.append(row);}body.append(el('h3','Total: '+money(pending?.dados.total??total())));if(pending){body.append(el('p','Recupere este envio para saber se o estabelecimento já recebeu, sem duplicar o pedido.'),button('Recuperar envio',send));return;}const form=el('form');body.append(form);const name=field(form,'Seu nome'),phone=field(form,'Telefone','tel'),mode=select(form,'Como deseja receber?',[['','Selecione'],['retirada','Vou buscar — retirada'],['entrega','Quero receber — entrega']]),address=field(form,'Seu endereço completo','textarea'),note=field(form,'Observação do pedido','textarea');name.required=phone.required=mode.required=address.required=true;name.minLength=2;name.maxLength=100;phone.maxLength=20;address.maxLength=500;address.minLength=5;address.placeholder='Rua, número, bairro, cidade e complemento';address.autocomplete='street-address';note.maxLength=500;const submit=el('button','Enviar pedido');submit.type='submit';form.append(submit);form.onsubmit=e=>{e.preventDefault();if(busy||!form.reportValidity())return;pending={chave:crypto.randomUUID(),enviado:false,dados:{nome:name.value.trim(),telefone:phone.value,modalidade:mode.value,endereco:address.value.trim(),observacao:note.value,total:total(),itens:cart.map(({nome,unidade,escolhas_nomes,...x})=>x)}};try{save();}catch(err){pending=null;error(Error('Libere o armazenamento do navegador antes de enviar.'));return;}send().catch(error);};}
async function send(){if(busy||!pending)return;busy=true;const previous=pending.enviado;pending.enviado=true;try{save();for(const i of $('conteudo').querySelectorAll('button,input,textarea,select'))i.disabled=true;const result=await api('confirmar',pending.dados,pending.chave);receipt={...result,chave:pending.chave};pending=null;cart=[];update();const body=modal('Pedido '+result.numero+' enviado!');body.append(el('p','Seu pedido chegou ao estabelecimento. O pagamento será confirmado pelo caixa.'),el('strong','Total: '+money(result.total)),button('Acompanhar pedido',tracking));}catch(e){if(e.definitive&&!previous){pending=null;save();}checkout();error(e);}finally{busy=false;for(const i of $('conteudo').querySelectorAll('button,input,textarea,select'))i.disabled=false;}}
async function tracking(){if(!receipt)return;const r=await api('acompanhar',{segredo:receipt.segredo},receipt.chave),body=modal('Pedido '+r.numero),labels={recebido:'Recebido pelo estabelecimento',preparando:'Em preparo',pronto:'Pronto',saiu:'Saiu para entrega',finalizado:'Pedido finalizado',cancelado:'Pedido recusado pelo estabelecimento'};body.append(el('p',labels[r.estado]||'Aguardando atualização'),el('p','Total: '+money(r.total)),button('Atualizar andamento',tracking));}
$('fechar').onclick=()=>$('modal').close();$('carrinho').onclick=()=>{try{checkout();}catch(e){error(e);}};$('acompanhar').onclick=()=>tracking().catch(error);$('busca').oninput=()=>{seq++;clearTimeout(timer);page=0;timer=setTimeout(()=>render().catch(error),300);};
try{if(!/^[a-f0-9]{64}$/.test(token))throw Error('Use o link ou QR Code fornecido pela loja.');update();await applyNovaPonteTheme();await render();}catch(e){$('loja').textContent='Cardápio indisponível';error(e);}

document.querySelector('.skip-link').onclick=e=>{e.preventDefault();$('produtos').tabIndex=-1;$('produtos').focus();$('produtos').scrollIntoView({block:'start'});};

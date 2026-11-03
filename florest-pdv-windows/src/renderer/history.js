"use strict";
// Operações do histórico reaproveitadas do PDV main; RPCs preservam permissões do ERP.
async function openErpHistory() {
 modal("Histórico de vendas do ERP", '<input id="pdvh-busca" placeholder="Número ou cliente"><button id="pdvh-buscar">Buscar</button><div id="pdvh-msg"></div><div id="pdvh-lista"></div><button id="pdvh-mais">Mais vendas</button><div id="pdvh-detalhe"></div>');
 const formatarReais = brl;
 const supabase={
  rpc:async(name,args)=>{try{return {data:await remote(name,args),error:null};}catch(error){return {data:null,error};}},
  from(table){let found=table==="produtos"?state.produtos:state.clientes;return {
   select(){return this;},
   or(expr){const term=expr.match(/ilike\.%([^%]*)%/)?.[1]?.toLowerCase()||"";found=found.filter(p=>[p.nome,p.codigo,p.referencia,p.gtin].some(v=>String(v??"").toLowerCase().includes(term)));return this;},
   ilike(field,value){const term=value.replaceAll("%", "").toLowerCase();found=found.filter(p=>String(p[field]||"").toLowerCase().includes(term));return this;},
   async limit(n){return {data:found.slice(0,n),error:null};}
  };}
 };
let pdvhOffset=0,pdvhData=null,pdvhItens=[],pdvhPag=[];
const pdvhEl=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=String(text);return e;};
const pdvhMoney=n=>formatarReais(Number(n)||0);
function pdvhAviso(s){$('pdvh-msg').textContent=s||'';}
async function pdvhListar(reset){
 try{
  if(reset){pdvhOffset=0;$('pdvh-lista').replaceChildren();$('pdvh-detalhe').replaceChildren();}
  const {data,error}=await supabase.rpc('pdv_historico_listar',{p_busca:$('pdvh-busca').value.trim()||null,p_limite:100,p_offset:pdvhOffset});if(error)throw error;
  for(const v of data||[]){const line=pdvhEl('div');line.style.cssText='padding:10px;border-bottom:1px solid var(--border);display:flex;gap:12px;justify-content:space-between;flex-wrap:wrap';line.append(pdvhEl('span','#'+v.numero_venda+' · '+new Date(v.criado_em).toLocaleString('pt-BR')+' · '+v.cliente_nome+' · '+pdvhMoney(v.total)+(v.cancelada_em?' · Cancelada':'')));const b=pdvhEl('button','Detalhes');b.className='btn-secondary';b.onclick=()=>pdvhAbrir(v.id);line.append(b);$('pdvh-lista').append(line);}
  pdvhOffset+=(data||[]).length;$('pdvh-mais').classList.toggle('hidden',(data||[]).length<100);pdvhAviso('');
 }catch(e){pdvhAviso(e.message||e);}
}
async function pdvhAbrir(id){
 try{const {data,error}=await supabase.rpc('pdv_historico_detalhar',{p_venda:id});if(error)throw error;pdvhData=data;pdvhItens=(data.itens||[]).map(i=>({produto_id:i.produto_id,nome:i.nome,quantidade:Number(i.quantidade),preco_unitario:Number(i.preco_unitario)}));pdvhPag=(data.pagamentos||[]).map(p=>({forma_pagamento:p.forma_pagamento,valor:Number(p.valor)}));pdvhRender();}catch(e){pdvhAviso(e.message||e);}
}
function pdvhRender(){
 const d=pdvhData,root=$('pdvh-detalhe');root.replaceChildren();if(!d)return;
 root.append(pdvhEl('h3','Venda #'+d.venda.numero_venda),pdvhEl('p','Cliente: '+(d.cliente_nome||'Consumidor')+' · '+pdvhMoney(d.venda.total)));
 if(!d.editavel)root.append(pdvhEl('p','Somente consulta: esta venda não permite edição ou exclusão.'));
 const table=(name,arr,fields)=>{root.append(pdvhEl('h4',name));for(let i=0;i<arr.length;i++){const r=arr[i],line=pdvhEl('div');line.style.cssText='display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0';if(name==='Produtos')line.append(pdvhEl('span',r.nome));for(const f of fields){if(!d.editavel)line.append(pdvhEl('span',f+': '+r[f]));else if(f==='forma_pagamento'){const sel=pdvhEl('select');for(const x of ['Dinheiro','Pix','Cartão de Débito','Cartão de Crédito']){const o=pdvhEl('option',x);o.value=x;sel.append(o)}sel.value=r[f];sel.onchange=()=>r[f]=sel.value;line.append(sel);}else{const input=pdvhEl('input');input.type='number';input.min=f==='quantidade'?'0.0001':'0.01';input.step=f==='quantidade'?'0.0001':'0.01';input.value=r[f];input.style.width='100px';input.onchange=()=>r[f]=Number(input.value);line.append(input);}}if(d.editavel){const b=pdvhEl('button','Remover');b.className='btn-secondary';b.onclick=()=>{arr.splice(i,1);pdvhRender()};line.append(b)}root.append(line);}};
 table('Produtos',pdvhItens,['quantidade','preco_unitario']);table('Pagamentos',pdvhPag,['forma_pagamento','valor']);
 if(!d.editavel)return;
 const addP=pdvhEl('button','+ Pagamento');addP.className='btn-secondary';addP.onclick=()=>{pdvhPag.push({forma_pagamento:'Dinheiro',valor:0});pdvhRender()};root.append(addP);
 const search=pdvhEl('input');search.placeholder='Nome ou código do produto';search.type='search';const found=pdvhEl('div');const find=pdvhEl('button','Buscar produto');find.className='btn-secondary';find.onclick=async()=>{const term=search.value.trim().replace(/[%,()]/g,'');if(!term)return;const {data,error}=await supabase.from('produtos').select('id,nome,codigo,preco_venda').or('nome.ilike.%'+term+'%,codigo.ilike.%'+term+'%').limit(15);if(error){pdvhAviso(error.message);return}found.replaceChildren();for(const p of data||[]){const b=pdvhEl('button',p.nome+' · '+pdvhMoney(p.preco_venda));b.className='btn-secondary';b.onclick=()=>{pdvhItens.push({produto_id:p.id,nome:p.nome,quantidade:1,preco_unitario:Number(p.preco_venda)});pdvhRender()};found.append(b)}};root.append(pdvhEl('h4','Adicionar produto'),search,find,found);
 const customer=pdvhEl('input');customer.type='search';customer.placeholder='Buscar cliente (opcional)';const sel=pdvhEl('select');const empty=pdvhEl('option','Consumidor');empty.value='';sel.append(empty);if(d.venda.cliente_id){const op=pdvhEl('option',d.cliente_nome);op.value=d.venda.cliente_id;sel.append(op);sel.value=op.value}
 const cb=pdvhEl('button','Buscar cliente');cb.className='btn-secondary';cb.onclick=async()=>{const t=customer.value.trim().replace(/[%,()]/g,'');const {data,error}=await supabase.from('clientes').select('id,nome').ilike('nome','%'+t+'%').limit(30);if(error){pdvhAviso(error.message);return}sel.replaceChildren(empty);for(const c of data||[]){const op=pdvhEl('option',c.nome);op.value=c.id;sel.append(op)}};root.append(pdvhEl('h4','Cliente'),customer,cb,sel);
 for(const del of [false,true]){const b=pdvhEl('button',del?'Excluir venda':'Salvar alterações');b.className=del?'btn-secondary':'btn-accent';b.style.margin='8px';b.onclick=async()=>{
 if(!confirm(del?'Confirma excluir esta venda?':'Confirma salvar as alterações?'))return;
 try{const {error}=await supabase.rpc('pdv_historico_alterar',{p_venda:d.venda.id,p_itens:pdvhItens.map(({produto_id,quantidade,preco_unitario})=>({produto_id,quantidade,preco_unitario})),p_pagamentos:pdvhPag,p_cliente:sel.value||null,p_excluir:del});if(error)throw error;await pdvhListar(true);await pdvhAbrir(d.venda.id);pdvhAviso('Operação concluída.');}catch(e){pdvhAviso(e.message||e)}};root.append(b);}
}

 $('pdvh-buscar').onclick=()=>pdvhListar(true);$('pdvh-mais').onclick=()=>pdvhListar(false);$('pdvh-busca').onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();pdvhListar(true)}};
 await pdvhListar(true);
}

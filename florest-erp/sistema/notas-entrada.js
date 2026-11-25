// Somente vinculação e conversão da entrada de XML. Nenhuma escrita direta no estoque.
function scaled(value,places,label){const s=String(value??'').trim().replace(',','.').replace(/^\./,'0.');if(!/^\d+(\.\d+)?$/.test(s))throw Error(label+' inválido.');const [whole,fraction='']=s.split('.');if(fraction.slice(places).replace(/0/g,''))throw Error(label+' aceita até '+places+' casas decimais.');return BigInt(whole)*10n**BigInt(places)+BigInt(fraction.slice(0,places).padEnd(places,'0')||'0')}
function decimal(value,places){const s=value.toString().padStart(places+1,'0');return (s.slice(0,-places)+'.'+s.slice(-places)).replace(/\.?0+$/,'')}
const unit=value=>String(value||'').trim().toUpperCase();
export function neCalcularConversao(item,product){const received=scaled(item.quantidade_recebida??item.quantidade,4,'Quantidade recebida'),original=scaled(item.quantidade,4,'Quantidade do XML'),factor=scaled(item.fator_conversao??1,6,'Fator'),total=scaled(item.valor_total,2,'Valor do item');if(received<=0n||received>99999999999999n||factor<=0n||factor>1000000000000n)throw Error('Informe quantidade e fator positivos dentro dos limites.');const multiplied=received*factor;if(multiplied%1000000n)throw Error('A quantidade de estoque resultante precisa ter até quatro casas decimais.');const quantity=multiplied/1000000n;if(quantity<=0n||quantity>99999999999999n)throw Error('Quantidade de estoque fora do limite.');const purchase=unit(item.unidade_compra??item.unidade_comercial),stock=unit(product?.unidade_comercial||item.unidade_estoque||item.unidade_comercial);if(!purchase||!stock||purchase.length>10||stock.length>10)throw Error('Informe unidade de compra e unidade de estoque válidas.');const cost=(total*1000000n+quantity/2n)/quantity;if(cost>99999999999999n)throw Error('Custo unitário fora do limite.');return {recebida:decimal(received,4),fator:decimal(factor,6),quantidade:decimal(quantity,4),custo:decimal(cost,4),unidadeCompra:purchase,unidadeEstoque:stock,exigeConfirmacao:received!==original||factor!==1000000n||purchase!==stock}}
export function neDadosConversao(item,product){if(item.vinculo_fornecedor_id&&!item.produto_id)throw Error('Este código do fornecedor já possui vínculo. Selecione o produto correto antes de confirmar.');const c=neCalcularConversao(item,product);if(c.exigeConfirmacao&&item.conversao_confirmada!==true)throw Error('Confira e confirme a conversão deste item.');return {quantidade_recebida:c.recebida,unidade_compra:c.unidadeCompra,fator_conversao:c.fator,unidade_estoque:c.unidadeEstoque,quantidade_estoque_entrada:c.quantidade,conversao_confirmada:item.conversao_confirmada===true}}
export async function neBuscarProdutos(client,{term='',page=0,gtins=null,signal}={}){let query=client.rpc('notas_entrada_produtos_buscar',{p_termo:term.trim(),p_pagina:page,p_gtins:gtins});if(signal&&query.abortSignal)query=query.abortSignal(signal);const {data,error}=await query;if(error){if(error.code==='PGRST202'||error.code==='42883')throw Error('A correção de Notas de Entrada ainda não foi instalada no banco. Confira o SQL desta entrega.');throw error}if(!data||data.versao!=='ne_20261026_v1'||!Array.isArray(data.produtos))throw Error('Versão incompatível da pesquisa/conversão de Notas de Entrada.');return data}
export async function neCarregarGtins(client,items){const gtins=[...new Set(items.map(i=>i.gtin).filter(g=>/^\d{8,14}$/.test(g||'')))],found={};for(let i=0;i<gtins.length;i+=100){const data=await neBuscarProdutos(client,{gtins:gtins.slice(i,i+100)});for(const p of data.produtos)found[p.gtin.replace(/^0+/,'')]=p}return found}
// Resolve GTIN primeiro e, na ausência, o vínculo prévio do fornecedor, antes da prévia.
export async function nePrepararVinculos(client,dados){
 const byGtin=await neCarregarGtins(client,dados.itens),byCode={},products={};
 const codes=[...new Set(dados.itens.map(i=>String(i.codigo_fornecedor||'').trim()).filter(Boolean))];
 if(dados.fornecedor.id)for(let offset=0;offset<codes.length;offset+=100){
  const {data,error}=await client.rpc('notas_entrada_produtos_vinculados',{p_fornecedor:dados.fornecedor.id,p_codigos:codes.slice(offset,offset+100)});
  if(error){if(['PGRST202','42883'].includes(error.code))throw Error('A atualização dos vínculos de Notas de Entrada ainda não está disponível. Atualize a página após a instalação.');throw error}
  if(data?.versao!=='ne_vinculos_20261119_v1'||!Array.isArray(data.vinculos))throw Error('Resposta incompatível dos vínculos do fornecedor.');
  for(const link of data.vinculos){if(link.produto?.id)byCode[link.codigo_fornecedor]=link.produto}
 }
 const itens=dados.itens.map(item=>{const gtin=item.gtin?byGtin[item.gtin.replace(/^0+/,'')]:null,match=gtin||byCode[String(item.codigo_fornecedor||'').trim()];if(match)products[match.id]=match;return {...item,produto_id:match?.id||null,vinculo_fornecedor_id:byCode[String(item.codigo_fornecedor||'').trim()]?.id||null,vinculo_origem:gtin?'gtin':match?'fornecedor':null,quantidade_recebida:item.quantidade,unidade_compra:item.unidade_comercial,fator_conversao:1,unidade_estoque:match?.unidade_comercial||item.unidade_comercial,conversao_confirmada:false}});
 return {itens,produtosPorId:products};
}
const make=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e};
export function neMontarPesquisa(root,{client,selected,onSelect,onCreate,isCurrent=()=>true,delay=300}){const label=make('label','Pesquisar produto por nome, código interno ou GTIN'),input=make('input'),current=make('p'),status=make('p'),results=make('div'),pages=make('div'),create=make('button','Cadastrar novo produto');input.type='search';input.placeholder='Digite para pesquisar em todo o cadastro';input.autocomplete='off';input.id='ne-busca-'+crypto.randomUUID();label.htmlFor=input.id;status.setAttribute('role','status');results.style.cssText='max-height:230px;overflow:auto;display:grid;gap:5px';current.style.cssText='font-size:12px;font-weight:600';create.type='button';create.className='btn-secondary';root.append(label,input,current,status,results,pages,create);let timer,generation=0,controller,page=0;const selectedText=()=>current.textContent=selected?'Vinculado: '+selected.nome+(selected.ativo===false?' (INATIVO)':''):'Novo produto: será cadastrado ao confirmar a entrada.';selectedText();function invalidate(){generation++;clearTimeout(timer);controller?.abort()}
 async function search(next=0){invalidate();const run=generation,term=input.value.trim();page=next;results.replaceChildren();pages.replaceChildren();if(!term){status.textContent='Digite nome, código ou GTIN. O vínculo atual é preservado.';return}if(!isCurrent())return;controller=new AbortController();status.textContent='Pesquisando…';try{const data=await neBuscarProdutos(client,{term,page,signal:controller.signal});if(run!==generation||!isCurrent())return;for(const p of data.produtos){const b=make('button',p.nome+' · Código '+(p.codigo||'—')+' · GTIN '+(p.gtin||'—')+' · '+(p.unidade_comercial||'sem unidade'));b.type='button';b.className='btn-secondary';b.style.textAlign='left';b.onclick=()=>{if(!isCurrent())return;selected=p;selectedText();onSelect(p);invalidate();results.replaceChildren();pages.replaceChildren();status.textContent='Produto vinculado.'};results.append(b)}status.textContent=data.produtos.length?data.produtos.length+' resultado(s) · página '+(page+1):'Nenhum produto encontrado nesta pesquisa.';for(const [text,n,enabled]of [['Anterior',page-1,page>0],['Próxima',page+1,data.tem_mais===true]]){const b=make('button',text);b.type='button';b.disabled=!enabled;b.className='btn-secondary';b.onclick=()=>search(n);pages.append(b)}}catch(e){if(run===generation&&isCurrent()&&e.name!=='AbortError')status.textContent='Falha na pesquisa: '+(e.message||e)}}
 input.oninput=()=>{invalidate();results.replaceChildren();pages.replaceChildren();status.textContent='Aguardando digitação…';timer=setTimeout(()=>search(0),delay)};input.onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();search(0)}};create.onclick=()=>onCreate(unidade=>{if(!isCurrent())return;invalidate();selected=null;selectedText();results.replaceChildren();pages.replaceChildren();status.textContent='Cadastro preparado para confirmar com a nota.';onSelect(null,unidade)});return {input,search,dispose:invalidate}}
export function neAbrirCadastro(root,item,onSave){
 const dialog=make('dialog'), form=make('form'), title=make('h3','Cadastrar produto pela nota');
 const name=make('p',item.descricao), label=make('label','Unidade de estoque'), stock=make('input');
 const cancel=make('button','Cancelar'), save=make('button','Usar novo produto');
 dialog.className='ne-cadastro-produto';
 dialog.setAttribute('aria-label',title.textContent);
 stock.value=item.produto_id?item.unidade_comercial:item.unidade_estoque;
 stock.required=true;
 stock.pattern='.*[^\\s].*';
 stock.maxLength=10;
 stock.id='ne-cadastro-'+crypto.randomUUID();
 label.htmlFor=stock.id;
 cancel.type='button';
 cancel.className='btn-secondary';
 save.type='submit';
 save.className='btn-primary';
 form.append(title,name,label,stock,cancel,save);
 dialog.append(form);
 root.append(dialog);
 cancel.onclick=()=>dialog.close();
 form.onsubmit=e=>{e.preventDefault();onSave(unit(stock.value));dialog.close()};
 dialog.addEventListener('close',()=>dialog.remove(),{once:true});
 dialog.showModal();
}

export function neMontarConversao(root,item,{getProduct,canEditPrice=true,onChange}){
 const fields={};
 function field(text,type,value,group=root){
  const label=make('label',text), input=make('input');
  input.type=type;
  input.value=value??'';
  input.id='ne-conversao-'+crypto.randomUUID();
  label.htmlFor=input.id;
  label.append(input);
  group.append(label);
  return input;
 }
 fields.received=field('Quantidade recebida','number',item.quantidade_recebida??item.quantidade);
 fields.received.min='.0001';
 fields.received.step='.0001';
 fields.purchase=field('Unidade recebida','text',item.unidade_compra??item.unidade_comercial);
 fields.purchase.maxLength=10;
 fields.factor=field('Unidades por embalagem','number',item.fator_conversao??1);
 fields.factor.min='.000001';
 fields.factor.step='.000001';
 fields.stock=field('Unidade de estoque','text',getProduct()?.unidade_comercial||item.unidade_estoque||item.unidade_comercial);
 fields.stock.maxLength=10;
 fields.stock.readOnly=!!getProduct()?.unidade_comercial;
 const preview=make('p'), prices=make('div'), cost=make('output'), costLabel=make('div');
 prices.className='ne-precos';
 costLabel.append(make('span','Custo por unidade'),cost);
 prices.append(costLabel);
 const price=field('Preço de venda por unidade (R$)','number','',prices);
 price.min='0';
 price.step='.01';
 price.max='999999999999.99';
 const ackLabel=make('label'), ack=make('input');
 ack.type='checkbox';
 ack.checked=item.conversao_confirmada===true;
 ackLabel.className='ne-confirmar-conversao';
 ackLabel.append(ack,make('span','Confirmar quantidade convertida'));
 root.append(preview,prices,ackLabel);
 function showPrice(){
  const product=getProduct();
  price.value=product?.preco_venda??'';
  price.readOnly=!!product&&!canEditPrice;
 }
 function refresh(){
  item.quantidade_recebida=fields.received.value;
  item.unidade_compra=unit(fields.purchase.value);
  item.fator_conversao=fields.factor.value;
  item.unidade_estoque=unit(fields.stock.value);
  item.conversao_confirmada=ack.checked;
  try{
   const c=neCalcularConversao(item,getProduct());
   preview.textContent=c.recebida+' '+c.unidadeCompra+' × '+c.fator+' = '+c.quantidade+' '+c.unidadeEstoque+' no estoque';
   const formatted=Number(c.custo).toLocaleString('pt-BR',{style:'currency',currency:'BRL',maximumFractionDigits:4});
   cost.textContent=formatted+' / '+c.unidadeEstoque;
   price.placeholder=getProduct()?'':'Custo da entrada';
   ackLabel.hidden=!c.exigeConfirmacao;
  }catch(e){
   preview.textContent=e.message;
   cost.textContent='—';
   ackLabel.hidden=true;
  }
  item.preco_venda_invalido=!price.validity.valid;
  onChange();
 }
 price.oninput=()=>{
  const current=getProduct()?.preco_venda;
  item.preco_venda_editado=price.value!==''&&(current==null||Number(price.value)!==Number(current))?price.value:null;
  refresh();
 };
 price.onblur=()=>{if(getProduct()&&price.value===''&&!price.validity.badInput)showPrice()};
 for(const f of Object.values(fields))f.oninput=()=>{ack.checked=false;refresh()};
 ack.onchange=refresh;
 showPrice();
 refresh();
 return {
  setStock(newStock){
   if(fields.stock.value===newStock)return;
   fields.stock.value=newStock;
   ack.checked=false;
   refresh();
  },
  reset(newStock){
   fields.factor.value='1';
   fields.stock.value=getProduct()?.unidade_comercial||newStock||item.unidade_comercial||'';
   fields.stock.readOnly=!!getProduct()?.unidade_comercial;
   item.preco_venda_editado=null;
   ack.checked=false;
   showPrice();
   refresh();
  }
 };
}

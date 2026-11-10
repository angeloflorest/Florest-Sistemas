// Configuração exclusiva da Gastronomia. Não solicita credenciais no navegador.
const el=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e};
export async function mount99Food(root,{rpc,catalog=[],current=()=>true,notice=()=>{}}){
 let data;
 const call=async(action,values={})=>{if(!current())throw Error('Reabra a configuração da empresa atual.');const result=await rpc(action,values);if(!current())throw Error('A tela ou a empresa mudou. Reabra a configuração.');return result};
 function field(parent,label,value='',choices){const wrap=el('div'),lab=el('label',label),input=el(choices?'select':'input');input.id='food99-'+crypto.randomUUID();lab.htmlFor=input.id;wrap.className='field';if(choices)for(const [v,t]of choices){const o=el('option',t);o.value=v;input.append(o)}input.value=value??'';wrap.append(lab,input);parent.append(wrap);return input}
 function section(title,text){const s=el('section');s.className='gs-section';s.append(el('h3',title));if(text)s.append(el('p',text));root.append(s);return s}
 function button(parent,label,fn){const b=el('button',label);b.type='button';b.className='btn-secondary';b.onclick=async()=>{b.disabled=true;try{await fn()}catch(e){notice(e.message||String(e))}finally{b.disabled=false}};parent.append(b);return b}
 function submit(form,label,fn){const b=el('button',label);b.type='submit';b.className='btn';form.append(b);form.onsubmit=async e=>{e.preventDefault();if(b.disabled)return;b.disabled=true;try{await fn()}catch(error){notice(error.message||String(error))}finally{b.disabled=false}}}
 async function reload(){data=await call('obter');render()}
 function render(){
  root.replaceChildren(el('h2','99Food · Preparação da integração'));
  const status=el('p','Desativada — aguardando qualificação da Florest, credenciais, testes e autorização da loja na 99Food.');status.className='msg';status.setAttribute('role','status');root.append(status);
  const cfg=section('Configuração da loja','É possível salvar sem cadastro na 99Food. Esta preparação não altera o cardápio existente na plataforma e não recebe pedidos.'),form=el('form');form.className='gs-form-grid';cfg.append(form);
  const name=field(form,'Nome da loja (opcional)',data.config.nome_loja);name.maxLength=120;
  const shop=field(form,'ID da loja na 99Food — Shop ID (opcional)',data.config.shop_id);shop.inputMode='numeric';shop.pattern='[1-9][0-9]{0,18}';shop.maxLength=19;shop.placeholder='Identificador fornecido pela 99Food';
  const appShop=field(form,'Identificador de vínculo — AppShopID',data.config.app_shop_id);appShop.required=true;appShop.maxLength=100;
  const env=field(form,'Ambiente planejado',data.config.ambiente,[['teste','Testes / homologação'],['producao','Produção — conexão bloqueada']]);
  const sync=field(form,'Sincronização de cardápio planejada',String(data.config.sincronizar_cardapio===true),[['false','Somente pedidos'],['true','Pedidos e cardápio — ativação futura']]);
  submit(form,'Salvar preparação 99Food',async()=>{await call('salvar',{versao:data.versao,nome_loja:name.value.trim(),shop_id:shop.value.trim(),app_shop_id:appShop.value.trim(),ambiente:env.value,sincronizar_cardapio:sync.value==='true'});await reload();notice('Preparação 99Food salva. A conexão continua desativada.')});
  const mappings=section('Vínculo de produtos e adicionais','Relacione o app_item_id da 99Food ao produto desta empresa. Os vínculos não publicam nem substituem produtos.'),mf=el('form');mf.className='gs-form-grid';mappings.append(mf);
  const kind=field(mf,'Tipo de vínculo','produto',[['produto','Produto'],['adicional','Adicional']]),code=field(mf,'Código do item na 99Food — app_item_id');code.required=true;code.maxLength=100;
  const search=field(mf,'Buscar produto do Gastronomia');search.type='search';search.placeholder='Digite o nome ou código do produto';
  const product=field(mf,'Produto do Gastronomia','',[['','Selecione']]);product.required=true;
  const products=catalog.filter(p=>p.ativo!==false);
  function filter(){const selected=product.value,q=search.value.trim().toLocaleLowerCase('pt-BR');product.replaceChildren();const empty=el('option','Selecione');empty.value='';product.append(empty);for(const p of products.filter(p=>[p.nome,p.codigo,p.id].some(v=>String(v??'').toLocaleLowerCase('pt-BR').includes(q)))){const o=el('option',p.nome);o.value=p.id;product.append(o)}product.value=selected}
  search.oninput=filter;filter();
  submit(mf,'Salvar vínculo 99Food',async()=>{await call('vincular',{versao:data.versao,tipo:kind.value,codigo_externo:code.value.trim(),produto_id:product.value,ativo:true});await reload();notice('Vínculo 99Food salvo.')});
  if(!data.vinculos.length)mappings.append(el('p','Nenhum vínculo cadastrado.'));
  for(const m of data.vinculos){const row=el('p');row.append(el('span',`${m.tipo==='produto'?'Produto':'Adicional'} · ${m.codigo_externo} → ${m.nome}${m.ativo?'':' · Desativado'} `));button(row,m.ativo?'Desativar vínculo':'Reativar vínculo',async()=>{await call('vincular',{versao:data.versao,tipo:m.tipo,codigo_externo:m.codigo_externo,produto_id:m.produto_id,ativo:!m.ativo});await reload()});mappings.append(row)}
  const flow=section('Pedidos no Gastronomia','Os pedidos da 99Food serão identificados em amarelo na aba Pedidos. iFood permanece vermelho e Cardápio Digital fica azul.');
  flow.append(el('p','Após a conexão ser validada, os pedidos deverão seguir a impressão de duas vias na impressora da Gastronomia. Esta preparação não imprime, não cria vendas e não movimenta caixa ou estoque.'));
  const pending=section('Etapas para ativação','Protocolo planejado: 99Food nativo, recomendado pela documentação para pedidos e cardápio.');
  const list=el('ol');for(const text of ['Qualificar a Florest como integradora e concluir os acordos exigidos pela 99Food.','Criar aplicativo e loja de testes; configurar App ID, App Secret e tokens somente no servidor.','Autorizar a loja com o superadministrador da 99Food e conferir o Shop ID e o AppShopID. Uma loja pode estar vinculada a um único aplicativo de produção.','Concluir e testar o processamento de notificações, confirmação, pedido pronto, retirada, cancelamentos e pagamentos.','Validar produtos, complementos, fotos, preços e pausas; conferir o resultado de cada sincronização antes de considerar o cardápio atualizado.','Validar impressão sem duplicidade e recebimentos; liberar uma loja piloto após aprovação.'])list.append(el('li',text));pending.append(list);
  for(const [label,url]of [['Abrir portal oficial da 99Food','https://developer-food.99app.com/pt-BR/home'],['Documentação da integração','https://developer-food.99app.com/pt-BR/openapi/index']]){const p=el('p'),a=el('a',label);a.href=url;a.target='_blank';a.rel='noopener noreferrer';p.append(a);pending.append(p)}
  pending.append(el('p','Contato técnico da 99Food: 99FoodTechSupport@didiglobal.com. A autorização ainda não está disponível nesta preparação.'));
 }
 root.replaceChildren(el('p','Carregando configuração 99Food…'));await reload();
}

import {revisaoDoCadastro,destinoDoCliente,pendenciasContrato,itemSimples102} from './fiscal-nfe55-modelo.js';
// NF-e 55: série do cadastro fiscal da empresa. Nunca chama a emissão NFC-e.
export const NFE55_MODELO = '55';
export function validarBuscaNfe55(numero, inicio, fim) {
  if (numero && !/^[1-9]\d{0,14}$/.test(numero)) throw Error('Informe um número de venda válido.');
  const dataValida = valor => /^\d{4}-\d{2}-\d{2}$/.test(valor) && !Number.isNaN(Date.parse(valor+'T12:00:00Z')) && new Date(valor+'T12:00:00Z').toISOString().slice(0,10)===valor;
  for (const valor of [inicio,fim]) if (valor && !dataValida(valor)) throw Error('Informe datas válidas.');
  if (inicio && fim && inicio > fim) throw Error('A data inicial deve ser anterior ou igual à final.');
  if (!numero && (!inicio || !fim)) throw Error('Informe o número da venda ou um período com início e fim.');
}
export function impedimentoDocumentoNfe55(venda, documentos) {
  if (venda.cancelada_em) return 'Venda cancelada: não pode ser utilizada para emitir NF-e.';
  const conflito = documentos.find(d => ['nfce','nfe'].includes(d.tipo_documento) && !['cancelada','rejeitada'].includes(d.status));
  if (!conflito) return '';
  return `Esta venda possui ${conflito.tipo_documento === 'nfce' ? 'NFC-e' : 'NF-e'} com situação ${conflito.status || 'não confirmada'}. A emissão de outro documento exige análise fiscal; não será feita automaticamente.`;
}
export function instalarAbaNfe55({ document, supabase, obterEmpresaId, podeAcessar, formatarReais }) {
  const $ = id => document.getElementById(id);
  let geracao = 0, selecionada = null, ocupada = false, serieEmpresa = '';
  let ultimaPesquisa={numero:'',inicio:'',fim:'',vendaId:null,empresa:null};
  const chavePesquisa='florest-nfe55-pesquisa';
  const chaveRascunho='florest-nfe55-rascunho';
  function salvarRascunho(){if(!selecionada||selecionada.registro)return;try{sessionStorage.setItem(chaveRascunho,JSON.stringify({empresa:selecionada.ctx.empresa,vendaId:selecionada.id,revisao:selecionada.revisao}));}catch{}}
  function recuperarRascunho(empresa,vendaId){try{const r=JSON.parse(sessionStorage.getItem(chaveRascunho)||'null');return r?.empresa===empresa&&r?.vendaId===vendaId?r.revisao:null;}catch{return null;}}
  function salvarPesquisa(){try{sessionStorage.setItem(chavePesquisa,JSON.stringify(ultimaPesquisa));}catch{}}
  function recuperarPesquisa(){try{const v=JSON.parse(sessionStorage.getItem(chavePesquisa)||'null');return v&&typeof v==='object'?v:null;}catch{return null;}}
  const money = valor => formatarReais(Number(valor || 0));
  function texto(tag, valor, classe) {
    const node=document.createElement(tag); node.textContent=String(valor ?? 'Não informado');
    if (classe) node.className=classe;
    return node;
  }
  function limpar() {
    geracao++; selecionada=null;serieEmpresa='';$('nfe55-serie').value='';
    $('nfe55-resultados').replaceChildren(); $('nfe55-detalhes').replaceChildren();
    $('nfe55-emitente').replaceChildren(); $('nfe55-msg').textContent='';
    $('nfe55-numero').value=''; $('nfe55-inicio').value=''; $('nfe55-fim').value='';
    ultimaPesquisa={numero:'',inicio:'',fim:'',vendaId:null,empresa:null};
    try{sessionStorage.removeItem(chavePesquisa);sessionStorage.removeItem(chaveRascunho);}catch{}
    $('nfe55-transmitir').disabled=true; $('nfe55-pesquisar').disabled=false;
  }
  async function aguardar(promise,mensagem,ms=20000){
    let timer;try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(mensagem)),ms);})]);}finally{clearTimeout(timer);}
  }
  async function contexto() {
    if (!supabase || !podeAcessar('fiscal')) throw Error('Acesso ao módulo Fiscal necessário.');
    const {data,error}=await aguardar(supabase.auth.getSession(),'A sessão demorou a responder. Tente novamente sem repetir uma transmissão.');
    if (error || !data?.session?.user?.id) throw Error('Sessão expirada. Entre novamente.');
    const empresa=await aguardar(obterEmpresaId(),'Não foi possível confirmar a empresa a tempo. Reabra a aba fiscal.');
    if (!empresa) throw Error('Não foi possível identificar sua empresa.');
    return { empresa, usuario:data.session.user.id };
  }
  async function atual(ctx, req) {
    if (req!==geracao) return false;
    const c=await contexto();
    return req===geracao && c.empresa===ctx.empresa && c.usuario===ctx.usuario;
  }
  async function emitente(ctx,req) {
    const config=await supabase.from('configuracoes_fiscais').select('empresa_id,razao_social,nome_fantasia,cnpj,inscricao_estadual,regime_tributario,crt,certificado_status,certificado_validade,emitente_registrado,nfce_ambiente,nfe_serie,nfe_numeracao_confirmada_em').eq('empresa_id',ctx.empresa).maybeSingle();
    if(!await atual(ctx,req))return;
    serieEmpresa=config.data?.nfe_serie||'';$('nfe55-serie').value=serieEmpresa;
    const counter=serieEmpresa ? await supabase.from('contadores_fiscais').select('ultimo_numero').eq('empresa_id',ctx.empresa).eq('tipo_documento','nfe').eq('serie',serieEmpresa).maybeSingle() : {data:null};
    if (!await atual(ctx,req)) return;
    const box=$('nfe55-emitente'); box.replaceChildren();
    if (config.error || !config.data) { box.append(texto('p','Não foi possível consultar o cadastro fiscal existente. Nenhuma configuração foi alterada.','msg error')); return; }
    const c=config.data;
    if (c.empresa_id!==ctx.empresa) throw Error('Cadastro fiscal não corresponde à empresa autenticada.');
    box.append(texto('h4',c.razao_social || c.nome_fantasia || 'Emitente cadastrado'));
    box.append(texto('p',`CNPJ: ${c.cnpj || 'não informado'} · IE: ${c.inscricao_estadual || 'não informada'} · Regime: ${c.regime_tributario || 'não informado'} · CRT: ${c.crt || 'não informado'}`));
    box.append(texto('p',`Certificado: ${c.certificado_status || 'não informado'}${c.certificado_validade ? ' · validade '+c.certificado_validade : ''}. Cadastro do emitente na integração: ${c.emitente_registrado ? 'registrado' : 'não confirmado'}.`));
    const ambiente = c.nfce_ambiente === 'producao' ? 'Produção' : c.nfce_ambiente === 'homologacao' ? 'Homologação' : 'não confirmado';
    box.append(texto('p',`Ambiente cadastrado para NFC-e: ${ambiente}. A NF-e usa Produção e a série configurada desta empresa, com liberação independente no servidor; esta tela não modifica a configuração da NFC-e.`));
    box.append(texto('p',counter.error ? 'Não foi possível consultar a numeração de NF-e.' : counter.data ? `Último número de NF-e série ${serieEmpresa} emitido ou reservado no ERP: ${counter.data.ultimo_numero}.` : 'Nenhum contador desta série NF-e foi encontrado no ERP.'));
    box.append(texto('p',c.nfe_numeracao_confirmada_em?'Sequência conferida pelo responsável. Nenhum número é reservado ao abrir esta aba.':'Antes de emitir, o responsável deve conferir e salvar a sequência NF-e nas Configurações.'));
  }
  async function abrir() {
    const lembrada=recuperarPesquisa()||{...ultimaPesquisa};
    geracao++;selecionada=null;serieEmpresa='';$('nfe55-serie').value='';$('nfe55-resultados').replaceChildren();$('nfe55-detalhes').replaceChildren();$('nfe55-emitente').replaceChildren();$('nfe55-msg').textContent='';$('nfe55-transmitir').disabled=true;$('nfe55-pesquisar').disabled=false;
    const req=geracao;
    try { const ctx=await contexto(); await emitente(ctx,req);
      if(req===geracao && lembrada.empresa===ctx.empresa){
        ultimaPesquisa=lembrada;salvarPesquisa();
        $('nfe55-numero').value=lembrada.numero; $('nfe55-inicio').value=lembrada.inicio; $('nfe55-fim').value=lembrada.fim;
        if(lembrada.numero||lembrada.inicio&&lembrada.fim){await pesquisar(); if(lembrada.vendaId)await selecionar(lembrada.vendaId);}
      }
    }
    catch(e) { if(req===geracao) $('nfe55-msg').textContent=e.message || 'Não foi possível consultar o cadastro fiscal.'; }
  }
  async function pesquisar(event) {
    event?.preventDefault(); selecionada=null; $('nfe55-transmitir').disabled=true; const req=++geracao;
    $('nfe55-resultados').replaceChildren(); $('nfe55-detalhes').replaceChildren(); $('nfe55-msg').textContent='';
    const button=$('nfe55-pesquisar');button.disabled=true;
    try {
      const numero=$('nfe55-numero').value.trim(), inicio=$('nfe55-inicio').value, fim=$('nfe55-fim').value;
      validarBuscaNfe55(numero,inicio,fim);
      const ctx=await contexto();
      ultimaPesquisa={numero,inicio,fim,vendaId:null,empresa:ctx.empresa};salvarPesquisa();
      let query=supabase.from('vendas').select('id,empresa_id,numero_venda,total,criado_em,forma_pagamento,cancelada_em,cliente_id,clientes(nome)').eq('empresa_id',ctx.empresa);
      if(numero)query=query.eq('numero_venda',numero);
      if(inicio)query=query.gte('criado_em',new Date(inicio+'T00:00:00').toISOString());
      if(fim)query=query.lte('criado_em',new Date(fim+'T23:59:59.999').toISOString());
      const {data,error}=await query.order('criado_em',{ascending:false}).order('id').limit(31);
      if(error)throw Error('Não foi possível consultar as vendas. Confira sua conexão e permissão fiscal.');
      if(!await atual(ctx,req))return;
      const rows=data || [];
      if(rows.some(v=>v.empresa_id!==ctx.empresa))throw Error('A resposta contém venda de outra empresa. Consulta interrompida.');
      if(!rows.length)$('nfe55-msg').textContent='Nenhuma venda encontrada para os filtros.';
      for(const v of rows.slice(0,30)) {
        const row=texto('div','', 'lista-item');
        row.append(texto('span',`Venda #${v.numero_venda} · ${v.clientes?.nome || 'Consumidor sem cadastro'} · ${money(v.total)}${v.cancelada_em ? ' · Cancelada' : ''}`));
        const b=texto('button','Conferir para NF-e','btn-secondary');b.type='button';
        b.addEventListener('click',()=>selecionar(v.id));row.append(b);$('nfe55-resultados').append(row);
      }
      if(rows.length>30)$('nfe55-msg').textContent='Exibindo 30 vendas. Refine o período ou informe o número da venda.';
    } catch(e) { if(req===geracao){$('nfe55-resultados').replaceChildren();$('nfe55-msg').textContent=e.message || 'Não foi possível pesquisar.';} }
    finally { if(req===geracao)button.disabled=false; }
  }
  async function selecionar(id) {
    selecionada=null; const req=++geracao; $('nfe55-detalhes').replaceChildren();$('nfe55-msg').textContent='Carregando conferência da venda…';$('nfe55-transmitir').disabled=true;$('nfe55-pesquisar').disabled=false;
    try {
      const ctx=await contexto();
      ultimaPesquisa={numero:$('nfe55-numero').value,inicio:$('nfe55-inicio').value,fim:$('nfe55-fim').value,vendaId:id,empresa:ctx.empresa};salvarPesquisa();
      const [sale,items,docs]=await Promise.all([
        supabase.from('vendas').select('id,empresa_id,numero_venda,total,criado_em,forma_pagamento,cliente_id,cancelada_em,clientes(nome,cpf,email,logradouro,numero,complemento,bairro,cidade,uf,cep)').eq('empresa_id',ctx.empresa).eq('id',id).single(),
        supabase.from('itens_venda').select('empresa_id,quantidade,preco_unitario,subtotal,produtos(nome,codigo,ncm,cfop,unidade_comercial,tipo_fiscal)').eq('empresa_id',ctx.empresa).eq('venda_id',id).order('id').limit(501),
        supabase.from('documentos_fiscais').select('empresa_id,tipo_documento,status,numero').eq('empresa_id',ctx.empresa).eq('venda_id',id),
      ]);
      if(sale.error||items.error||docs.error)throw Error('Não foi possível conferir venda, produtos e documentos existentes. Nenhum documento foi gerado.');
      if(!await atual(ctx,req))return;
      const v=sale.data, linhas=items.data||[], documentos=docs.data||[];
      if(!v||v.id!==id||v.empresa_id!==ctx.empresa||linhas.some(i=>i.empresa_id!==ctx.empresa)||documentos.some(d=>d.empresa_id!==ctx.empresa))throw Error('Os dados não correspondem à empresa autenticada.');
      const box=$('nfe55-detalhes'), cliente=v.clientes;
      box.append(texto('h3',`Conferência da venda #${v.numero_venda} · NF-e modelo 55 · Série ${serieEmpresa || 'não configurada'}`));
      box.append(texto('p',`Venda registrada em ${new Date(v.criado_em).toLocaleString('pt-BR')} · ${v.forma_pagamento} · Total ${money(v.total)}`));
      box.append(texto('h4','Destinatário do cadastro existente'));
      box.append(texto('p',cliente ? `${cliente.nome} · CPF/CNPJ cadastrado: ${cliente.cpf || 'não informado'}` : 'Venda sem cliente cadastrado. A NF-e exigirá um destinatário completo antes da transmissão.'));
      if(cliente)box.append(texto('p',[cliente.logradouro,cliente.numero,cliente.complemento,cliente.bairro,cliente.cidade,cliente.uf,cliente.cep].filter(Boolean).join(' · ') || 'Endereço não informado no cadastro.'));
      box.append(texto('p','Os dados do destinatário serão validados conforme a operação. Esta aba não altera o cadastro do cliente.'));
      const impedimento=impedimentoDocumentoNfe55(v,documentos);
      if(impedimento)box.append(texto('p',impedimento,'msg error'));
      if(documentos.length)box.append(texto('p','Documentos existentes: '+documentos.map(d=>`${d.tipo_documento.toUpperCase()} · ${d.status} · número ${d.numero || 'não atribuído'}`).join('; ')));
      const table=document.createElement('table'), head=document.createElement('thead'), hr=document.createElement('tr');
      for(const label of ['Produto','Quantidade','Preço','Subtotal','NCM','CFOP'])hr.append(texto('th',label));head.append(hr);table.append(head);
      const body=document.createElement('tbody');
      for(const item of linhas.slice(0,500)) { const tr=document.createElement('tr');const p=item.produtos||{};for(const value of [p.nome||'Produto',item.quantidade,money(item.preco_unitario),money(item.subtotal),p.ncm||'não informado',p.cfop||'não informado'])tr.append(texto('td',value));body.append(tr); }
      table.append(body);box.append(table);
      if(!linhas.length||linhas.length>500)box.append(texto('p','Não foi possível exibir uma lista completa de itens para emissão.','msg error'));
      if(linhas.some(i=>i.produtos?.tipo_fiscal==='servico'))box.append(texto('p','Esta venda contém serviços. A NF-e modelo 55 é de mercadorias; a separação fiscal precisa ser validada antes de emitir.','msg error'));
      box.append(texto('p','A emissão usa esta venda; não cria outra venda e não movimenta estoque ou financeiro.'));
      $('nfe55-msg').textContent=impedimento || 'Carregando dados fiscais para conferência…';
      if(!impedimento)try{await editar(ctx,req,id,box);}catch(e){if(req===geracao)$('nfe55-msg').textContent=e.message;}
    } catch(e) { if(req===geracao){$('nfe55-detalhes').replaceChildren();$('nfe55-msg').textContent=e.message || 'Falha ao conferir a venda.';} }
  }
  $('nfe55-form').addEventListener('submit',pesquisar);
  $('nfe55-limpar').addEventListener('click',limpar);
  async function chamar(acao,venda_id,extra={}) {
    const {data,error}=await aguardar(supabase.functions.invoke('fiscal-nfe55',{body:{acao,venda_id,...extra}}),'O servidor demorou a responder. Consulte a situação antes de repetir uma emissão.',25000);
    if(error||data?.erro) {
      let info=data;
      if(!info?.erro&&error?.context?.json)try{info=await error.context.json();}catch{}
      const failure=Error(info?.erro||'Backend NF-e indisponível. Nenhuma transmissão será repetida automaticamente.');failure.fase=info?.fase;throw failure;
    }
    return data;
  }
  function campo(parent,rotulo,obj,chave,{opcoes,tipo='text'}={}) {
    const label=texto('label',rotulo);let input;
    if(opcoes){input=document.createElement('select');for(const [valor,nome] of [['','Selecione…'],...opcoes]){const o=texto('option',nome);o.value=valor;input.append(o);}}
    else {input=document.createElement('input');input.type=tipo;input.maxLength=tipo==='text'?200:20;}
    input.value=obj[chave]??'';input.addEventListener('input',()=>{obj[chave]=input.value;salvarRascunho();const c=$('nfe55-confirmar');if(c)c.checked=false;if(selecionada){selecionada.validada=false;}atualizarPendencias();});
    label.append(input);parent.append(label);return input;
  }
  function habilitar(){const c=$('nfe55-confirmar');$('nfe55-transmitir').disabled=ocupada||!selecionada||!!selecionada.registro||!selecionada.validada||pendenciasContrato(selecionada.snapshot,selecionada.revisao).length>0||!c?.checked;}
  function situacao(box,registro){
    const old=$('nfe55-situacao');old?.remove();const panel=texto('div','');panel.id='nfe55-situacao';box.append(panel);
    panel.append(texto('h4',`NF-e nº ${registro.numero} · Série ${registro.serie || serieEmpresa || 'a consultar'} · Produção · ${registro.status}`));
    panel.append(texto('p',`${registro.c_stat||''} ${registro.mensagem||''}`));
    if(registro.chave_acesso)panel.append(texto('p','Chave: '+registro.chave_acesso));
    if(registro.protocolo)panel.append(texto('p','Protocolo: '+registro.protocolo));
    panel.append(texto('p',registro.status==='rejeitada'?'Rejeição registrada. Confira a IE e consulte a situação antes de retransmitir.':'Use a consulta para acompanhar a situação, sem enviar uma nova nota.'));
    if(registro.status==='rejeitada'){
      const label=texto('label','Inscrição Estadual do destinatário para correção');const ie=document.createElement('input');ie.type='text';ie.maxLength=14;ie.value=selecionada?.revisao?.dest?.ie||'';ie.id='nfe55-ie-reenvio';label.append(ie);panel.append(label);
      const reenviar=texto('button','Corrigir e retransmitir esta NF-e','btn-secondary');reenviar.type='button';reenviar.addEventListener('click',()=>acaoNota('retransmitir'));panel.append(reenviar);
    }
    for(const [acao,label] of [['consultar','Consultar situação'],...(registro.status==='autorizada'?[['xml','Baixar XML'],['danfe','Baixar DANFE (PDF)']]:[])]) {
      const b=texto('button',label,'btn-secondary');b.type='button';b.addEventListener('click',()=>acaoNota(acao));panel.append(b);
    }
  }
  function atualizarPendencias(){
    const current=selecionada,box=$('nfe55-pendencias');if(!current||!box)return;
    const pendencias=pendenciasContrato(current.snapshot,current.revisao);box.replaceChildren();
    for(const p of pendencias)box.append(texto('p',p,'msg warning'));
    habilitar();
  }
  async function editar(ctx,req,id,box) {
    const data=await chamar('preparar',id);if(!await atual(ctx,req))return;
    const snap=data.snapshot;if(snap?.venda?.id!==id||snap.venda.empresa_id!==ctx.empresa)throw Error('A conferência fiscal não corresponde à empresa autenticada.');
    serieEmpresa=snap.emitente?.nfe_serie||serieEmpresa;$('nfe55-serie').value=serieEmpresa;
    selecionada={ctx,req,id,snapshot:snap,revisao:revisaoDoCadastro(snap,recuperarRascunho(ctx.empresa,id)||data.revisao||{}),registro:data.registro,conferenciaHash:data.conferencia_hash,validada:false};
    if(data.registro){situacao(box,data.registro);$('nfe55-msg').textContent='Tentativa existente recuperada. A emissão duplicada está bloqueada.';return;}
    renderEditor();
  }
  function renderEditor(){
    const current=selecionada;if(!current||current.registro)return;
    $('nfe55-editor')?.remove();const box=texto('div','');box.id='nfe55-editor';$('nfe55-detalhes').append(box);
    current.validada=false;
    const r=current.revisao,snap=current.snapshot,simples=['1','4'].includes(String(snap.emitente?.crt));
    box.append(texto('h4',`Conferir NF-e · CRT ${snap.emitente?.crt||'não cadastrado'} · Série ${serieEmpresa||'não configurada'}`));
    const search=texto('div','','fpq-grid'),q=document.createElement('input'),btn=texto('button','Buscar destinatário','btn-secondary'),results=texto('div','');q.placeholder='Nome, CPF ou CNPJ';q.setAttribute('aria-label','Pesquisar destinatário');q.maxLength=80;btn.type='button';search.append(q,btn);box.append(search,results);
    let busca=0;
    btn.addEventListener('click',async()=>{
      const seq=++busca;results.replaceChildren();btn.disabled=true;
      try{
        if(q.value.trim().length<2)throw Error('Informe ao menos dois caracteres.');
        const data=await chamar('clientes',current.id,{busca:q.value.trim()});
        if(current!==selecionada||seq!==busca||!await atual(current.ctx,current.req))return;
        if(data.empresa_id!==current.ctx.empresa||data.clientes?.some(c=>c.empresa_id!==current.ctx.empresa))throw Error('Destinatário não corresponde à empresa autenticada.');
        if(!data.clientes?.length)results.append(texto('p','Nenhum destinatário encontrado. Você pode preencher os dados abaixo.'));
        for(const c of data.clientes||[]){const use=texto('button',`Usar ${c.nome} · ${c.cpf||'documento não cadastrado'}`,'btn-secondary');use.type='button';use.addEventListener('click',()=>{if(current!==selecionada)return;current.revisao.dest=destinoDoCliente(c);current.validada=false;renderEditor();});results.append(use);}
      }catch(e){if(current===selecionada&&seq===busca)results.append(texto('p',e.message,'msg error'));}
      finally{btn.disabled=false;}
    });
    const grid=texto('div','','fpq-grid');box.append(grid);
    campo(grid,'Destinatário: nome / razão social',r.dest,'xNome');campo(grid,'CPF/CNPJ',r.dest,'CNPJCPF');
    campo(grid,'Indicador IE',r.dest,'indIEDest',{opcoes:[['9','9 — Não contribuinte'],['2','2 — Isento'],['1','1 — Contribuinte']]});
    campo(grid,'Inscrição estadual do destinatário (quando aplicável)',r.dest,'ie');
    const endereco=texto('details','');endereco.append(texto('summary','Endereço do destinatário'));endereco.open=Object.values(r.dest.enderDest||{}).some(v=>!v);const eg=texto('div','','fpq-grid');endereco.append(eg);box.append(endereco);
    for(const [k,l] of Object.entries({xLgr:'Logradouro',nro:'Número',xBairro:'Bairro',cMun:'Código IBGE do município',xMun:'Município',UF:'UF',CEP:'CEP'}))campo(eg,l,r.dest.enderDest,k);
    const op=texto('div','','fpq-grid');box.append(op);const natureza=campo(op,'Natureza da operação',r.ide,'natOp');const sugestao=texto('button','Usar: VENDA DE MERCADORIA ADQUIRIDA OU RECEBIDA DE TERCEIROS','btn-secondary');sugestao.type='button';sugestao.addEventListener('click',()=>{natureza.value='VENDA DE MERCADORIA ADQUIRIDA OU RECEBIDA DE TERCEIROS';natureza.dispatchEvent(new Event('input',{bubbles:true}));});op.append(sugestao);campo(op,'Consumidor final',r.ide,'indFinal',{opcoes:[['1','Sim'],['0','Não']]});
    campo(op,'Presença',r.ide,'indPres',{opcoes:[['0','Não se aplica'],['1','Presencial'],['2','Internet'],['3','Teleatendimento'],['4','Entrega em domicílio'],['9','Outros']]});
    campo(op,'Transporte',r,'modFrete',{opcoes:[['9','9 — Sem transporte (fluxo mínimo)']]});
    const details=texto('details','');details.open=r.itens.some(f=>!f.imposto?.PIS?.CST||!f.imposto?.COFINS?.CST);details.append(texto('summary','Dados fiscais dos produtos — carregados do cadastro'));box.append(details);
    for(const [i,f] of r.itens.entries()){
      const p=snap.itens[i].produto||{},g=texto('div','','fpq-grid');details.append(texto('h4',p.nome),g);
      for(const [k,l] of Object.entries({ncm:'NCM',cfop:'CFOP',cest:'CEST (quando aplicável)',unidade:'Unidade',gtin:'GTIN ou SEM GTIN'}))campo(g,l,f,k);
      campo(g,'Origem da mercadoria',f.imposto.ICMS,'orig');if(simples)campo(g,'CSOSN (confirmar com responsável fiscal)',f,'csosn');else campo(g,'CST ICMS',f.imposto.ICMS,'CST');campo(g,'CST PIS',f.imposto.PIS,'CST');campo(g,'CST COFINS',f.imposto.COFINS,'CST');
      for(const group of ['PIS','COFINS']){
        const label=texto('label',`${group} CST 49/99: ausência de destaque conferida com o responsável fiscal.`),checkbox=document.createElement('input');checkbox.type='checkbox';checkbox.checked=f.imposto[group].sem_destaque===true;label.prepend(checkbox);g.append(label);
        const atualizar=()=>{label.hidden=!(itemSimples102(snap,f)&&['49','99'].includes(f.imposto[group].CST));};atualizar();g.addEventListener('input',atualizar);
        checkbox.addEventListener('change',()=>{f.imposto[group].sem_destaque=checkbox.checked;current.validada=false;$('nfe55-confirmar').checked=false;atualizarPendencias();});
      }
      const advanced=texto('details','');advanced.append(texto('summary','Valores tributários complementares (se necessários)'));const ag=texto('div','','fpq-grid');advanced.append(ag);details.append(advanced);
      campo(ag,'Tributos aproximados (se informados)',f.imposto,'vTotTrib');
      if(!itemSimples102(snap,f))for(const [k,l] of Object.entries({vBCSTRet:'Base ST retida',pST:'Percentual ST',vICMSSubstituto:'ICMS substituto',vICMSSTRet:'ICMS ST retido'}))campo(ag,l,f.imposto.ICMS,k);
      const ipi=texto('label','IPI aplicável (conferir CST e enquadramento)');const toggle=document.createElement('input');toggle.type='checkbox';toggle.checked=!!f.imposto.IPI;ipi.prepend(toggle);advanced.append(ipi);const ipibox=texto('div','','fpq-grid');advanced.append(ipibox);
      const montarIpi=()=>{ipibox.replaceChildren();if(f.imposto.IPI){campo(ipibox,'CST IPI',f.imposto.IPI,'CST');campo(ipibox,'Enquadramento legal IPI',f.imposto.IPI,'cEnq');campo(ipibox,'Selo IPI (se aplicável)',f.imposto.IPI,'cSelo');}};montarIpi();
      toggle.addEventListener('change',()=>{if(toggle.checked)f.imposto.IPI={CST:'',cEnq:'',cSelo:''};else delete f.imposto.IPI;montarIpi();current.validada=false;$('nfe55-confirmar').checked=false;atualizarPendencias();});
    }
    if(!r.itens.every(f=>itemSimples102(snap,f))){
      const tax=texto('details','');tax.append(texto('summary','Conferir totais tributários da operação'));const totals=texto('div','','fpq-grid');tax.append(totals);box.append(tax);
      for(const [k,l] of Object.entries({vBC:'Base de cálculo ICMS',vICMS:'Valor ICMS',vICMSDeson:'ICMS desonerado',vFCP:'FCP',vBCST:'Base ST',vFCPST:'FCP ST',vFCPSTRet:'FCP ST retido',vFrete:'Frete',vSeg:'Seguro',vDesc:'Desconto',vII:'Importação',vIPI:'IPI',vIPIDevol:'IPI devolvido',vPIS:'PIS',vCOFINS:'COFINS',vOutro:'Outras despesas'}))campo(totals,l,r.totais,k);
    }
    box.append(texto('p',`Total da NF-e: ${money(snap.venda.total)}. Os valores permanecem os da venda; não é necessário cálculo tributário separado para o enquadramento sem destaque validado.`));
    const pay=texto('details','');pay.append(texto('summary','Pagamento da venda e informações adicionais'));const pg=texto('div','','fpq-grid');pay.append(pg);box.append(pay);
    for(const p of r.pagamentos){campo(pg,'Meio de pagamento fiscal',p,'tPag',{opcoes:[['01','Dinheiro'],['02','Cheque'],['05','Crédito loja'],['15','Boleto'],['17','PIX'],['18','Transferência'],['99','Outros']]});campo(pg,'Descrição (obrigatória para Outros)',p,'xPag');campo(pg,'Valor pago',p,'vPag');}campo(pg,'Informações complementares',r,'infCpl');
    const pending=texto('div','');pending.id='nfe55-pendencias';box.append(pending);
    const final=texto('label','Conferi destinatário, produtos, tributos e pagamentos. Esta NF-e mantém os valores da venda, sem frete, seguro, desconto adicional ou outras despesas. Confirmo a sequência e autorizo a emissão em PRODUÇÃO após clicar em Emitir.');const confirm=document.createElement('input');confirm.type='checkbox';confirm.id='nfe55-confirmar';confirm.addEventListener('change',()=>{r.sem_acessorios=confirm.checked;if(confirm.checked&&!current.validada)acaoNota('validar');else habilitar();});final.prepend(confirm);box.append(final);
    const status=texto('p','Marque a confirmação para validar os dados antes de transmitir.','msg');status.id='nfe55-validacao-status';box.append(status);
    atualizarPendencias();$('nfe55-msg').textContent='Conferência carregada do cadastro. Complete apenas o que faltar; nenhuma nota foi transmitida.';
  }
  async function acaoNota(acao) {
    if(ocupada||!selecionada)return;const current=selecionada;
    const controles=[...($('nfe55-editor')?.querySelectorAll('input,select,button')||[])].map(node=>[node,node.disabled]);
    ocupada=true;for(const [node] of controles)if(acao==='emitir'||node.id!=='nfe55-confirmar')node.disabled=true;habilitar();
    const status=$('nfe55-validacao-status');if(status&&acao==='validar')status.textContent='Validando com o servidor. Aguarde o resultado; nenhuma nota será transmitida.';
    try {
      if(acao==='validar')$('nfe55-msg').textContent='Validando os dados fiscais. Nenhuma nota será transmitida nesta conferência…';
      if(!await atual(current.ctx,current.req))throw Error('Empresa ou sessão mudou. Recarregue a venda.');
      if(acao==='retransmitir'){
        const ie=String($('nfe55-ie-reenvio')?.value||'').replace(/\D/g,'');
        if(!/^\d{2,14}$/.test(ie))throw Error('Informe a inscrição estadual correta do destinatário.');
        if(!globalThis.confirm(`Retransmitir a NF-e nº ${current.registro.numero}, série ${current.registro.serie}, em PRODUÇÃO, com a IE ${ie}?`))return;
        const data=await chamar('retransmitir',current.id,{ie,conferencia_hash:current.conferenciaHash,confirmar_producao:true});
        if(!await atual(current.ctx,current.req))return;
        if(data.registro){current.registro=data.registro;current.revisao.dest.ie=ie;situacao($('nfe55-detalhes'),data.registro);$('nfe55-msg').textContent='Resultado da retransmissão: '+data.registro.status;}return;
      }
      if(acao==='emitir'&&!$('nfe55-confirmar')?.checked)return;
      if(acao==='emitir'&&!globalThis.confirm(`Emitir uma NF-e REAL em PRODUÇÃO para esta venda, modelo 55, série ${serieEmpresa}?`))return;
      const data=await chamar(acao,current.id,acao==='emitir'?{revisao:current.revisao,conferencia_hash:current.conferenciaHash,confirmar_producao:true}:acao==='validar'?{revisao:current.revisao}:{});
      if(!await atual(current.ctx,current.req))return;
      if(acao==='validar'){current.validada=data.valida===true;if(!current.validada&&$('nfe55-confirmar'))$('nfe55-confirmar').checked=false;const mensagem=data.valida?'Dados validados. A transmissão está liberada após a confirmação.':(data.pendencias||[]).join(' ')||'Validação não aprovada. Confira os dados fiscais.';$('nfe55-msg').textContent=mensagem;if(status)status.textContent=mensagem;}
      if(data.registro){current.registro=data.registro;situacao($('nfe55-detalhes'),data.registro);$('nfe55-msg').textContent='Situação NF-e: '+data.registro.status;}
      if(['xml','danfe'].includes(acao)) {
        let href,temporaria=false;
        if(data.conteudo){const bytes=acao==='xml'?data.conteudo:Uint8Array.from(atob(data.conteudo),c=>c.charCodeAt(0));href=URL.createObjectURL(new Blob([bytes],{type:acao==='xml'?'application/xml':'application/pdf'}));temporaria=true;}
        else {const u=new URL(data.link);if(u.protocol!=='https:'||u.username||u.password)throw Error('Link de arquivo inválido.');href=u.href;}
        const a=document.createElement('a');a.href=href;a.download=`NFE_${data.numero}.${acao==='xml'?'xml':'pdf'}`;a.target='_blank';a.rel='noopener noreferrer';document.body.append(a);a.click();a.remove();if(temporaria)setTimeout(()=>URL.revokeObjectURL(href),60000);
      }
    }catch(e){if(current===selecionada){const mensagem=e.message+(acao==='emitir'?' Se houve tentativa de emissão, recarregue a venda e consulte antes de tentar novamente.':' Nenhuma nota foi transmitida.');$('nfe55-msg').textContent=mensagem;if(status)status.textContent=mensagem;if(acao==='emitir'&&e.fase!=='validacao'){current.registro={status:'pendente',numero:'a consultar'};situacao($('nfe55-detalhes'),current.registro);}}}
    finally{ocupada=false;for(const [node,disabled] of controles)node.disabled=disabled;const checkbox=$('nfe55-confirmar');if(checkbox)checkbox.disabled=false;habilitar();}
  }
  $('nfe55-transmitir').addEventListener('click',()=>acaoNota('emitir'));
  const subscription=supabase?.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT')limpar();});
  return { abrir, limpar, destruir:()=>{limpar();subscription?.data.subscription.unsubscribe();} };
}

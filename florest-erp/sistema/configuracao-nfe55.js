// Configuração exclusiva NF-e. Não chama nem atualiza configurações NFC-e.
export function validarNumeracaoNfe55(serie,ultimo,confirmado){
 if(!/^[1-9]\d{0,2}$/.test(serie))throw Error('Série da NF-e deve ser um número de 1 a 999, sem zeros à esquerda.');
 if(!/^(0|[1-9]\d{0,8})$/.test(ultimo)||Number(ultimo)>999999998)throw Error('Último número da NF-e deve estar entre 0 e 999999998.');
 if(confirmado!==true)throw Error('Confirme que a série e a última numeração foram conferidas pelo responsável.');
 return {p_serie:serie,p_ultimo_numero:Number(ultimo),p_confirmado:true};
}
export function instalarConfiguracaoNfe55({document,supabase,obterEmpresaId,podeAcessar}){
 const $=id=>document.getElementById(id);let geracao=0,ocupado=false,contexto=null;
 function msg(s){$('cf-nfe-msg').textContent=s;}
 function bloquear(estado){ocupado=estado;for(const id of ['cf-nfe-serie','cf-nfe-ultimo-numero','cf-nfe-confirmado'])$(id).disabled=estado;$('cf-nfe-salvar').disabled=estado||!contexto;}
 function limpar(){geracao++;contexto=null;$('cf-nfe-serie').value='1';$('cf-nfe-ultimo-numero').value='';$('cf-nfe-confirmado').checked=false;$('cf-nfe-salvar').disabled=true;msg('');}
 async function ctx(){
  if(!podeAcessar('configuracoes'))throw Error('Permissão de configurações necessária.');
  const {data,error}=await supabase.auth.getSession();const empresa=await obterEmpresaId();
  if(error||!data?.session?.user?.id||!empresa)throw Error('Sessão inválida. Entre novamente.');
  return {empresa,usuario:data.session.user.id};
 }
 async function atual(c,g){if(g!==geracao)return false;const n=await ctx();return g===geracao&&c.empresa===n.empresa&&c.usuario===n.usuario;}
 function mostrar(data){
  if(!data||data.empresa_id!==contexto?.empresa)throw Error('Numeração não corresponde à empresa autenticada.');
  $('cf-nfe-serie').value=data.serie;$('cf-nfe-ultimo-numero').value=String(data.ultimo_numero);
  $('cf-nfe-confirmado').checked=false;
  msg((data.confirmada?'Numeração conferida. ':'Confirmação inicial pendente. ')+`Próxima NF-e da série ${data.serie}: ${data.proximo_numero??'numeração esgotada'}. Números reservados, rejeitados ou pendentes não são reutilizados automaticamente.`);
 }
 async function abrir(){
  limpar();const g=geracao;
  try{
   const c=await ctx();const {data,error}=await supabase.rpc('fiscal_nfe55_numeracao_obter',{p_serie:null});
   if(!await atual(c,g))return;
   if(error)throw Error('Configuração NF-e indisponível. A instalação do backend precisa estar autorizada e concluída.');
   contexto=c;mostrar(data);$('cf-nfe-salvar').disabled=ocupado;
  }catch(e){if(g===geracao)msg(e.message);}
 }
 async function consultarSerie(){
  if(ocupado)return;const serie=$('cf-nfe-serie').value.trim(),g=++geracao;
  $('cf-nfe-confirmado').checked=false;$('cf-nfe-salvar').disabled=true;
  if(!/^[1-9]\d{0,2}$/.test(serie)){msg('Informe uma série entre 1 e 999.');return;}
  try{
   const c=await ctx(),{data,error}=await supabase.rpc('fiscal_nfe55_numeracao_obter',{p_serie:serie});
   if(!await atual(c,g)||$('cf-nfe-serie').value.trim()!==serie)return;
   if(error)throw Error('Não foi possível consultar a sequência desta série.');
   contexto=c;mostrar(data);$('cf-nfe-salvar').disabled=ocupado;
  }catch(e){if(g===geracao)msg(e.message);}
 }
 async function salvar(){
  if(ocupado)return;const g=geracao;
  try{
   const args=validarNumeracaoNfe55($('cf-nfe-serie').value.trim(),$('cf-nfe-ultimo-numero').value.trim(),$('cf-nfe-confirmado').checked);
   bloquear(true);
   const c=await ctx();if(!contexto||!await atual(contexto,g)||contexto.empresa!==c.empresa||contexto.usuario!==c.usuario)throw Error('Empresa ou sessão mudou. Reabra as Configurações.');
   if(!globalThis.confirm(`Confirmar a sequência da NF-e para esta empresa? Série ${args.p_serie}, último número ${args.p_ultimo_numero}, próximo ${args.p_ultimo_numero+1}. A NFC-e não será alterada.`))return;
   const {data,error}=await supabase.rpc('fiscal_nfe55_numeracao_salvar',args);
   if(!await atual(c,g))return;
   if(error)throw Error(error.message||'Não foi possível salvar. Recarregue para conferir se outro operador já reservou um número.');
   mostrar(data);
  }catch(e){if(g===geracao)msg(e.message);}
  finally{bloquear(false);}
 }
 $('cf-nfe-serie').addEventListener('input',()=>{$('cf-nfe-confirmado').checked=false;$('cf-nfe-salvar').disabled=true;});
 $('cf-nfe-serie').addEventListener('change',consultarSerie);
 $('cf-nfe-ultimo-numero').addEventListener('input',()=>{$('cf-nfe-confirmado').checked=false;});
 $('cf-nfe-salvar').addEventListener('click',salvar);
 const sub=supabase.auth.onAuthStateChange(event=>{if(event!=='INITIAL_SESSION')limpar();});
 return {abrir,limpar,destruir(){limpar();sub?.data.subscription.unsubscribe();}};
}

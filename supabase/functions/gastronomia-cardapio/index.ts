const base=Deno.env.get('SUPABASE_URL')!,key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const origins=(Deno.env.get('GASTRONOMIA_ORIGENS')||'https://erp.florestsistemas.com.br').split(',');
const protocolo='cardapio-confirmacao-v2';
function confirmacaoValida(data:Record<string,unknown>){return data&&typeof data==='object'&&!Array.isArray(data)&&typeof data.numero==='number'&&Number.isInteger(data.numero)&&data.numero>0&&['mesa','entrega','retirada'].includes(String(data.tipo))&&typeof data.segredo==='string'&&/^[a-f0-9]{64}$/.test(data.segredo)&&typeof data.total==='number'&&Number.isFinite(data.total)&&data.total>=0&&typeof data.pagamento_confirmado==='boolean'}
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get('origin')||'',headers={'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Origin':origins.includes(origin)?origin:origins[0],'Vary':'Origin','Access-Control-Allow-Headers':'content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
 if(req.method==='OPTIONS')return new Response('',{headers});
 if(req.method!=='POST')return new Response(JSON.stringify({error:'Método inválido.'}),{status:405,headers});
 let b;
 try{
  const text=await req.text();if(text.length>55000)throw Error('Solicitação muito grande.');b=JSON.parse(text);
  if(!b||!['catalogo','confirmar','acompanhar'].includes(b.acao)||!/^[a-f0-9]{64}$/.test(b.token||'')||(b.acao==='confirmar'&&!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(b.chave||'')))throw Error('Solicitação inválida.');
 }catch{return new Response(JSON.stringify({error:'Solicitação inválida. Não foi enviada ao banco.',resultado:'nao_enviado',protocolo}),{status:400,headers})}
 const incerto=(status:number)=>new Response(JSON.stringify({error:'Não foi possível confirmar o resultado. Preserve esta tentativa e repita usando a mesma chave e o mesmo conteúdo.',resultado:'incerto',protocolo,chave:b.chave||null}),{status,headers});
 try{
  const r=await fetch(base+'/rest/v1/rpc/gastronomia_cardapio_publico',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({p_acao:b.acao,p_token:b.token,p_dados:b.dados||{},p_chave:b.chave||null}),signal:AbortSignal.timeout(20000)});
  let data;try{data=await r.json()}catch{return incerto(502)}
  if(!r.ok){
   // P0001 + HTTP 400 é o RAISE EXCEPTION de negócio devolvido pelo PostgREST:
   // a transação DESTA execução foi revertida. Não prova o resultado de tentativas anteriores.
   if(r.status===400&&data&&typeof data==='object'&&!Array.isArray(data)&&data.code==='P0001'&&typeof data.message==='string'&&data.message.length>0)return new Response(JSON.stringify({error:data.message.slice(0,500),resultado:'rejeitado',transacao:'revertida',codigo:'P0001',protocolo,chave:b.chave||null}),{status:422,headers});
   // Status HTTP sozinho, erros PGRST, permissões, SQL inesperado e 5xx não autorizam descartar a chave.
   return incerto(r.status===504?504:r.status>=500?503:502);
  }
  if(b.acao==='confirmar'){
   if(!confirmacaoValida(data))return incerto(502);
   return new Response(JSON.stringify({...data,protocolo,chave:b.chave}),{headers});
  }
  return new Response(JSON.stringify(data),{headers});
 }catch(e){return incerto(e instanceof Error&&['TimeoutError','AbortError'].includes(e.name)?504:503)}
});

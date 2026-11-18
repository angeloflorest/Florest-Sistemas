const base=Deno.env.get('SUPABASE_URL')!,key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
Deno.serve(async(req:Request)=>{
 const headers={'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Origin':'https://erp.florestsistemas.com.br','Access-Control-Allow-Headers':'content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
 if(req.method==='OPTIONS')return new Response('',{headers});
 if(req.method!=='POST')return new Response(JSON.stringify({error:'Método inválido.'}),{status:405,headers});
 let b;
 try{const body=await req.text();if(body.length>55000)throw Error();b=JSON.parse(body);if(!b||!['catalogo','confirmar','acompanhar'].includes(b.acao)||!/^[a-f0-9]{64}$/.test(b.token||'')||(b.acao!=='catalogo'&&!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(b.chave||'')))throw Error();}catch{return new Response(JSON.stringify({error:'Solicitação inválida.'}),{status:400,headers});}
 const uncertain=()=>new Response(JSON.stringify({error:'Não foi possível confirmar o resultado. Repita o mesmo envio para recuperar seu pedido.',resultado:'incerto',chave:b.chave}),{status:503,headers});
 try{
  const ip=req.headers.get('x-forwarded-for')?.split(',')[0].trim()||req.headers.get('cf-connecting-ip')||'unknown',digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(ip+':'+b.token)),hash=Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,'0')).join('');
  const res=await fetch(base+'/rest/v1/rpc/rotisseria_cardapio_publico',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({p_acao:b.acao,p_token:b.token,p_dados:b.dados||{},p_chave:b.chave||null,p_ip:hash}),signal:AbortSignal.timeout(20000)});let data;try{data=await res.json();}catch{return uncertain();}
  if(!res.ok){if(res.status===400&&data?.code==='P0001')return new Response(JSON.stringify({error:String(data.message).slice(0,500),resultado:'rejeitado',chave:b.chave}),{status:422,headers});return uncertain();}
  return new Response(JSON.stringify(data),{headers});
 }catch{return uncertain();}
});

// Endpoint exclusivo para criar novos garçons da Gastronomia. Não altera o Florest Garçom.
const base=Deno.env.get('SUPABASE_URL')||'',service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'';
const origins=(Deno.env.get('GASTRONOMIA_ORIGENS')||'https://erp.florestsistemas.com.br').split(',');
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get('origin')||'',headers={'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Origin':origins.includes(origin)?origin:origins[0],'Vary':'Origin','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS'};
 const response=(status:number,data:Record<string,unknown>)=>new Response(JSON.stringify(data),{status,headers});
 if(req.method==='OPTIONS')return new Response('',{headers});
 if(req.method!=='POST')return response(405,{error:'Método inválido.'});
 const auth=req.headers.get('authorization')||'';if(!/^Bearer \S+$/.test(auth))return response(401,{error:'Sessão expirada.'});
 const request=async(path:string,body:Record<string,unknown>|null=null,actor=false,method=body?'POST':'GET')=>{
  const r=await fetch(base+path,{method,headers:{apikey:service,Authorization:actor?auth:'Bearer '+service,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(20000)});let data;try{data=await r.json()}catch{data={}}return{ok:r.ok,status:r.status,data};
 };
 try{
  const raw=await req.text();if(raw.length>10000)return response(400,{error:'Solicitação muito grande.'});const b=JSON.parse(raw);
  const nome=typeof b.nome==='string'?b.nome.trim():'',usuario=typeof b.usuario==='string'?b.usuario.trim().toLowerCase():'',senha=b.senha;
  if(nome.length<2||nome.length>200||!/^\S{2,60}$/.test(usuario)||typeof senha!=='string'||senha.length<6||senha.length>18)return response(400,{error:'Confira nome, usuário sem espaços e senha de 6 a 18 caracteres.'});
  const user=await request('/auth/v1/user',null,true);if(!user.ok||!user.data.id)return response(401,{error:'Sessão expirada.'});
  const pre=await request('/rest/v1/rpc/gastronomia_ferramentas',{p_acao:'g_autorizar',p_dados:{empresa_esperada:b.empresa_esperada}},true);
  if(!pre.ok||!pre.data.empresa_id)return response(403,{error:'Somente o proprietário ativo da Gastronomia pode cadastrar garçons.'});
  const empresa=pre.data.empresa_id,ator=user.data.id;
  const created=await request('/auth/v1/admin/users',{email:crypto.randomUUID()+'@garcons.florest.app',password:senha,email_confirm:true,app_metadata:{gastronomia_garcom_empresa:empresa,gastronomia_garcom_ator:ator}});
  const id=created.data.id;if(!created.ok||!id)return response(400,{error:'Não foi possível criar o login. Confira os dados e a senha.'});
  const bound=await request('/rest/v1/rpc/gastronomia_garcom_vincular',{p_ator:ator,p_user_id:id,p_nome:nome,p_usuario:usuario});
  if(bound.ok)return response(200,{ok:true,usuario_id:id,empresa_id:empresa});
  // Conferir resultado antes de qualquer compensação: uma resposta perdida pode ter vinculado o perfil.
  const check=await request('/rest/v1/perfis?select=id,empresa_id&id=eq.'+encodeURIComponent(id));
  if(check.ok&&Array.isArray(check.data)&&check.data.some((p:{id:string;empresa_id:string})=>p.id===id&&p.empresa_id===empresa))return response(200,{ok:true,usuario_id:id,empresa_id:empresa});
  // Só desfaz o login NOVO desta requisição após recusa de negócio comprovada e ausência de perfil.
  if(check.ok&&Array.isArray(check.data)&&check.data.length===0&&['P0001','42501'].includes(bound.data.code))await request('/auth/v1/admin/users/'+encodeURIComponent(id),null,false,'DELETE');
  return response(400,{error:bound.data.code==='P0001'?String(bound.data.message).slice(0,300):'Não foi possível confirmar o cadastro. Consulte a lista antes de repetir.'});
 }catch{return response(503,{error:'Não foi possível confirmar o cadastro. Consulte a lista de garçons antes de repetir.'})}
});


import { createClient } from "npm:@supabase/supabase-js@2.57.4";
// Esta função é publicada manualmente como florest-autorizar-operacao (Verify JWT ligado).
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function envKey(nome: string, legado: string) {
  const raw = Deno.env.get(nome);
  if (raw) { try { const k = Object.values(JSON.parse(raw))[0]; if(typeof k === 'string') return k; } catch { /* legado */ } }
  return Deno.env.get(legado)!;
}
Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin');
  const permitidas = (Deno.env.get('DISTGESTOR_ALLOWED_ORIGINS') ?? Deno.env.get('FLOREST_ALLOWED_ORIGINS') ?? '').split(',').map(s=>s.trim());
  const headers: Record<string,string> = {'content-type':'application/json','cache-control':'no-store','vary':'Origin'};
  if(origin && !permitidas.includes(origin)) return new Response(JSON.stringify({mensagem:'Origem não permitida.'}),{status:403,headers});
  if(origin) Object.assign(headers,{'access-control-allow-origin':origin,'access-control-allow-methods':'POST, OPTIONS','access-control-allow-headers':'authorization, apikey, content-type, x-client-info'});
  const reply=(mensagem: unknown,status=200)=>new Response(JSON.stringify(mensagem),{status,headers});
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply({mensagem:'Método não permitido.'},405);
  const url=Deno.env.get('SUPABASE_URL')!;
  const admin=createClient(url,envKey('SUPABASE_SECRET_KEYS','SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
  let authClient: ReturnType<typeof createClient> | null=null;
  try {
    const bearer=req.headers.get('authorization')?.replace(/^Bearer\s+/i,'');
    if(!bearer)return reply({mensagem:'Não autenticado.'},401);
    const user=await admin.auth.getUser(bearer);
    if(user.error||!user.data.user)return reply({mensagem:'Sessão inválida.'},401);
    const ator=user.data.user.id;
    // Sem bloqueio próprio por número de tentativas; a senha do proprietário continua obrigatória.
    const bytes=await req.arrayBuffer(); if(bytes.byteLength>8192)return reply({mensagem:'Solicitação muito grande.'},413);
    const body=JSON.parse(new TextDecoder().decode(bytes));
    if(!uuid.test(body.alvo_id??'')||typeof body.identificacao!=='string'||typeof body.senha!=='string'||body.senha.length>128)return reply({mensagem:'Solicitação inválida.'},400);
    const perfil=await admin.from('perfis').select('empresa_id,ativo').eq('id',ator).single();
    if(perfil.error||!perfil.data.ativo)return reply({mensagem:'Acesso negado.'},403);
    const empresa=perfil.data.empresa_id;
    const ident=body.identificacao.trim().toLowerCase();
    // Lista restrita à empresa e a proprietários; não oferece enumeração de e-mails pela resposta.
    const donos=await admin.from('perfis').select('id,usuario').eq('empresa_id',empresa).eq('papel','proprietario').eq('ativo',true);
    if(donos.error)throw donos.error;
    let dono: string|null=null, email: string|null=null;
    for(const p of donos.data){
      const u=await admin.auth.admin.getUserById(p.id);
      if(u.error)throw u.error;
      if(p.usuario?.toLowerCase()===ident||u.data.user.email?.toLowerCase()===ident){dono=p.id;email=u.data.user.email??null;break;}
    }
    if(!dono||!email)return reply({mensagem:'Autorização recusada.'},403);
    authClient=createClient(url,envKey('SUPABASE_PUBLISHABLE_KEYS','SUPABASE_ANON_KEY'),{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
    const login=await authClient.auth.signInWithPassword({email,password:body.senha});
    body.senha='';
    if(login.error||login.data.user?.id!==dono)return reply({mensagem:'Autorização recusada.'},403);
    const token=await admin.rpc('florest_autorizacao_emitir',{p_solicitante:ator,p_autorizador:dono,p_operacao:body.operacao,p_alvo:body.alvo_id,p_parametros:body.parametros??{}});
    if(token.error)throw token.error;
    return reply({ok:true,token:token.data,expira_em_segundos:90});
  }catch{
    return reply({mensagem:'Não foi possível autorizar a operação.'},400);
  }finally{
    // Revoga somente a sessão temporária de validação; jamais devolve access/refresh token.
    if(authClient)await authClient.auth.signOut({scope:'local'}).catch(()=>{});
  }
});

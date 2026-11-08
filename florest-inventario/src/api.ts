import {createClient, type SupabaseClient} from '@supabase/supabase-js';
import {secureStorage} from './secureStorage';
import {gtins, product, validateProfile, type Profile, type Product} from './domain';
const defaults=require('../public-config.json');
const url=process.env.EXPO_PUBLIC_SUPABASE_URL||defaults.supabase_url, key=process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY||defaults.supabase_anon_key;
export function publicConfigValid(endpoint:string, publicKey:string):boolean {
 try { const u=new URL(endpoint); if(u.protocol!=='https:' || !u.hostname.endsWith('.supabase.co') || u.username || u.password)return false;
 return publicKey.startsWith('sb_publishable_') ? publicKey.length>25 : JSON.parse(atob(publicKey.split('.')[1].replace(/-/g,'+').replace(/_/g,'/'))).role==='anon'; } catch{return false;}
}
const timedFetch:typeof fetch=async(input,init)=>{const c=new AbortController();const abort=()=>c.abort();init?.signal?.addEventListener('abort',abort);if(init?.signal?.aborted)c.abort();const timer=setTimeout(abort,25000);try{return await fetch(input,{...init,signal:c.signal});}finally{clearTimeout(timer);init?.signal?.removeEventListener('abort',abort);}};
export const client=publicConfigValid(url,key)?createClient(url,key,{auth:{storage:secureStorage,autoRefreshToken:true,persistSession:true,detectSessionInUrl:false},global:{fetch:timedFetch}}):null;
export async function loginERP(c:SupabaseClient,email:string,password:string,username:string){
 if(!email.trim()||!password)throw Error('Informe e-mail e senha.');
 if(!username.trim()){const {error}=await c.auth.signInWithPassword({email:email.trim(),password});if(error)throw error;return;}
 const r=await timedFetch(url+'/functions/v1/florest-login',{method:'POST',headers:{'content-type':'application/json',apikey:key,authorization:'Bearer '+key},body:JSON.stringify({empresa:email.trim(),usuario:username.trim(),senha:password,superficie:'erp'})});
 const data=await r.json().catch(()=>null);
 if(!r.ok||!data?.ok||!data.session?.access_token||!data.session?.refresh_token)throw Error(data?.mensagem||'Empresa, usuário ou senha inválidos.');
 const {error}=await c.auth.setSession(data.session);if(error)throw error;
}
export async function loadProfile(c:SupabaseClient,id:string):Promise<Profile>{
 const {data,error}=await c.from('perfis').select('id,empresa_id,nome,papel,permissoes,ativo,empresas(nome,bloqueado,status_conta)').eq('id',id).single();if(error)throw error;return validateProfile(data,id);
}
const fields='id,empresa_id,nome,codigo,gtin,unidade_comercial,quantidade_estoque,atualizado_em,ativo,tipo_fiscal';
export async function searchProducts(c:SupabaseClient,p:Profile,term:string,exact:boolean):Promise<Product[]>{
 validateProfile(p,p.id);const t=term.trim().slice(0,100);if(!t)return [];
 let q=c.from('produtos').select(fields).eq('empresa_id',p.empresa_id).eq('ativo',true).eq('tipo_fiscal','produto');
 if(exact){const variants=gtins(t);q=variants.length?q.or('codigo.eq.'+t+',gtin.in.('+variants.join(',')+')'):q.eq('codigo',t);}
 else {const safe=t.replace(/[%_]/g,' ').trim();if(!safe)return [];q=q.ilike('nome','%'+safe+'%');}
 const {data,error}=await q.order('nome').order('id').limit(40);if(error)throw error;return (data||[]).map(v=>product(v,p.empresa_id));
}
export async function readProduct(c:SupabaseClient,p:Profile,id:string):Promise<Product>{
 const {data,error}=await c.from('produtos').select(fields).eq('empresa_id',p.empresa_id).eq('id',id).single();if(error)throw error;return product(data,p.empresa_id);
}
export class StockConflict extends Error { constructor(){super('O estoque ou o cadastro mudou durante a contagem. Confira o saldo antes de fazer uma nova contagem.');} }
export async function updateStock(c:SupabaseClient,p:Profile,snapshot:Product,amount:number):Promise<Product>{
 const {data:user,error:authError}=await c.auth.getUser();if(authError)throw authError;if(user.user?.id!==p.id)throw Error('Sessão alterada. Entre novamente.');
 const fresh=await loadProfile(c,p.id);if(fresh.empresa_id!==p.empresa_id)throw Error('A empresa do usuário mudou. Entre novamente.');
 product(snapshot,p.empresa_id);if(!Number.isFinite(amount)||amount<0||amount>999999999.9999||Math.abs(amount*10000-Math.round(amount*10000))>0.001)throw Error('Quantidade inválida.');
 // Same table/stock column used by ERP. Compare-and-set prevents replacing a later sale.
 // Do not change schema, triggers, permissions, minimum stock, price or fiscal fields.
 const {data,error}=await c.from('produtos').update({quantidade_estoque:amount}).eq('empresa_id',p.empresa_id).eq('id',snapshot.id).eq('ativo',true).eq('tipo_fiscal','produto').eq('atualizado_em',snapshot.atualizado_em).eq('quantidade_estoque',snapshot.quantidade_estoque).select(fields);
 if(error)throw error;if(!data||data.length!==1)throw new StockConflict();return product(data[0],p.empresa_id);
}
export function readableError(e:unknown):string {
 const x=e as {code?:string;message?:string;name?:string};
 if(x?.code==='42501')return 'Acesso recusado pelo ERP. Confira a permissão Estoque.';
 if(x?.code==='PGRST301'||x?.code==='28000')return 'Sessão expirada. Entre novamente.';
 if(x?.name==='AbortError'||/network|fetch|timeout/i.test(x?.message||''))return 'Sem confirmação do servidor. Confira a conexão; não repita como uma nova contagem.';
 return x?.message||'Não foi possível concluir.';
}

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { secureStorage } from './secureStorage';
import { canReadHistory } from './commerce';
import { exactProduct, gtinVariants, validateProducts, validateProfile, type Profile } from './domain';

const url = process.env.EXPO_PUBLIC_SUPABASE_URL || '';
const key = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY || '';
export function publicConfigValid(endpoint: string, publicKey: string): boolean {
  try {
    const u = new URL(endpoint);
    if (u.protocol !== 'https:' || u.username || u.password || /SEU-|COLE_AQUI/i.test(endpoint)) return false;
    if (publicKey.startsWith('sb_publishable_')) return publicKey.length > 25;
    // Legacy anon JWTs only. Never accept service_role or opaque secret keys.
    const part = publicKey.split('.')[1];
    return !!part && JSON.parse(atob(part.replace(/-/g, '+').replace(/_/g, '/'))).role === 'anon';
  } catch { return false; }
}
const timedFetch: typeof fetch = async (input, init) => {
  const controller = new AbortController();
  const cancel = () => controller.abort();
  init?.signal?.addEventListener('abort', cancel);
  if (init?.signal?.aborted) controller.abort();
  const timer = setTimeout(cancel, 20000);
  try { return await fetch(input, { ...init, signal: controller.signal }); }
  finally { clearTimeout(timer); init?.signal?.removeEventListener('abort', cancel); }
};
export const client = publicConfigValid(url, key) ? createClient(url, key, {
  auth: { storage: secureStorage, autoRefreshToken: true, persistSession: true, detectSessionInUrl: false },
  global: { fetch: timedFetch },
}) : null;
export const legacyStorageKey = (() => { try { return `sb-${new URL(url).hostname.split('.')[0]}-auth-token`; } catch { return ''; } })();

export async function loadProfile(c: SupabaseClient, userId: string): Promise<Profile> {
  const { data, error } = await c.from('perfis')
    .select('id,empresa_id,nome,papel,permissoes,ativo,empresas(nome,bloqueado,status_conta)')
    .eq('id', userId).single();
  if (error) throw error;
  return validateProfile(data, userId);
}
export async function searchProducts(c: SupabaseClient, term: string, barcode = false) {
  // Same RPC as ERP: server derives empresa from auth.uid(), enforces PDV and RLS.
  // Never fall back to unrestricted tables or accept an empresa_id from the UI.
  const text = term.trim().slice(0, 80);
  if (!text) return [];
  const args = barcode ? { p_codigo: text, p_gtins: gtinVariants(text), p_limite: 50 }
    : { p_busca: text, p_limite: 40 };
  const { data, error } = await c.rpc('pdv_produtos_consultar', args);
  if (error) throw error;
  const products = validateProducts(data);
  if (!barcode) return products;
  const match = exactProduct(products, text);
  return match ? [match] : [];
}
export function readableError(error: unknown): string {
  const e = error as { message?: string; code?: string; name?: string; status?: number };
  if (e?.status === 401 || e?.code === 'PGRST301') return 'Sua sessão expirou. Saia e entre novamente.';
  if (e?.code === '42501') return 'Acesso não autorizado pelo ERP. Confira as permissões do seu usuário.';
  if (e?.name === 'AbortError' || /network|fetch|timeout/i.test(e?.message || '')) return 'Não foi possível conectar. Confira a internet e tente novamente.';
  if (e?.code === 'PGRST202') return 'A integração solicitada não está disponível neste banco. Confira a aplicação da migração do PDV Móvel.';
  return e?.message || 'Não foi possível concluir. Tente novamente.';
}

// Reuse both existing ERP login routes; username is never treated as an Auth email.
export async function loginERP(c: SupabaseClient, email: string, password: string, username: string) {
  if (!email.trim() || !password) throw Error('Informe e-mail e senha.');
  if (!username.trim()) {
    const { error } = await c.auth.signInWithPassword({ email: email.trim(), password });
    if (error) throw error;
    return;
  }
  const response = await timedFetch(`${url}/functions/v1/florest-login`, {
    method: 'POST', headers: { 'content-type': 'application/json', apikey: key, authorization: `Bearer ${key}` },
    body: JSON.stringify({ empresa: email.trim(), usuario: username.trim(), senha: password, superficie: 'erp' }),
  });
  const result = await response.json().catch(() => null);
  if (!response.ok || !result?.ok || typeof result.session?.access_token !== 'string' || typeof result.session?.refresh_token !== 'string') throw Error(result?.mensagem || 'Empresa, usuário ou senha inválidos.');
  const { error } = await c.auth.setSession({ access_token: result.session.access_token, refresh_token: result.session.refresh_token });
  if (error) throw error;
}
export async function searchCustomers(c: SupabaseClient, profile: Profile, term: string) {
  validateProfile(profile, profile.id);
  const safe = term.trim().replace(/[,()"'\\%*]/g, ' ').replace(/\s+/g, ' ').trim().slice(0,80);
  let query = c.from('clientes').select('id,nome').eq('empresa_id', profile.empresa_id);
  if (safe) query = query.ilike('nome', `%${safe}%`);
  const { data, error } = await query.order('nome').order('id').limit(40);
  if (error) throw error;
  if (!Array.isArray(data) || data.some(p => typeof p.id !== 'string' || typeof p.nome !== 'string')) throw Error('Resposta de clientes inválida.');
  return data as import('./commerce').Customer[];
}
export async function historyPage(c: SupabaseClient, profile: Profile, search: string, offset: number, filters?: import('./commerce').HistoryFilters) {
  validateProfile(profile, profile.id);
  const f=filters || { start:'',end:'',number:search.trim(),customer:'',cash:'',operator:'' };
  const { data, error } = await c.rpc('pdv_movel_vendas_listar', { p_filtros:{inicio:f.start,fim:f.end,numero:f.number || search.trim(),cliente:f.customer,caixa:f.cash,operador:canReadHistory(profile)?f.operator:''},p_limite:100,p_offset:offset });
  if (error) throw error;
  if (!Array.isArray(data) || data.some(r => typeof r.id !== 'string' || typeof r.criado_em !== 'string' || !Number.isFinite(Number(r.total)))) throw Error('Resposta do histórico inválida.');
  return data.map(r => ({ ...r, total: Number(r.total) })) as import('./commerce').SaleRow[];
}
export async function historyDetail(c: SupabaseClient, profile: Profile, id: string) {
  validateProfile(profile, profile.id);
  const { data, error } = await c.rpc('pdv_movel_venda_detalhar', { p_venda: id });
  if (error) throw error;
  if (!data?.venda || data.venda.id !== id || !Array.isArray(data.itens) || !Array.isArray(data.pagamentos)) throw Error('Detalhes da venda inválidos.');
  // The server keeps the immutable mobile adjustment audit in sale order. Only
  // enrich matching products; never infer a discount from a net unit price.
  const audit=data.venda.pdv_movel_ajustes;
  if(data.venda.pdv_movel_caixa_id && Array.isArray(audit)) data.itens=data.itens.map((item: { produto_id?: string }, index: number)=>{
    const row=audit[index];
    if(!row || row.produto_id!==item.produto_id)return item;
    return {...item,desconto:Number(row.desconto||0),acrescimo:Number(row.acrescimo||0)};
  });
  return data as { venda: import('./commerce').SaleRow; cliente_nome?: string; titulo?: { id: string; saldo_aberto: number; vencimento: string } | null; itens: { nome: string; quantidade: number; preco_unitario: number; desconto?: number; acrescimo?: number }[]; pagamentos: { forma_pagamento: string; valor: number }[] };
}

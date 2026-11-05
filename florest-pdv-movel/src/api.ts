import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { secureStorage } from './secureStorage';
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
  if (e?.code === 'PGRST202') return 'A consulta de produtos do ERP não está disponível. Fale com o administrador.';
  return e?.message || 'Não foi possível concluir. Tente novamente.';
}

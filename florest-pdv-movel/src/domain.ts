export type Product = {
  id: string; nome: string; codigo: string | null; gtin: string | null;
  preco_venda: number; quantidade_estoque?: number; unidade_comercial?: string;
  venda_granel?: boolean; ativo?: boolean;
};
export type CartItem = { product: Product; quantity: number };
export type Profile = {
  id: string; empresa_id: string; nome: string; papel: string; permissoes: string[]; ativo: boolean;
  empresas: { nome: string; bloqueado: boolean; status_conta: string };
};
export function validateProfile(value: unknown, userId: string): Profile {
  const p = value as Profile | null;
  if (!p || p.id !== userId || !p.empresa_id || !p.empresas) throw Error('Não foi possível identificar sua empresa. Confira seu cadastro no ERP.');
  if (p.ativo !== true) throw Error('Usuário desativado. Fale com o administrador.');
  if (p.empresas.bloqueado || p.empresas.status_conta === 'pendente') throw Error('Acesso da empresa bloqueado ou aguardando aprovação.');
  if (p.papel !== 'proprietario' && (p.papel !== 'funcionario' || !Array.isArray(p.permissoes) || !p.permissoes.includes('pdv'))) throw Error('Seu usuário não tem permissão para usar o PDV.');
  return p;
}
export const money = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
export function parseQuantity(text: string): number {
  if (!/^\d{1,7}([.,]\d{1,3})?$/.test(text.trim())) throw Error('Informe uma quantidade positiva com até três casas decimais.');
  const n = Number(text.trim().replace(',', '.'));
  if (!(n > 0) || !Number.isFinite(n)) throw Error('Quantidade inválida.');
  return n;
}
export const itemCents = (item: CartItem) => Math.round(Number(item.product.preco_venda) * item.quantity * 100);
export const totalCents = (items: CartItem[]) => items.reduce((s, i) => s + itemCents(i), 0);
export const gtinKey = (v: string) => v.replace(/\D/g, '').replace(/^0+/, '');
export function gtinVariants(v: string): string[] {
  if (!/^\d{1,14}$/.test(v)) return [];
  const base = gtinKey(v);
  if (!base) return [];
  return [...new Set([v, base, ...[8, 12, 13, 14].filter(n => n >= base.length).map(n => base.padStart(n, '0'))])];
}
export function exactProduct(items: Product[], code: string): Product | null {
  const barcode = /^\d+$/.test(code) ? gtinKey(code) : '';
  return items.find(p => barcode && p.gtin && gtinKey(p.gtin) === barcode)
    || items.find(p => p.codigo === code) || null;
}
export function validateProducts(value: unknown): Product[] {
  if (!Array.isArray(value)) throw Error('Resposta inesperada da consulta de produtos.');
  return value.filter(p => p.ativo !== false).map(p => {
    if (!p.id || typeof p.nome !== 'string' || !Number.isFinite(Number(p.preco_venda)) || Number(p.preco_venda) < 0) throw Error('Produto com dados de venda inválidos. Confira o cadastro no ERP.');
    return { ...p, preco_venda: Number(p.preco_venda) };
  });
}
export function newerVersion(candidate: string, current: string): boolean {
  const parse = (v: string) => /^\d+\.\d+\.\d+$/.test(v) ? v.split('.').map(Number) : null;
  const a = parse(candidate), b = parse(current);
  if (!a || !b) return false;
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return false;
}
export function validUpdate(value: unknown, current: string, manifest: string): { version: string; apkUrl: string } | null {
  const m = value as { version?: string; apkUrl?: string } | null;
  if (!m || typeof m.version !== 'string' || typeof m.apkUrl !== 'string' || !newerVersion(m.version, current)) return null;
  try {
    const source = new URL(manifest), target = new URL(m.apkUrl);
    if (source.protocol !== 'https:' || target.protocol !== 'https:' || source.origin !== target.origin || target.username || target.password) return null;
    return { version: m.version, apkUrl: target.href };
  } catch { return null; }
}

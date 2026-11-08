export type Profile = { id: string; empresa_id: string; nome: string; papel: string; permissoes: string[]; ativo: boolean; empresas: {nome: string; bloqueado: boolean; status_conta: string} };
export type Product = {id: string; empresa_id: string; nome: string; codigo: string|null; gtin: string|null; unidade_comercial: string|null; quantidade_estoque: number; atualizado_em: string; ativo: boolean; tipo_fiscal: string};
export type Inventory = {id: string; empresa_id: string; operador_id: string; operador_nome: string; empresa_nome: string; numero: number; aberto_em: string; fechado_em: string|null; status: 'aberto'|'fechado'};
export type Count = {id: string; inventario_id: string; empresa_id: string; operador_id: string; produto: Product; quantidade: number; criado_em: string; confirmado_em: string|null; status: 'pendente'|'confirmado'|'conferir'|'nao_aplicado'|'encerrado_sem_confirmacao'; mensagem: string; observado?: Product};
export function validateProfile(value: unknown, user: string): Profile {
  const p = value as Profile;
  if (!p || p.id !== user || !p.empresa_id || !p.empresas) throw Error('Não foi possível identificar a empresa deste usuário.');
  if (!p.ativo || p.empresas.bloqueado || p.empresas.status_conta !== 'aprovado') throw Error('Usuário ou empresa sem acesso ativo.');
  if (p.papel !== 'proprietario' && (!Array.isArray(p.permissoes) || !p.permissoes.includes('estoque'))) throw Error('Seu usuário precisa da permissão Estoque no ERP.');
  return p;
}
export function quantity(text: string): number {
  if (!/^\d{1,9}([.,]\d{1,4})?$/.test(text.trim())) throw Error('Informe uma quantidade de zero a 999999999,9999, com até quatro casas decimais.');
  const n = Number(text.trim().replace(',', '.'));
  if (!Number.isFinite(n) || n < 0) throw Error('Quantidade inválida.');
  return n;
}
export function product(value: unknown, company: string): Product {
  const p = value as Product;
  if (!p || typeof p.id !== 'string' || p.empresa_id !== company || typeof p.nome !== 'string' || !p.atualizado_em || !Number.isFinite(Date.parse(p.atualizado_em)) || !Number.isFinite(Number(p.quantidade_estoque)) || !p.ativo || p.tipo_fiscal !== 'produto') throw Error('Produto indisponível para contagem.');
  return {...p, quantidade_estoque: Number(p.quantidade_estoque)};
}
export function gtins(code: string): string[] {
  if (!/^\d{1,14}$/.test(code)) return [];
  const base = code.replace(/^0+/, '') || '0';
  return [...new Set([code,base,...[8,12,13,14].filter(n=>n>=base.length).map(n=>base.padStart(n,'0'))])];
}
export const formatQuantity = (n: number) => n.toLocaleString('pt-BR',{maximumFractionDigits:4});
export const formatDate = (s: string|null) => s ? new Date(s).toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo'}) : '—';
function cell(value: unknown): string {
  let s=String(value ?? '');
  if(typeof value === 'string' && /^[\s]*[=+@\-]/.test(s)) s="'"+s;
  return '"'+s.replace(/"/g,'""')+'"';
}
export function reportCSV(inv: Inventory, rows: Count[]): string {
  const header=['Inventário','Empresa','Operador','Abertura','Fechamento','Produto','Código','Código de barras','Unidade','Saldo anterior','Quantidade informada','Diferença','Situação','Data da contagem','Data da confirmação','Observação'];
  const lines=rows.map(r=>[inv.numero,inv.empresa_nome,inv.operador_nome,inv.aberto_em,inv.fechado_em,r.produto.nome,r.produto.codigo,r.produto.gtin,r.produto.unidade_comercial,r.produto.quantidade_estoque,r.quantidade,Number((r.quantidade-r.produto.quantidade_estoque).toFixed(4)),r.status,r.criado_em,r.confirmado_em,r.mensagem]);
  return '\uFEFF'+[header,...lines].map(row=>row.map(cell).join(';')).join('\r\n');
}

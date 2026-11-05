import { type CartItem, type Profile } from './domain';
export type Customer = { id: string; nome: string };
export type Payment = { id: number; method: string; cents: number; band?: string };
export const PAYMENT_METHODS = ['Dinheiro', 'Pix', 'Cartão de Crédito', 'Cartão de Débito'] as const;
export const DEFAULT_CUSTOMER = { id: '', nome: 'Consumidor Padrão' };
export function parseCents(text: string): number {
  if (!/^\d{1,8}([.,]\d{1,2})?$/.test(text.trim())) throw Error('Informe um valor positivo com até duas casas decimais.');
  const [whole, fraction = ''] = text.trim().replace(',', '.').split('.');
  return Number(whole) * 100 + Number(fraction.padEnd(2, '0'));
}
export function adjustedUnitCents(item: CartItem): number {
  const base = Math.round(item.product.preco_venda * 100), discount = item.discountCents || 0, surcharge = item.surchargeCents || 0;
  if (![base, discount, surcharge].every(n => Number.isSafeInteger(n) && n >= 0) || discount > base) throw Error('Desconto inválido: não pode superar o preço unitário.');
  const result = base - discount + surcharge;
  if (result > 9999999999) throw Error('Valor do item excede o limite.');
  return result;
}
export function adjustedItemCents(item: CartItem): number {
  const quantity = Math.round(item.quantity * 1000);
  if (!Number.isSafeInteger(quantity) || quantity <= 0) throw Error('Quantidade inválida.');
  const product = quantity * adjustedUnitCents(item);
  if (!Number.isSafeInteger(product)) throw Error('Valor do item excede o limite.');
  return Math.floor((product + 500) / 1000);
}
export function draftTotal(items: CartItem[]): number { return items.reduce((n, item) => n + adjustedItemCents(item), 0); }
export function addPayment(payments: Payment[], method: string, cents: number, total: number, id: number): Payment[] {
  if (!PAYMENT_METHODS.includes(method as typeof PAYMENT_METHODS[number])) throw Error('Forma de pagamento inválida.');
  if (payments.length >= 10) throw Error('Limite de dez lançamentos por venda.');
  const remaining = total - payments.reduce((s, p) => s + p.cents, 0);
  if (!Number.isSafeInteger(cents) || cents <= 0 || cents > remaining) throw Error('O pagamento deve ser positivo e não superar o restante.');
  return [...payments, { id, method, cents }];
}
export function validateCredit(customer: Customer, payments: Payment[], total: number) {
  if (!customer.id) throw Error('Nota a prazo exige cliente cadastrado no ERP.');
  if (payments.length) throw Error('Nota a prazo integral não pode ser combinada com valores recebidos.');
  if (total <= 0) throw Error('Inclua produtos com total positivo.');
}
export function canReadHistory(p: Profile): boolean { return p.papel === 'proprietario' || p.permissoes.includes('financeiro'); }
export type SaleRow = { id: string; numero_venda: number | string; criado_em: string; total: number; cliente_nome?: string; caixa_id?: string; caixa_numero?: number; operador_nome?: string; origem?: string; cancelada_em?: string };
export type HistoryFilters = { start: string; end: string; number: string; customer: string; cash: string; operator: string };
function day(value: string): boolean {
  const date = new Date(value+'T12:00:00Z');
  return /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(date.getTime()) && date.toISOString().slice(0,10) === value;
}
export function validateFilters(f: HistoryFilters) {
  for (const value of [f.start, f.end]) if (value && !day(value)) throw Error('Data inválida. Use AAAA-MM-DD.');
  if (f.start && f.end && f.start > f.end) throw Error('Data inicial deve ser anterior à final.');
}
export function saleDay(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(date);
  return ['year','month','day'].map(t => parts.find(p => p.type === t)?.value).join('-');
}
export function filterSales(rows: SaleRow[], f: HistoryFilters): SaleRow[] {
  validateFilters(f);
  const includes = (a: unknown, b: string) => !b.trim() || String(a ?? '').toLocaleLowerCase('pt-BR').includes(b.trim().toLocaleLowerCase('pt-BR'));
  return rows.filter(r => { const date = saleDay(r.criado_em); return (!f.start || date >= f.start) && (!f.end || date <= f.end) && includes(r.numero_venda, f.number) && includes(r.cliente_nome, f.customer) && includes(r.caixa_numero ?? r.caixa_id, f.cash) && includes(r.operador_nome, f.operator); });
}

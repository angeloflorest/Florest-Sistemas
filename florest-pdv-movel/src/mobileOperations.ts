// Durable online operations. The transport must bind these methods to a verified
// backend contract; this engine never guesses RPC names or falls back to main PDV.
export type OperationScope = { userId: string; companyId: string; deviceId: string };
export type OperationKind = 'sale' | 'open-cash' | 'close-cash';
export type Confirmed = { state: 'confirmed'; operationKey: string; companyId: string; deviceId: string; result: Record<string, unknown> };
export type Rejected = Omit<Confirmed, 'state'> & { state: 'rejected'; error: string };
export type Outcome = Confirmed | Rejected;
export type Lookup = Outcome | { state: 'absent'; operationKey: string; companyId: string; deviceId: string };
export interface MobileTransport {
  submit(scope: OperationScope, kind: OperationKind, key: string, request: Record<string, unknown>): Promise<Outcome>;
  lookup(scope: OperationScope, kind: OperationKind, key: string): Promise<Lookup>;
}
export interface OperationStorage { getItem(key: string): Promise<string | null>; setItem(key: string, value: string): Promise<void>; removeItem(key: string): Promise<void> }
export type PendingOperation = { version: 1; scope: OperationScope; kind: OperationKind; key: string; request: Record<string, unknown>; phase: 'prepared' | 'unknown' | 'confirmed' | 'rejected'; result?: Record<string, unknown> };
const runningScopes = new Set<string>();
const scopeKey = (s: OperationScope) => {
  for (const value of [s.userId,s.companyId,s.deviceId]) if (!/^[A-Za-z0-9_-]{1,100}$/.test(value)) throw Error('Identificação da operação inválida.');
  return `florest.mobile.${s.userId}.${s.companyId}.${s.deviceId}`;
};
function canonical(value: unknown): string {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return JSON.stringify(value);
  if (typeof value === 'number' && Number.isFinite(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return '['+value.map(canonical).join(',')+']';
  if (typeof value === 'object' && value) return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical((value as Record<string,unknown>)[k])).join(',')+'}';
  throw Error('Dados da operação inválidos.');
}
export class MobileOperationEngine {
  private storageKey: string;
  constructor(private scope: OperationScope, private store: OperationStorage, private transport: MobileTransport, private newKey: () => string) { this.storageKey=scopeKey(scope); }
  async pending(): Promise<PendingOperation | null> {
    const raw=await this.store.getItem(this.storageKey);
    if (!raw) return null;
    const value=JSON.parse(raw) as PendingOperation;
    if (value.version!==1 || scopeKey(value.scope)!==this.storageKey || !['sale','open-cash','close-cash'].includes(value.kind) || !['prepared','unknown','confirmed','rejected'].includes(value.phase) || typeof value.key!=='string' || !value.key || typeof value.request!=='object' || value.request===null) throw Error('Operação pendente inválida. Não inicie outra venda; recupere o estado no servidor.');
    canonical(value.request);
    return value;
  }
  private async exclusive<T>(fn: () => Promise<T>): Promise<T> {
    if (runningScopes.has(this.storageKey)) throw Error('Operação em andamento. Aguarde a confirmação.');
    runningScopes.add(this.storageKey);
    try { return await fn(); } finally { runningScopes.delete(this.storageKey); }
  }
  private verify(result: Lookup, pending: PendingOperation): void {
    if (result.state!=='absent' && (!result.result || typeof result.result!=='object' || (result.state==='rejected' && typeof result.error!=='string'))) throw Error('Recibo inválido do servidor.');
    if (result.operationKey!==pending.key || result.companyId!==this.scope.companyId || result.deviceId!==this.scope.deviceId || !['confirmed','rejected','absent'].includes(result.state)) throw Error('Resposta do servidor não corresponde à operação deste dispositivo.');
  }
  private async confirm(pending: PendingOperation, result: Outcome): Promise<Outcome> {
    this.verify(result,pending);
    // Keep the receipt until explicitly acknowledged: crash/restart cannot lose it.
    await this.store.setItem(this.storageKey,JSON.stringify({...pending,phase:result.state,result:result.result}));
    return result;
  }
  async execute(kind: OperationKind, request: Record<string, unknown>): Promise<Outcome> {
    return this.exclusive(async()=>{
      const previous=await this.pending();
      if (previous) throw Error('Existe operação anterior pendente. Consulte ou reconheça o resultado antes de continuar.');
      const key=this.newKey();
      if (!/^[A-Za-z0-9_-]{8,100}$/.test(key)) throw Error('Chave de operação inválida.');
      const immutable=JSON.parse(canonical(request));
      const pending: PendingOperation={version:1,scope:{...this.scope},kind,key,request:immutable,phase:'prepared'};
      // Commit both request and key BEFORE the first network write.
      await this.store.setItem(this.storageKey,JSON.stringify(pending));
      return this.send(pending);
    });
  }
  private async send(pending: PendingOperation): Promise<Outcome> {
    try { return await this.confirm(pending,await this.transport.submit(this.scope,pending.kind,pending.key,pending.request)); }
    catch(error) {
      // This includes response loss and receipt-persistence failure. Never assume rejection.
      await this.store.setItem(this.storageKey,JSON.stringify({...pending,phase:'unknown'})).catch(()=>{});
      throw error;
    }
  }
  async recover(retryIfAbsent = false): Promise<Lookup | null> {
    return this.exclusive(async()=>{
      const pending=await this.pending(); if (!pending) return null;
      // Always ask server, even if a local receipt exists. Never send automatically.
      const result=await this.transport.lookup(this.scope,pending.kind,pending.key);
      this.verify(result,pending);
      if (result.state!=='absent') return this.confirm(pending,result);
      // Explicit retry retains the exact same key and immutable payload. Backend must
      // serialize this key even if its first transaction is still running at lookup time.
      return retryIfAbsent ? this.send(pending) : result;
    });
  }
  async acknowledge(): Promise<void> {
    return this.exclusive(async()=>{
      const pending=await this.pending(); if (!pending) return;
      const result=await this.transport.lookup(this.scope,pending.kind,pending.key);
      this.verify(result,pending);
      if (result.state==='absent') throw Error('Não é seguro descartar uma operação sem confirmação do servidor.');
      await this.store.removeItem(this.storageKey);
    });
  }
}

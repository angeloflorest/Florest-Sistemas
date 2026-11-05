import type { SupabaseClient } from '@supabase/supabase-js';
import type { MobileTransport, OperationScope, Outcome, Lookup } from './mobileOperations';
export type CashSummary = { quantidade_vendas: number; total_vendido: number; nota_prazo: number; dinheiro_esperado: number; por_forma: { forma_pagamento: string; total: number }[] };
export type MobileCash = { id: string; numero: number; dispositivo_id: string; dispositivo_nome: string; status: 'aberto' | 'fechado'; aberto_em: string; aberto_por: string; aberto_por_nome: string; valor_inicial: number; fechado_em: string | null; fechado_por_nome: string | null; fechamento_resumo: CashSummary | null; resumo?: CashSummary };
export type FeeConfig = { id: string | null; ativo: boolean; regras: { forma: string; bandeira: string | null; percentual: number }[] };
export type MobileContext = { contract: number; empresa_id: string; usuario_id: string; dispositivo_id: string; caixa: MobileCash | null; resumo: CashSummary | null; venda_habilitada: boolean; motivo: string | null; taxas: FeeConfig };
async function rpc<T>(c: SupabaseClient,name: string,args: Record<string,unknown>): Promise<T> {
 const {data,error}=await c.rpc(name,args); if(error)throw error; if(data===null)throw Error('Resposta vazia do PDV Móvel.');return data as T;
}
export async function mobileContext(c: SupabaseClient,scope: OperationScope): Promise<MobileContext> {
 const data=await rpc<MobileContext>(c,'pdv_movel_contexto',{p_dispositivo:scope.deviceId});
 if(data.contract!==1 || data.empresa_id!==scope.companyId || data.usuario_id!==scope.userId || data.dispositivo_id!==scope.deviceId || typeof data.venda_habilitada!=='boolean')throw Error('Contexto do caixa móvel incompatível com a sessão.');
 return data;
}
export function mobileTransport(c: SupabaseClient): MobileTransport {
 return {
  submit:(scope,kind,key,request)=>rpc<Outcome>(c,'pdv_movel_operar',{p_dispositivo:scope.deviceId,p_tipo:kind,p_chave:key,p_pedido:request}),
  lookup:(scope,kind,key)=>rpc<Lookup>(c,'pdv_movel_operacao_consultar',{p_dispositivo:scope.deviceId,p_tipo:kind,p_chave:key}),
 };
}
export const mobileCashHistory=(c: SupabaseClient,device: string)=>rpc<MobileCash[]>(c,'pdv_movel_caixas_listar',{p_dispositivo:device});

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { CartItem, Profile } from './domain';
import type { Customer, Payment } from './commerce';
import { secureStorage } from './secureStorage';
import { newOperationKey } from './deviceIdentity';
import { MobileOperationEngine, type Lookup, type OperationKind } from './mobileOperations';
import { mobileContext, mobileTransport, mobileCashHistory, type MobileContext, type MobileCash } from './mobileGateway';
import { readableError } from './api';
export function useMobilePOS(c: SupabaseClient | null,p: Profile | null,device: string,onSaleDone: ()=>void) {
 const tag = p&&device ? `${p.id}|${p.empresa_id}|${device}` : '';
 const currentTag=useRef(tag);currentTag.current=tag;
 const live=()=>currentTag.current===tag;
 const engine=useMemo(()=>c&&p&&device ? new MobileOperationEngine({userId:p.id,companyId:p.empresa_id,deviceId:device},secureStorage,mobileTransport(c),newOperationKey):null,[c,p?.id,p?.empresa_id,device]);
 const [context,setContext]=useState<MobileContext|null>(null),[history,setHistory]=useState<MobileCash[]>([]),[error,setError]=useState(''),[busy,setBusy]=useState(false),[pending,setPending]=useState(false),[receipt,setReceipt]=useState<Lookup|null>(null),[kind,setKind]=useState<OperationKind|null>(null);
 const refresh=useCallback(async()=>{
  if(!c||!p||!device)return;
  const scope={userId:p.id,companyId:p.empresa_id,deviceId:device};
  const ctx=await mobileContext(c,scope); const boxes=await mobileCashHistory(c,device); if(live()){setContext(ctx);setHistory(boxes);}
 },[c,p?.id,p?.empresa_id,device]);
 useEffect(()=>{
  let active=true;setContext(null);setHistory([]);setError('');setPending(false);setReceipt(null);setKind(null);
  if(!engine){setBusy(false);return;}
  setBusy(true);
  (async()=>{const saved=await engine.pending();if(!active)return;setPending(!!saved);setKind(saved?.kind||null);if(saved){const r=await engine.recover();if(active)setReceipt(r);}if(active)await refresh();})().catch(e=>{if(active)setError(readableError(e));}).finally(()=>{if(active)setBusy(false);});
  return()=>{active=false;};
 },[engine,refresh]);
 const run=async(type: OperationKind,request:Record<string,unknown>)=>{
  if(!engine)throw Error('Dispositivo ou sessão ainda não confirmado.');
  setBusy(true);setError('');setKind(type);
  try{const r=await engine.execute(type,request);if(live()){setPending(true);setReceipt(r);await refresh();}
   if(r.state==='confirmed'){
     await engine.acknowledge();
     if(live()){setPending(false);setReceipt(null);setKind(null);if(type==='sale')onSaleDone();await refresh();}
   }
   return r;}
  catch(e){const saved=await engine.pending();if(live()){setPending(!!saved);setError(readableError(e));}throw e;}
  finally{if(live())setBusy(false);}
 };
 const recover=async(retry=false)=>{
  if(!engine)return;setBusy(true);setError('');
  try{const saved=await engine.pending();const reply=await engine.recover(retry);const pending=await engine.pending();if(live()){setKind(saved?.kind||null);setReceipt(reply);setPending(!!pending);await refresh();}}
  catch(e){if(live())setError(readableError(e));}finally{if(live())setBusy(false);}
 };
 const acknowledge=async()=>{
  if(!engine)return;setBusy(true);setError('');
  try{const saved=await engine.pending();const r=await engine.recover();if(!r||r.state==='absent')throw Error('O servidor ainda não confirmou o resultado.');await engine.acknowledge();if(!live())return;if(saved?.kind==='sale'&&r.state==='confirmed')onSaleDone();setPending(false);setReceipt(null);setKind(null);await refresh();}
  catch(e){if(live())setError(readableError(e));}finally{if(live())setBusy(false);}
 };
 return {context,history,error,busy,pending,receipt,kind,refresh:async()=>{setBusy(true);try{setError('');await refresh();}catch(e){if(live())setError(readableError(e));}finally{if(live())setBusy(false);}},recover,acknowledge,
  open:(name:string,amount:number)=>run('open-cash',{nome:name,valor_inicial:amount}),
  close:async()=>{if(!context?.caixa)throw Error('Não há caixa aberto.');return run('close-cash',{caixa_id:context.caixa.id});},
  sell:async(cart:CartItem[],customer:Customer,payments:Payment[],credit:boolean)=>{
   if(!context?.caixa||!context.venda_habilitada||pending)throw Error(context?.motivo||'Caixa ainda não confirmado ou operação pendente.');
   return run('sale',{caixa_id:context.caixa.id,cliente_id:customer.id||null,prazo:credit,itens:cart.map(x=>({produto_id:x.product.id,quantidade:x.quantity,preco_base:x.product.preco_venda,desconto:(x.discountCents||0)/100,acrescimo:(x.surchargeCents||0)/100})),pagamentos:payments.map(x=>({forma_pagamento:x.method,valor:x.cents/100,taxas:{config_id:context.taxas.id,bandeira:x.band||null}}))});
  },
 };
}
export type MobilePOS=ReturnType<typeof useMobilePOS>;

// Transporte injetável: o banco confirma persistência antes do ACK e reserva comandos antes de enviá-los.
import {createIFoodClient} from './adapter.mjs';
import {normalizeOrder} from './core.mjs';
import {syncCatalog} from './catalog.mjs';
export async function syncCompany({empresa,rpc,fetchImpl=fetch}) {
 const cfg=await rpc('reservar',empresa);if(!cfg)return {ocupado:true};
 const api=createIFoodClient({enabled:true,...cfg.credenciais,merchants:[cfg.merchant_id],fetchImpl});
 const merchant=cfg.merchant_id,deadline=Date.now()+55000;let received=0;
 try {
  const events=await api.poll([merchant]);
  if(events.length){
   await rpc('eventos',empresa,{eventos:events});
   await api.acknowledge(events);
   await rpc('ack',empresa,{ids:events.map(e=>e.id)});received=events.length;
  }else await rpc('eventos',empresa,{eventos:[]});
  const waiting=await rpc('pendentes',empresa);
  for(const event of waiting){if(Date.now()>deadline)break;
   try{
    if(event.pedido_id){const order=await api.order(event.pedido_id,merchant);const normalized=normalizeOrder(order,cfg.vinculos);await rpc('pedido',empresa,{detalhe:order,normalizado:normalized});}
    await rpc('processar',empresa,{evento_id:event.evento_id});
   }catch(e){await rpc('falha_evento',empresa,{evento_id:event.evento_id,erro:e.message||'Falha ao processar pedido.'});}
  }
  for(const id of await rpc('revisar',empresa)){if(Date.now()>deadline)break;try{const order=await api.order(id,merchant);await rpc('pedido',empresa,{detalhe:order,normalizado:normalizeOrder(order,cfg.vinculos)});}catch{ /* Evento permanece guardado e visível para revisão. */ }}
  await rpc('agendados',empresa);
  for(const pending of await rpc('comandos',empresa)){if(Date.now()>deadline)break;
   const cmd=await rpc('reservar_comando',empresa,{id:pending.id});if(!cmd)continue;
   try {if(['aceitar_negociacao','recusar_negociacao'].includes(cmd.acao)){const {disputeId,...body}=cmd.payload;await api.dispute(disputeId,merchant,cmd.acao==='aceitar_negociacao'?'accept':'reject',body)}else await api.command(cmd.pedido_id,merchant,cmd.acao,cmd.payload);await rpc('resultado_comando',empresa,{id:cmd.id,estado:'enviado'});}
   catch(e){await rpc('resultado_comando',empresa,{id:cmd.id,estado:e.uncertain?'incerto':'falha'});}
  }
  await syncCatalog({empresa,merchant,api,rpc,deadline:Math.min(deadline,Date.now()+18000)});
  await rpc('liberar',empresa);return {recebidos:received};
 }catch(e){await rpc('liberar',empresa,{erro:e.message||'Falha de comunicação com o iFood.',espera_ms:e.retryAfter||0});throw e;}
}

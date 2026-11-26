import {createAPI,FoodError,safeError,commandSpec,achieved} from './core.mjs';
export async function runWorker({rpc,secret,fetchImpl=fetch,now=Date.now}){
 const lease=await rpc('reservar');if(!lease)return {ocupado:true};
 const api=createAPI({secret,rpc,fetchImpl,now});let failure;
 async function reconcile(id){
  try{const detalhe=await api.order(id);return await rpc('detalhe',{order_id:id,detalhe})}
  catch(error){await rpc('pedido_erro',{order_id:id,erro:safeError(error)});throw error}
 }
 try{
  // Pré-aquecer autenticação antes do próximo pedido, sem esperar um aceite falhar.
  await api.token();
  const queue=await rpc('fila'),checked=new Set();
  for(const event of queue.eventos){
   try{if(event.order_id&&!checked.has(event.order_id)){await reconcile(event.order_id);checked.add(event.order_id)}await rpc('evento_resultado',{id:event.id})}
   catch(error){await rpc('evento_resultado',{id:event.id,erro:safeError(error)})}
  }
  const cmd=queue.comando;
  if(cmd){
   try{
    // Reconciliar sempre antes de repetir um comando cujo resultado pode ser incerto.
    let order=checked.has(cmd.order_id)?await rpc('pedido',{order_id:cmd.order_id}):await reconcile(cmd.order_id);
    const metadata=await rpc('pedido',{order_id:cmd.order_id});order={...order,solicitacoes:metadata.solicitacoes};
    if(achieved(cmd,order))await rpc('comando_resultado',{id:cmd.id,estado:'confirmado'});
    else if(cmd.estado==='pendente'){
     const {path,payload}=commandSpec(cmd,order,now());
     await rpc('comando_resultado',{id:cmd.id,estado:'enviando'});
     try{
      const result=await api.send(path,cmd.order_id,payload);
      // errno:0 significa operação aceita. O estado do pedido ainda vem de consulta/evento.
      if(['confirmar','cancelar','retirada'].includes(cmd.acao)&&result.data!==true&&!(cmd.acao==='retirada'&&result.data&&typeof result.data==='object'))throw new FoodError('Resposta da operação não foi conclusiva.',{uncertain:true});
      const oneShot=['responder_cancelamento','responder_reembolso','entregue'].includes(cmd.acao);
      await rpc('comando_resultado',{id:cmd.id,estado:oneShot?'confirmado':'enviado',request_id:result.requestId});
      // Sem uma segunda consulta imediata: evento/cron confirma sem ultrapassar 10 consultas/10s.
     }catch(error){
      if(error.retryAfter)await rpc('comando_resultado',{id:cmd.id,estado:'pendente',erro:safeError(error)});
      else await rpc('comando_resultado',{id:cmd.id,estado:error.uncertain?'incerto':'falha',erro:safeError(error)});
     }
    }else if(order.status_99food>=900||order.status_99food===600){
     await rpc('comando_resultado',{id:cmd.id,estado:'falha',erro:'O pedido encerrou sem confirmar esta operação.'});
    }else if(cmd.estado==='enviando'){
     await rpc('comando_resultado',{id:cmd.id,estado:'incerto',erro:'Execução interrompida. Consultando a 99Food antes de qualquer repetição.'});
    }else{
     await rpc('comando_resultado',{id:cmd.id,estado:cmd.estado,erro:cmd.estado==='incerto'?'Resultado incerto; nenhuma repetição automática foi enviada.':undefined});
    }
    checked.add(cmd.order_id);
   }catch(error){
    // Validação falha antes do envio não deixa comando inválido bloquear os seguintes.
    if(error instanceof FoodError&&!error.retryAfter&&cmd.estado==='pendente')await rpc('comando_resultado',{id:cmd.id,estado:'falha',erro:safeError(error)});
    else failure=safeError(error);
   }
  }
  for(const id of queue.reconciliar||[]){if(checked.size>=4)break;if(!checked.has(id))try{await reconcile(id);checked.add(id)}catch(error){failure=safeError(error)}}
  return {ok:true,consultados:checked.size};
 }catch(error){failure=safeError(error);return {erro:failure}}
 finally{await rpc('liberar',{reserva:lease,erro:failure})}
}

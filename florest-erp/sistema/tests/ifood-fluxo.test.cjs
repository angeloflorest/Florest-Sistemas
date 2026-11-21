const test=require('node:test'),assert=require('node:assert/strict'),path=require('node:path');
const root=path.resolve(__dirname,'../../..'),merchant='9dc78f12-d874-4d66-a454-40268effa19d',id='11111111-1111-4111-8111-111111111111',eventId='22222222-2222-4222-8222-222222222222';
async function run({pending=[],commands=[],unacked=[],review=[],fetcher,action}={}){
 const calls=[],steps=[];const {syncCompany}=await import(root+'/supabase/functions/gastronomia-ifood/worker.mjs');
 await syncCompany({empresa:'isolated',rpc:async(a,e,d)=>{steps.push({a,d});if(action){const value=action(a,d);if(value!==undefined)return value}if(a==='reservar')return {merchant_id:merchant,credenciais:{clientId:'test',clientSecret:'test'},vinculos:[]};if(a==='h_token_obter')return {accessToken:'isolated-token',expiresAt:Date.now()+3600000};if(a==='pendentes')return pending;if(a==='comandos')return commands;if(a==='reservar_comando')return commands.find(c=>c.id===d.id);if(a==='acks_pendentes')return unacked;if(a==='revisar')return review;return []},fetchImpl:async(url,opt)=>{calls.push({url,opt});return fetcher?fetcher(url,opt):Response.json([])}});return {calls,steps};
}
test('CONFIRMED e CANCELLED já conhecidos são processados mesmo com consulta de detalhes indisponível',async()=>{
 for(const codigo of ['CONFIRMED','CANCELLED']){const {calls,steps}=await run({pending:[{evento_id:eventId,pedido_id:id,codigo,consultar_detalhe:false}],fetcher:async url=>{if(url.includes('/orders/'))throw Error('Detalhes indisponíveis');return Response.json([])}});assert(steps.some(s=>s.a==='processar'&&s.d.evento_id===eventId));assert(!steps.some(s=>s.a==='falha_evento'));assert(!calls.some(c=>c.url.includes('/orders/')))}
});
test('ACK persistido sem confirmação local é recuperado sem reenviar comando',async()=>{
 const {calls,steps}=await run({unacked:[{id:eventId,merchantId:merchant}]});const ack=calls.filter(c=>c.url.endsWith('/acknowledgment'));assert.equal(ack.length,1);assert.deepEqual(JSON.parse(ack[0].opt.body),[{id:eventId}]);assert(steps.some(s=>s.a==='ack'&&s.d.ids[0]===eventId));assert(!calls.some(c=>/\/confirm$|\/requestCancellation$/.test(c.url)));
});
test('confirmação é enviada antes da revisão lenta de outros pedidos',async()=>{
 const command={id:eventId,pedido_id:id,acao:'confirmar',payload:{}};const {calls,steps}=await run({commands:[command],review:[id],fetcher:async url=>url.endsWith('/confirm')?new Response(null,{status:202}):url.includes('/orders/')?new Response(null,{status:503}):Response.json([])});assert(calls.findIndex(c=>c.url.endsWith('/confirm'))<calls.findIndex(c=>c.url.endsWith('/orders/'+id)));assert.equal(steps.find(s=>s.a==='resultado_comando').d.status_http,202);
});
test('HTTP 204 sem política não é registrado como cancelamento aceito',async()=>{
 const {createIFoodClient}=await import(root+'/supabase/functions/gastronomia-ifood/adapter.mjs');const client=createIFoodClient({enabled:true,clientId:'test',clientSecret:'test',merchants:[merchant],fetchImpl:async url=>url.endsWith('/token')?Response.json({accessToken:'isolated',expiresIn:3600}):new Response(null,{status:204})});await assert.rejects(client.command(id,merchant,'solicitar_cancelamento',{cancellationCode:'503',reason:'Motivo válido'}),e=>e.status===204&&/política/.test(e.message));
});
test('agendamento aceita os formatos documentados sem antecipar início de preparo; PRS é reconhecido',async()=>{
 const {sampleOrder,normalizeOrder,eventRecord}=await import(root+'/supabase/functions/gastronomia-ifood/core.mjs');for(const field of ['schedule','scheduled']){const order=sampleOrder();order.orderTiming='SCHEDULED';order[field]={preparationStartDateTime:'2030-01-01T12:00:00Z'};const n=normalizeOrder(order);assert.equal(n.inicio_preparo,'2030-01-01T12:00:00Z');assert(!n.avisos.some(x=>x.includes('Agendamento')))}assert.equal(eventRecord({id:eventId,merchantId:merchant,orderId:id,code:'PRS',createdAt:new Date().toISOString()}).estado,'em_preparo');
});

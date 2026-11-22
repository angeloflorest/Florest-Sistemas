const {test}=require('node:test'),assert=require('node:assert/strict');
test('proteção do catálogo não limita confirmação e preserva resultados incertos',async()=>{
 let handler,calls=0;const oldDeno=globalThis.Deno,oldFetch=globalThis.fetch;
 globalThis.Deno={env:{get:()=> 'https://teste.invalid'},serve:fn=>handler=fn};
 try{
  await import('../../../supabase/functions/gastronomia-cardapio/index.ts?teste=leitura');
  const token='a'.repeat(64),chave='00000000-0000-4000-8000-000000000001';
  const request=acao=>new Request('https://teste.invalid',{method:'POST',headers:{'Content-Type':'application/json','x-forwarded-for':'192.0.2.1'},body:JSON.stringify({acao,token,chave,dados:{}})});
  globalThis.fetch=async()=>{calls++;return new Response(JSON.stringify({nome:'Cardápio'}))};
  for(let n=0;n<240;n++)assert.equal((await handler(request('catalogo'))).status,200);
  assert.equal((await handler(request('catalogo'))).status,429);assert.equal(calls,240);
  const success={numero:1,tipo:'retirada',segredo:'b'.repeat(64),total:25,pagamento_confirmado:false};
  globalThis.fetch=async()=>new Response(JSON.stringify(success));
  const confirmation=await handler(request('confirmar'));assert.equal(confirmation.status,200);assert.equal((await confirmation.json()).chave,chave);
  globalThis.fetch=async()=>new Response('{invalido');const uncertain=await handler(request('confirmar'));assert.equal(uncertain.status,502);assert.equal((await uncertain.json()).resultado,'incerto');
 }finally{globalThis.Deno=oldDeno;globalThis.fetch=oldFetch;}
});

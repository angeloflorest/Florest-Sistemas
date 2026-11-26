const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),{stripTypeScriptTypes}=require('node:module'),{createHash}=require('node:crypto');
test('webhook valida assinatura e vínculo, preserva IDs e persiste também eventos sem pedido',async()=>{
 const source=stripTypeScriptTypes(fs.readFileSync(path.join(__dirname,'../../../supabase/functions/gastronomia-99food-sandbox/index.ts'),'utf8'),{mode:'strip'}),originalFetch=global.fetch,originalDeno=global.Deno;let handler,written=[];
 global.Deno={env:{get:n=>({FOOD99_SANDBOX_APP_SECRET:'test-secret',SUPABASE_URL:'https://example.invalid',SUPABASE_SERVICE_ROLE_KEY:'service-test'})[n]},serve:fn=>{handler=fn}};
 global.fetch=async(u,o)=>{written.push(JSON.parse(o.body));return new Response('true')};
 try{
  await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
  const event={app_id:'5764607791191296200',app_shop_id:'florest-gastronomia-teste-01',type:'orderConfirm',data:{order_id:'5764702946243708669'}};
  async function send(e,{sign=true,status}={}){let raw=JSON.stringify(e).replace('"5764702946243708669"','5764702946243708669');const sig=createHash('md5').update(raw).update('test-secret').digest('hex');const r=await handler(new Request('https://test.invalid',{method:'POST',headers:{'didi-header-sign':sign?sig:'0'.repeat(32)},body:raw}));if(status)assert.equal(r.status,status);return r}
  await send(event,{status:200});assert.equal(written[0].p_dados.order_id,'5764702946243708669');
  await send(event,{sign:false,status:401});assert.equal(written.length,1);
  await send({...event,app_shop_id:'other'},{status:403});assert.equal(written.length,1);
  await send({...event,type:'shopBind',data:{order_id:0}},{status:200});assert.equal(written[1].p_dados.order_id,'');
  await send({...event,type:'orderNew',data:{order_id:0}},{status:400});
  await send({...event,data:{order_id:event.data.order_id,order_info:{shop:{shop_id:'111'}}}},{status:403});
  assert.equal((await (await handler(new Request('https://test.invalid'))).json()).errno,0);
 }finally{global.fetch=originalFetch;global.Deno=originalDeno}
});

const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),{pathToFileURL}=require('node:url'),{stripTypeScriptTypes}=require('node:module'),{createHash}=require('node:crypto');
test('webhook de produção verifica assinatura antes de persistir, isola empresa e não chama APIs no ACK',async()=>{
 const dir=path.join(__dirname,'../../../supabase/functions/gastronomia-99food'),source=stripTypeScriptTypes(fs.readFileSync(path.join(dir,'index.ts'),'utf8')).replace(/from '(\.\/[^']+)'/g,(_,v)=>"from '"+pathToFileURL(path.join(dir,v)).href+"'");let handler,calls=[];const originalDeno=global.Deno,originalFetch=global.fetch;
 global.Deno={env:{get:n=>({SUPABASE_URL:'https://example.invalid',SUPABASE_SERVICE_ROLE_KEY:'service',SUPABASE_ANON_KEY:'anon'})[n]},serve:fn=>handler=fn};
 global.fetch=async(url,options)=>{assert.match(String(url),/example.invalid\/rest\/v1\/rpc\//);const body=JSON.parse(options.body);calls.push(body);return Response.json(body.p_acao==='resolver'?{empresa_id:'company-a',segredo:'secret-production'}:true)};
 try{await import('data:text/javascript;base64,'+Buffer.from('const Buffer=undefined;\n'+source).toString('base64'));
 const raw='{"app_id":5764700000000000001,"app_shop_id":"loja-a","type":"orderNew","data":{"order_id":5764703136254068546}}';
 const send=signature=>handler(new Request('https://edge.invalid',{method:'POST',headers:{'didi-header-sign':signature},body:raw}));
 assert.equal((await send('0'.repeat(32))).status,401);assert.equal(calls.length,1);assert.equal(calls[0].p_dados.app_id,'5764700000000000001');calls=[];
 const result=await send(createHash('md5').update(raw).update('secret-production').digest('hex'));assert.equal(result.status,200);assert.equal((await result.json()).errno,0);assert.equal(calls.length,2);assert.equal(calls[1].p_empresa,'company-a');assert.equal(calls[1].p_dados.order_id,'5764703136254068546');
 assert.equal((await handler(new Request('https://edge.invalid',{method:'POST',body:'{"acao":"estado"}'}))).status,401);
 }finally{global.Deno=originalDeno;global.fetch=originalFetch}
});

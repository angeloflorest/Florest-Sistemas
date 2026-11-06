const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../configuracao-nfe55.js'),'utf8');
const moduleUrl='data:text/javascript;base64,'+Buffer.from(source).toString('base64');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
test('numeração NF-e: série configurável, último 150 implica próximo 151, confirmação obrigatória',async()=>{
 const {validarNumeracaoNfe55:v}=await import(moduleUrl);
 assert.deepEqual(v('1','150',true),{p_serie:'1',p_ultimo_numero:150,p_confirmado:true});assert.equal(v('12','0',true).p_serie,'12');
 for(const args of [['','150',true],['0','150',true],['1000','150',true],['01','150',true],['1','1.5',true],['1','-1',true],['1','999999999',true],['1','150',false],['1','150','true']])assert.throws(()=>v(...args));
});
test('navegador: salva somente NF-e por empresa, troca série e ignora resposta após mudança de sessão',{skip:!process.env.NFE55_BROWSER},async()=>{
 const {chromium}=require(process.env.NFE55_BROWSER),browser=await chromium.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
  const a=html.indexOf('        <div class="pdv-panel" style="margin-top:20px;" id="config-nfe55-numeracao">'),b=html.indexOf('          <h3>NFS-e</h3>',a);
  assert.ok(a>0&&b>a);await page.setContent('<input id="cf-nfce-serie" value="9"><input id="cf-nfce-ultimo-numero" value="900">'+html.slice(a,b));
  await page.evaluate(async url=>{
   window.state={empresa:'empresa-a',usuario:'usuario-a',calls:[],hold:false,serie:'1',numero:150};
   const client={auth:{getSession:async()=>({data:{session:{user:{id:window.state.usuario}}}}),onAuthStateChange:fn=>{window.authChanged=fn;return {data:{subscription:{unsubscribe(){}}}}}},rpc:async(name,args)=>{
    const st=window.state;st.calls.push({name,args,empresa:st.empresa});const serie=args.p_serie||st.serie;
    let numero=serie===st.serie?st.numero:0;
    if(name==='fiscal_nfe55_numeracao_salvar'){if(!args.p_confirmado)throw Error('Confirmação ausente');st.serie=serie;st.numero=numero=args.p_ultimo_numero;}
    const data={empresa_id:st.empresa,serie,ultimo_numero:numero,proximo_numero:numero+1,confirmada:name.endsWith('_salvar')};
    if(st.hold)return new Promise(resolve=>window.release=()=>resolve({data}));return {data};
   }};
   const {instalarConfiguracaoNfe55}=await import(url);window.controller=instalarConfiguracaoNfe55({document,supabase:client,obterEmpresaId:async()=>window.state.empresa,podeAcessar:()=>true});await window.controller.abrir();
  },moduleUrl);
  assert.equal(await page.locator('#cf-nfe-serie').inputValue(),'1');assert.equal(await page.locator('#cf-nfe-ultimo-numero').inputValue(),'150');
  await page.click('#cf-nfe-salvar');assert.match(await page.locator('#cf-nfe-msg').textContent(),/Confirme/);assert.equal(await page.evaluate(()=>window.state.calls.filter(c=>c.name.endsWith('_salvar')).length),0);
  await page.check('#cf-nfe-confirmado');await page.click('#cf-nfe-salvar');await page.waitForFunction(()=>document.getElementById('cf-nfe-msg').textContent.includes('Próxima NF-e da série 1: 151'));
  assert.equal(await page.locator('#cf-nfe-confirmado').isChecked(),false);assert.equal(await page.locator('#cf-nfce-serie').inputValue(),'9');assert.equal(await page.locator('#cf-nfce-ultimo-numero').inputValue(),'900');
  await page.fill('#cf-nfe-serie','12');await page.locator('#cf-nfe-serie').blur();await page.waitForFunction(()=>document.getElementById('cf-nfe-msg').textContent.includes('série 12: 1'));
  await page.fill('#cf-nfe-ultimo-numero','25');await page.check('#cf-nfe-confirmado');await page.click('#cf-nfe-salvar');await page.waitForFunction(()=>document.getElementById('cf-nfe-msg').textContent.includes('série 12: 26'));
  const calls=await page.evaluate(()=>window.state.calls);assert.ok(calls.every(c=>c.name.startsWith('fiscal_nfe55_numeracao_')));assert.deepEqual(calls.filter(c=>c.name.endsWith('_salvar')).map(c=>c.args.p_serie),['1','12']);
  // Requisição lenta: bloqueia edição e dois cliques não geram duas gravações.
  await page.check('#cf-nfe-confirmado');
  // Eventos no mesmo turno, antes de getSession resolver: apenas a primeira chamada pode prosseguir.
  await page.evaluate(()=>{window.state.hold=true;const button=document.getElementById('cf-nfe-salvar');button.dispatchEvent(new Event('click'));button.dispatchEvent(new Event('click'));button.dispatchEvent(new Event('click'));});
  await page.waitForFunction(()=>typeof window.release==='function');
  assert.equal(await page.locator('#cf-nfe-serie').isDisabled(),true);assert.equal(await page.locator('#cf-nfe-ultimo-numero').isDisabled(),true);
  assert.equal(await page.evaluate(()=>window.state.calls.filter(c=>c.name.endsWith('_salvar')).length),3);
  await page.evaluate(()=>{window.state.hold=false;window.release();delete window.release;});await page.waitForFunction(()=>!document.getElementById('cf-nfe-serie').disabled);
  await page.evaluate(()=>{window.state.hold=true;window.controller.abrir();});await page.waitForFunction(()=>typeof window.release==='function');
  await page.evaluate(()=>{window.state.empresa='empresa-b';window.state.usuario='usuario-b';window.authChanged('SIGNED_OUT');window.release();});
  await page.waitForTimeout(50);assert.equal(await page.locator('#cf-nfe-ultimo-numero').inputValue(),'');assert.equal(await page.locator('#cf-nfe-salvar').isDisabled(),true);assert.deepEqual(errors,[]);
 }finally{await browser.close();}
});

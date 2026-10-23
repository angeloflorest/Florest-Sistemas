"use strict";
const {chromium}=require(process.env.FLOREST_UI_PLAYWRIGHT||"playwright");
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path");
(async()=>{
 const browser=await chromium.launch({channel:"chrome",headless:true});
 const page=await browser.newPage();const errors=[];page.on("pageerror",e=>errors.push(e.message));
 const dir=path.resolve(__dirname,"../../florest-erp/sistema");
 await page.route("http://taxas.test/**",route=>{
  const file=new URL(route.request().url()).pathname.slice(1);
  if(["taxas-pagamento.js","taxas-core.js"].includes(file))return route.fulfill({contentType:"text/javascript",body:fs.readFileSync(path.join(dir,file),"utf8")});
  return route.fulfill({contentType:"text/html",body:'<div id="view-financeiro"><div class="fin-abas"></div></div><script type="module">import {instalarTaxasPagamento} from "/taxas-pagamento.js";window.calls=[];window.config={id:"12345678-1234-4234-8234-123456789abc",ativo:false,regras:[]};window.client={rpc:async(name,args)=>{window.calls.push({name,args});if(name==="taxas_pagamento_obter")return {data:window.config,error:null};if(name==="taxas_pagamento_salvar"){window.config={...window.config,ativo:args.p_ativo,regras:args.p_regras};return {data:window.config,error:null};}return {data:{ok:true},error:null};}};instalarTaxasPagamento(window.client);</script>'});
 });
 await page.goto("http://taxas.test/");
 await page.locator("#fin-formas-pagamento").click();
 await page.locator("#taxas-ativo").check();
 await page.locator('[data-rate="0"]').fill("1");
 await page.locator('[data-rate="1"]').fill("2");
 await page.locator('[data-rate="2"]').fill("0");
 await page.locator('[type="submit"]').click();
 await page.locator('[role="alert"]').filter({hasText:"Configuração salva"}).waitFor();
 assert.equal(await page.evaluate(()=>config.regras.length),3);
 await page.locator('[data-close]').click();
 for(const [name,key] of [["registrar_venda_mista","p_pagamentos"],["pdv_comanda_finalizar","p_pagamentos"],["bar_comanda_pagar","p_formas"],["bar_comanda_pagar_valor","p_formas"]]){
  await page.evaluate(({name,key})=>{window.result=null;window.client.rpc(name,{[key]:[{forma_pagamento:"Cartão de Débito",valor:100}]}).then(r=>window.result=r);},{name,key});
  await page.locator('[data-brand="0"]').waitFor();
  assert.equal(await page.locator("[data-brand]").count(),2);
  await page.keyboard.press("ArrowDown");await page.keyboard.press("Enter");
  await page.waitForFunction(()=>window.result!==null);
  assert.equal(await page.evaluate(({name,key})=>calls.filter(c=>c.name===name).at(-1).args[key][0].taxas.bandeira,{name,key}),"Mastercard");
 }
 const before=await page.evaluate(()=>calls.filter(c=>c.name==="registrar_venda_mista").length);
 await page.evaluate(()=>{window.result=null;client.rpc("registrar_venda_mista",{p_pagamentos:[{forma_pagamento:"Cartão de Débito",valor:100}]}).then(r=>window.result=r);});
 await page.locator('[data-brand="0"]').waitFor();await page.keyboard.press("Escape");
 await page.waitForFunction(()=>window.result!==null);
 assert.ok(await page.evaluate(()=>!!result.error));
 assert.equal(await page.evaluate(()=>calls.filter(c=>c.name==="registrar_venda_mista").length),before);
 await page.evaluate(async()=>{config.ativo=false;window.result=await client.rpc("registrar_venda_mista",{p_pagamentos:[{forma_pagamento:"Cartão de Débito",valor:100}]});});
 assert.equal(await page.locator("dialog").count(),0);
 assert.deepEqual(errors,[]);
 console.log("UI_ERP_TAXAS_OK: cadastro, regras por bandeira, PDV, comandas, Bar, cancelamento e desativação");
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1);});

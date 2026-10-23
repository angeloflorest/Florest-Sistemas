"use strict";
const {chromium}=require(process.env.FLOREST_UI_PLAYWRIGHT||"playwright");
const assert=require("node:assert/strict"),path=require("node:path"),fs=require("node:fs");
const {pathToFileURL}=require("node:url");
const {validarVenda}=require("../src/sale.cjs");
(async()=>{
 const browser=await chromium.launch({channel:"chrome",headless:true});
 const page=await browser.newPage({viewport:{width:1366,height:900}});
 const errors=[];page.on("pageerror",e=>errors.push(e.message));
 let saved=0;
 const state={context:{empresaId:"e",userId:"u",empresa:"Florest - Teste",operador:"Operador teste",papel:"proprietario",permitirSemEstoque:false},
 caixa:{aberto:true,pode_operar:true,caixa:{id:"cx",numero:1,valor_inicial:0},resumo:{}},
 online:false,lastSync:null,produtos:[
 {id:"p1",nome:"CERVEJA BRAHMA 600ML",codigo:"000002",gtin:"7891234567890",preco_venda:15,quantidade_estoque:100},
 {id:"p2",nome:"Brahma Duplo Malte",codigo:"000003",preco_venda:8,quantidade_estoque:100},
 {id:"p3",nome:"Abrahma",preco_venda:5,quantidade_estoque:100},
 {id:"p4",nome:"Brisa",preco_venda:4,quantidade_estoque:100}
 ],clientes:[],atalhos:[],pendencias:{},erros:[],draft:null};
 await page.exposeFunction("bridge",async(name,arg)=>{
  if(name==="state")return state;
  if(name==="draft"){state.draft=arg;return true;}
  if(name==="sale"){const dados=validarVenda(arg,state.produtos,{...state.context,caixaId:"cx"});saved++;state.draft=null;return{idLocal:"sale-"+saved,numeroLocal:saved,dados};}
  if(name==="print")return true;if(name==="history")return[];if(name==="sync")return state;
  throw new Error("Operação inesperada: "+name);
 });
 await page.addInitScript(()=>{
  window.florestDesktop={};
  for(const name of ["state","draft","sale","print","history","sync","login","cash","remote"])window.florestDesktop[name]=arg=>window.bridge(name,arg);
  window.florestDesktop.onChange=()=>{};
 });
 await page.goto(pathToFileURL(path.resolve(__dirname,"../src/renderer/index.html")).href);
 await page.locator("#view-pdv:not(.hidden)").waitFor();
 assert.equal(await page.locator('[data-forma="Outros"]').count(),0);
 await page.locator("#pdv-busca-produto").fill("br");
 assert.equal(await page.locator("[data-live-product]").count(),3);
 await page.locator("#pdv-busca-produto").fill("brahma");
 assert.equal(await page.locator("[data-live-product]").count(),2);
 await page.keyboard.press("ArrowDown");await page.keyboard.press("ArrowDown");
 await page.keyboard.press("Enter");
 await page.locator("#weight").waitFor();
 assert.ok((await page.locator("#modal-body").innerText()).includes("CERVEJA BRAHMA 600ML"));
 await page.locator("#weight").fill("2");await page.keyboard.press("Enter");
 assert.equal(await page.locator("#pdv-carrinho .cart-row").count(),1);
 assert.ok((await page.locator("#pdv-total").innerText()).includes("30,00"));
 assert.equal(await page.evaluate(()=>document.activeElement.id),"pdv-valor-forma");
 for(const [key,label]of [["F4","Dinheiro"],["F6","Pix"],["F7","Cartão de Débito"],["F8","Cartão de Crédito"]]){
  await page.keyboard.press(key);
  assert.ok((await page.locator("#pdx-pag-lista").innerText()).includes(label));
  assert.equal(saved,0);
  await page.locator('[data-pay-remove="0"]').click();
 }
 await page.keyboard.press("F8");await page.keyboard.press("F3");
 await page.locator("#receipt-cancel").waitFor();assert.equal(saved,1);await page.locator("#receipt-cancel").click();
 await page.keyboard.press("F9");await page.locator("#product-query").fill("bráhma");
 assert.equal(await page.locator("[data-product]").count(),2);
 await page.keyboard.press("ArrowDown");await page.keyboard.press("Enter");
 await page.locator("#weight").fill("3");await page.keyboard.press("Enter");
 assert.ok((await page.locator("#pdv-total").innerText()).includes("24,00"));
 await page.keyboard.press("F6");await page.keyboard.press("F3");
 await page.locator("#receipt-cancel").click();assert.equal(saved,2);
 await page.locator("#pdv-busca-produto").fill("7891234567890");await page.keyboard.press("Enter");
 assert.equal(await page.locator("#pdv-carrinho .cart-row").count(),1);
 assert.equal(await page.locator("#modal:not(.hidden)").count(),0);
 await page.locator("#pdv-busca-produto").fill("br");await page.keyboard.press("Escape");
 assert.equal(await page.locator("#pdv-resultados:not(.hidden)").count(),0);
 assert.equal(await page.locator("#pdv-carrinho .cart-row").count(),1);
 await page.keyboard.press("F1");await page.locator("#modal-title").filter({hasText:"Manual"}).waitFor();
 assert.ok((await page.locator("#modal-body").innerText()).includes("F4"));
 assert.ok(!(await page.locator("#modal-body").innerText()).includes("Outras formas"));
 await page.keyboard.press("Escape");
 await page.setViewportSize({width:1024,height:720});
 await page.locator("#pdv-busca-produto").fill("br");await page.keyboard.press("ArrowDown");
 assert.equal(await page.locator("#pdv-resultados .is-active").count(),1);
 fs.mkdirSync(path.resolve(__dirname,"../dist"),{recursive:true});
 await page.screenshot({path:path.resolve(__dirname,"../dist/pdv-busca-teclado.png")});
 assert.deepEqual(errors,[]);
 console.log("UI_KEYBOARD_OK: busca em tempo real, prefixos, setas, quantidade, foco, F4/F6/F7/F8, F3, F9, F1 e leitura de barras");
 await page.goto(pathToFileURL(path.resolve(__dirname,"../dist/Manual-Florest-PDV.html")).href);
 assert.equal(await page.locator("tbody tr").count(),12);
 const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>window.innerWidth);
 assert.equal(overflow,false);
 await browser.close();
})().catch(error=>{console.error(error);process.exit(1);});

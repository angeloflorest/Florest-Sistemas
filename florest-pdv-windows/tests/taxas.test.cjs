"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const T=require("../src/renderer/taxas-core.js"),{validarVenda}=require("../src/sale.cjs");
const id="12345678-1234-4234-8234-123456789abc";
const config={id,ativo:true,regras:[{forma:"Cartão de Débito",bandeira:"Visa",percentual:0},{forma:"Pix",bandeira:null,percentual:2}]};
test("somente as seis bandeiras autorizadas",()=>assert.deepEqual([...T.bandeiras],["Visa","Mastercard","Elo","American Express","Hipercard","Diners"]));
test("desativado, Pix, dinheiro e forma sem taxa não pedem bandeira",async()=>{
 let calls=0;const ask=()=>{calls++;return "Visa";};
 for(const [cfg,forma] of [[{...config,ativo:false},"Cartão de Débito"],[config,"Pix"],[config,"Dinheiro"],[config,"Cartão de Crédito"]]){
  assert.equal((await T.preparar(cfg,forma,ask)).bandeira,null);
 }
 assert.equal(calls,0);
});
test("taxa zero cadastrada pede bandeira e guarda versão",async()=>{
 const meta=await T.preparar(config,"Cartão de Débito",async b=>{assert.deepEqual(b,["Visa"]);return "Visa";});
 assert.deepEqual(meta,{config_id:id,bandeira:"Visa"});
 await assert.rejects(T.preparar(config,"Cartão de Débito",async()=>"Discover"),/bandeira/);
});
test("fila offline preserva snapshot sem aceitar percentual do renderer",()=>{
 const input={itens:[{produto_id:"p",quantidade:1}],pagamentos:[{forma_pagamento:"Cartão de Débito",valor:100,taxas:{config_id:id,bandeira:"Visa",percentual:99}}]};
 const dados=validarVenda(input,[{id:"p",nome:"Produto",preco_venda:100,quantidade_estoque:5}],{caixaId:"cx"});
 assert.equal(dados.total,100);
 assert.deepEqual(JSON.parse(JSON.stringify(dados)).pagamentos[0].taxas,{config_id:id,bandeira:"Visa"});
 input.pagamentos[0].taxas.bandeira="JCB";
 assert.throws(()=>validarVenda(input,[{id:"p",preco_venda:100,quantidade_estoque:5}],{caixaId:"cx"}),/Bandeira/);
});
test("Financeiro mostra uma despesa consolidada no período",()=>{
 const lista=T.agruparDespesas([{id:"a",valor:0.1,taxas_automaticas:true},{id:"b",valor:0.2,taxas_automaticas:true},{id:"c",valor:12}]);
 assert.equal(lista.length,2);assert.equal(lista[1].valor,0.3);assert.equal(lista[1].id,null);
 assert.equal(lista[1].descricao,"Despesa administrativa de cartões");assert.equal(lista[0].id,"c");
});
test("web e executável compartilham a mesma regra",()=>{
 const fs=require("node:fs"),path=require("node:path");
 assert.equal(fs.readFileSync(path.join(__dirname,"../../florest-erp/sistema/taxas-core.js"),"utf8"),fs.readFileSync(path.join(__dirname,"../src/renderer/taxas-core.js"),"utf8"));
});
test("sintaxe dos módulos web e script do ERP",()=>{
 const fs=require("node:fs"),path=require("node:path"),{spawnSync}=require("node:child_process");
 const dir=path.join(__dirname,"../../florest-erp/sistema");
 const html=fs.readFileSync(path.join(dir,"index.html"),"utf8");
 for(const source of [fs.readFileSync(path.join(dir,"taxas-pagamento.js"),"utf8"),...Array.from(html.matchAll(/<script[^>]*type="module"[^>]*>([\s\S]*?)<\/script>/g),m=>m[1])]){
 const result=spawnSync(process.execPath,["--input-type=module","--check"],{input:source,encoding:"utf8"});
 assert.equal(result.status,0,result.stderr);
 }
});

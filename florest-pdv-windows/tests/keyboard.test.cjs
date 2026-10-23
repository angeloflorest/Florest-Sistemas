"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const K=require("../src/renderer/keyboard.js");
const products=[
  {id:"1",nome:"CERVEJA BRAHMA 600ML",codigo:"000002",gtin:"7891111111111"},
  {id:"2",nome:"Brahma Duplo Malte",codigo:"000003"},
  {id:"3",nome:"Abrahma",codigo:"000004"},
  {id:"4",nome:"Brisa"},
  {id:"5",nome:"Água mineral",codigo:"000005"}
];
test("busca por prefixo do nome ou palavra, sem exigir Enter",()=>{
  assert.deepEqual(K.filterProducts(products,"br").map(p=>p.id),["2","4","1"]);
  assert.deepEqual(K.filterProducts(products,"brahma 60").map(p=>p.id),["1"]);
  assert.deepEqual(K.filterProducts(products,"BRAH").map(p=>p.id),["2","1"]);
});
test("busca ignora acentos e aceita prefixo de código e GTIN",()=>{
  assert.equal(K.filterProducts(products,"agua")[0].id,"5");
  assert.equal(K.filterProducts(products,"000002")[0].id,"1");
  assert.equal(K.filterProducts(products,"789111")[0].id,"1");
});
test("todos os produtos que correspondem ao prefixo são retornados",()=>{
  const all=Array.from({length:140},(_,n)=>({id:String(n),nome:"Brahma "+n}));
  assert.equal(K.filterProducts(all,"br").length,140);
});
test("setas iniciam, avançam, voltam e circulam sem ultrapassar a lista",()=>{
  assert.equal(K.nextIndex(-1,1,3),0);assert.equal(K.nextIndex(-1,-1,3),2);
  assert.equal(K.nextIndex(2,1,3),0);assert.equal(K.nextIndex(0,-1,3),2);
  assert.equal(K.nextIndex(0,1,0),-1);
});
test("pagamentos usam apenas teclas livres e Outros foi removido",()=>{
  const payment=K.shortcuts.filter(s=>s.action==="payment");
  assert.deepEqual(payment.map(s=>[s.key,s.forma]),[
    ["F4","Dinheiro"],["F6","Pix"],["F7","Cartão de Débito"],["F8","Cartão de Crédito"]
  ]);
  assert.equal(new Set(K.shortcuts.map(s=>s.key)).size,K.shortcuts.length);
  assert.equal(K.shortcuts.find(s=>s.key==="F2").action,"client");
  assert.equal(K.shortcuts.find(s=>s.key==="F3").action,"finish");
  assert.equal(K.shortcuts.find(s=>s.key==="F5").action,"discount");
  assert.equal(K.shortcuts.find(s=>s.key==="F9").action,"search");
  assert.equal(K.shortcuts.some(s=>s.key==="F10"||s.forma==="Outros"),false);
});
test("manual usa o mesmo cadastro de atalhos da aplicação",()=>{
  const html=K.manualBody();
  for(const shortcut of K.shortcuts){assert.ok(html.includes(shortcut.key));assert.ok(html.includes(shortcut.label));}
  assert.ok(!html.includes("Outras formas"));assert.ok(html.includes("Não finaliza"));
});

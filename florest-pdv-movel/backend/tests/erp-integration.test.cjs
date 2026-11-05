const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../../../florest-erp/sistema/index.html'),'utf8');
function part(start,end){const i=html.indexOf(start),j=html.indexOf(end,i);assert.ok(i>=0&&j>i);return html.slice(i,j);}
test('relatórios identificam celular sem mudar o rótulo do PDV Principal',()=>{const c=vm.createContext({});vm.runInContext(part('function pdvMovelRotuloVenda(', '// ---------- Financeiro'),c);assert.equal(c.pdvMovelRotuloVenda({}),'PDV Principal');assert.equal(c.pdvMovelRotuloVenda({pdv_movel_caixa_id:'id',pdv_movel_caixas:{numero:2,aberto_por_nome:'Ana'}}),'PDV Móvel · Caixa 2 · Ana');});
test('consolidado inclui pagamentos móveis separados uma vez e preserva o fluxo de outros módulos',async()=>{
 const rows=[{id:'principal',forma_pagamento:'Dinheiro',total:10},{id:'movel',pdv_movel_caixa_id:'cash',forma_pagamento:'dividido',total:20},{id:'bar',tipo:'bar',forma_pagamento:'dividido',total:15}];
 const c=vm.createContext({buscarVendasPeriodoRelatorio:async()=>rows,escapeHtml:String,formatarReais:String,supabase:{from(table){return {table,select(){return this;},in(){return this;},order(){return this;}};}},buscarTodos:async build=>({data:build().table==='vendas_pagamentos'?[{venda_id:'movel',forma_pagamento:'Pix',valor:5},{venda_id:'movel',forma_pagamento:'Pix',valor:7},{venda_id:'movel',forma_pagamento:'Crédito',valor:8}]:[{forma_pagamento:'Pix',valor:5},{forma_pagamento:'Crédito',valor:10}]})});
 vm.runInContext(part('async function relatorioVendasFormaPagamento(', 'async function relatorioVendasOrigem('),c);
 const result=await c.relatorioVendasFormaPagamento({});assert.equal(result.totalizadores[2],'45');
 const pix=result.linhas.find(x=>x[0]==='Pix');assert.equal(pix[1],1);assert.equal(pix[2],'17');assert.equal(result.linhas.some(x=>x[0]==='dividido'),false);
});
test('relatório de produtos móvel lê itens canônicos e filtra caixa móvel sem escrever dados',async()=>{
 let table,filters=[];const q={select(){return this},gte(){return this},lte(){return this},is(...args){filters.push(args);return this},not(...args){filters.push(args);return this},order(){return this}};
 const c=vm.createContext({Date,Map,escapeHtml:String,formatarQuantidade:String,formatarReais:String,supabase:{from(t){table=t;return q;}},buscarTodos:async build=>{build();return {data:[{produto_id:'p',quantidade:2,subtotal:24,produtos:{nome:'Produto'},vendas:{pdv_movel_caixa_id:'c',pdv_movel_caixas:{numero:3,aberto_por_nome:'Ana'}}}]}}});
 vm.runInContext(part('async function relatorioProdutosPdvMovel(', 'async function relatorioProdutosCadastrados('),c);
 const r=await c.relatorioProdutosPdvMovel({dataInicio:'2026-11-01',dataFim:'2026-11-05'});assert.equal(table,'itens_venda');assert.ok(filters.some(x=>x[0]==='vendas.pdv_movel_caixa_id'&&x[1]==='is'&&x[2]===null));assert.equal(r.linhas[0][1],'PDV Móvel');assert.equal(r.linhas[0][5],'24');
});

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./helpers.cjs');
const c = load('commerce');
const d = load('domain');
const profile = { id:'u', empresa_id:'a', nome:'Operador', papel:'proprietario', permissoes:[], ativo:true, empresas:{nome:'Loja',bloqueado:false,status_conta:'ativo'} };
test('consumidor padrão não cria cadastro nem inventa id', () => { assert.equal(c.DEFAULT_CUSTOMER.id,''); assert.equal(c.DEFAULT_CUSTOMER.nome,'Consumidor Padrão'); });
test('ajustes unitários usam centavos e arredondamento por item compatível com o servidor', () => {
 const item = { product:{preco_venda:12.99}, quantity:0.125, discountCents:99, surchargeCents:100 };
 assert.equal(c.adjustedUnitCents(item),1300);assert.equal(c.adjustedItemCents(item),163);
 assert.equal(c.draftTotal([item,item]),326);
 assert.equal(c.parseCents('12,05'),1205); assert.equal(c.parseCents('0'),0);
 for (const value of ['-1','1.001','1e3','','NaN']) assert.throws(() => c.parseCents(value));
 assert.throws(() => c.adjustedItemCents({...item,discountCents:1300}));
 assert.throws(() => c.adjustedItemCents({...item,quantity:Infinity}));
});
test('pagamentos da mesma forma permanecem separados, com limite e restante exatos', () => {
 let p=c.addPayment([],'Pix',200,1000,1);p=c.addPayment(p,'Pix',300,1000,2);p=c.addPayment(p,'Dinheiro',500,1000,3);
 assert.equal(p.length,3);assert.equal(p.reduce((s,x)=>s+x.cents,0),1000);
 assert.equal(p[0].cents,200);assert.equal(p[1].cents,300);
 assert.throws(() => c.addPayment(p,'Pix',1,1000,4));
 assert.throws(() => c.addPayment([],'Outra',10,100,1));
 assert.throws(() => c.addPayment(Array(10).fill({cents:1}),'Pix',1,1000,11));
});
test('prazo exige cadastro real e não se mistura com recebimentos', () => {
 assert.throws(() => c.validateCredit(c.DEFAULT_CUSTOMER,[],100));
 assert.throws(() => c.validateCredit({id:'cliente'},[{cents:1}],100));
 assert.doesNotThrow(() => c.validateCredit({id:'cliente'},[],100));
});
test('histórico respeita acesso financeiro e dia de São Paulo, com datas inclusivas', () => {
 assert.equal(c.canReadHistory(profile),true);assert.equal(c.canReadHistory({...profile,papel:'funcionario',permissoes:['pdv']}),false);
 assert.equal(c.canReadHistory({...profile,papel:'funcionario',permissoes:['financeiro']}),true);
 const rows=[{id:'1',numero_venda:10,criado_em:'2026-11-06T01:30:00Z',cliente_nome:'Ana',caixa_numero:2,operador_nome:'João'}, {id:'2',numero_venda:11,criado_em:'2026-11-06T04:00:00Z',cliente_nome:'Bia'}];
 const filters={start:'2026-11-05',end:'2026-11-05',number:'10',customer:'ana',cash:'2',operator:'joão'};
 assert.equal(c.filterSales(rows,filters).length,1);
 assert.throws(() => c.validateFilters({...filters,start:'2026-02-30'}));
 assert.throws(() => c.validateFilters({...filters,start:'2026-11-07'}));
});

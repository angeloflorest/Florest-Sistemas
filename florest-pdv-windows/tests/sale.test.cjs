"use strict";
const test = require("node:test"),
  assert = require("node:assert/strict");
const { validarVenda } = require("../src/sale.cjs");
const produtos = [
  {
    id: "p",
    nome: "Granel",
    preco_venda: 10,
    quantidade_estoque: 2,
    venda_granel: true,
  },
];
const contexto = { caixaId: "cx", userId: "u", permitirSemEstoque: false };
const input = () => ({
  itens: [{ produto_id: "p", quantidade: 0.5 }],
  pagamentos: [{ forma_pagamento: "Pix", valor: 5 }],
});
test("0,500 a R$10 gera R$5 e ignora preço forjado pelo renderer", () => {
  const d = input();
  d.itens[0].preco_unitario = 0.01;
  assert.equal(validarVenda(d, produtos, contexto).total, 5);
});
test("pagamento misto e desconto seguem arredondamento do PDV original", () => {
  const d = input();
  d.desconto = 1;
  d.pagamentos = [
    { forma_pagamento: "Pix", valor: 1.5 },
    { forma_pagamento: "Dinheiro", valor: 2.5 },
  ];
  assert.equal(validarVenda(d, produtos, contexto).total, 4);
});
test("rejeita estoque insuficiente, caixa fechado, CPF incorreto e pagamento incompleto", () => {
  const d = input();
  d.itens[0].quantidade = 3;
  assert.throws(() => validarVenda(d, produtos, contexto), /Estoque/);
  assert.throws(() => validarVenda(input(), produtos, {}), /caixa/);
  const c = input();
  c.cpf = "11111111111";
  assert.throws(() => validarVenda(c, produtos, contexto), /CPF/);
  const p = input();
  p.pagamentos[0].valor = 1;
  assert.throws(() => validarVenda(p, produtos, contexto), /Pagamentos/);
});
test("Nota a Prazo exige cliente cadastrado e nenhum pagamento", () => {
  const d = input();
  d.prazo = true;
  d.pagamentos = [];
  assert.throws(() => validarVenda(d, produtos, contexto), /cliente/);
  d.clienteId = "c";
  assert.equal(validarVenda(d, produtos, contexto).prazo, true);
});

test('dinheiro preserva recebido e troco sem enviar excedente como faturamento',()=>{
 const d=input();d.pagamentos=[{forma_pagamento:'Dinheiro',valor:5,recebido:20}];
 const sale=validarVenda(d,produtos,contexto);assert.equal(sale.total,5);assert.equal(sale.pagamentos[0].recebido,20);assert.equal(sale.pagamentos[0].troco,15);
 d.pagamentos[0].forma_pagamento='Pix';assert.throws(()=>validarVenda(d,produtos,contexto),/recebido/);
});

"use strict";
const formas = new Set([
  "Dinheiro",
  "Pix",
  "Cartão de Débito",
  "Cartão de Crédito",
  "Outros",
]);
const cents = (v) => Math.round(Number(v) * 100);
function validarVenda(input, produtos, contexto) {
  if (
    !input ||
    !Array.isArray(input.itens) ||
    !input.itens.length ||
    input.itens.length > 500
  )
    throw new Error("Adicione produtos ao cupom.");
  if (!contexto.caixaId) throw new Error("Abra o caixa antes de vender.");
  const vistos = new Set();
  const itens = input.itens.map((i) => {
    const p = produtos.find((p) => p.id === i.produto_id);
    if (!p || vistos.has(p.id))
      throw new Error("Produto inválido ou repetido.");
    vistos.add(p.id);
    const quantidade = Number(i.quantidade);
    if (
      !Number.isFinite(quantidade) ||
      quantidade <= 0 ||
      quantidade > 999999 ||
      Math.abs(quantidade * 1000 - Math.round(quantidade * 1000)) > 1e-6
    )
      throw new Error("Quantidade inválida (até 3 casas).");
    if (
      !contexto.permitirSemEstoque &&
      p.tipo_fiscal !== "servico" &&
      quantidade > Number(p.quantidade_estoque) + 1e-9
    )
      throw new Error(`Estoque insuficiente: ${p.nome}`);
    const preco = Number(p.preco_venda);
    if (!Number.isFinite(preco) || preco < 0)
      throw new Error("Preço inválido.");
    return {
      produto_id: p.id,
      nome: p.nome,
      quantidade,
      preco_unitario: cents(preco) / 100,
    };
  });
  const subtotal = itens.reduce(
    (s, i) =>
      s +
      Math.floor(
        (Math.round(i.quantidade * 10000) * cents(i.preco_unitario) + 5000) /
          10000,
      ),
    0,
  );
  const desconto = cents(input.desconto || 0);
  if (!Number.isSafeInteger(desconto) || desconto < 0 || desconto >= subtotal)
    throw new Error("Desconto inválido.");
  const fator = (subtotal - desconto) / subtotal;
  const ajustados = itens.map((i) => ({
    ...i,
    preco_unitario: Math.round(i.preco_unitario * fator * 100) / 100,
  }));
  const totalCentavos = ajustados.reduce(
    (s, i) =>
      s +
      Math.floor(
        (Math.round(i.quantidade * 10000) * cents(i.preco_unitario) + 5000) /
          10000,
      ),
    0,
  );
  const prazo = input.prazo === true;
  const pagamentos = input.pagamentos || [];
  if (prazo && (!input.clienteId || pagamentos.length))
    throw new Error("Nota a Prazo exige cliente e nenhum pagamento.");
  if (
    !prazo &&
    (!Array.isArray(pagamentos) || !pagamentos.length || pagamentos.length > 10)
  )
    throw new Error("Informe até 10 pagamentos.");
  let recebido = 0;
  const normalizados = pagamentos.map((p) => {
    const valor = cents(p.valor);
    if (
      !formas.has(p.forma_pagamento) ||
      !Number.isSafeInteger(valor) ||
      valor <= 0
    )
      throw new Error("Pagamento inválido.");
    recebido += valor;
    const normalizado={ forma_pagamento: p.forma_pagamento, valor: valor / 100 };
    if(p.taxas!=null){
      const config_id=p.taxas.config_id??null,bandeira=p.taxas.bandeira??null;
      if(config_id!==null&&!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(config_id))
        throw new Error("Configuração de taxas inválida.");
      if(bandeira!==null&&!require("./renderer/taxas-core.js").bandeiras.includes(bandeira))
        throw new Error("Bandeira inválida.");
      normalizado.taxas={config_id,bandeira};
    }
    return normalizado;
  });
  if (!prazo && recebido !== totalCentavos)
    throw new Error("Pagamentos devem ser iguais ao total.");
  const cpf = String(input.cpf || "").replace(/\D/g, "");
  if (cpf && !cpfValido(cpf)) throw new Error("CPF inválido.");
  return {
    itens: ajustados,
    pagamentos: normalizados,
    clienteId: input.clienteId || null,
    cpf: cpf || null,
    prazo,
    total: totalCentavos / 100,
    subtotal: subtotal / 100,
    desconto: desconto / 100,
    caixaId: contexto.caixaId,
    userId: contexto.userId,
  };
}
function cpfValido(c) {
  if (!/^\d{11}$/.test(c) || /^(\d)\1+$/.test(c)) return false;
  for (let t = 9; t <= 10; t++) {
    let s = 0;
    for (let i = 0; i < t; i++) s += Number(c[i]) * (t + 1 - i);
    let d = (s * 10) % 11;
    if (d === 10) d = 0;
    if (d !== Number(c[t])) return false;
  }
  return true;
}
module.exports = { validarVenda, cpfValido };

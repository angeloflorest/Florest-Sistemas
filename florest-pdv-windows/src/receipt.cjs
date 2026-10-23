"use strict";
const esc = (v) =>
  String(v ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const brl = (n) =>
  Number(n).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
function receiptHtml(context, row) {
  const d = JSON.parse(row.dados_json);
  return `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>Comprovante</title><style>@page{margin:3mm;size:80mm auto}body{font:11px monospace;color:#000;width:70mm;margin:0 auto}h1{font-size:15px;margin:4px 0}h2{font-size:12px}p{margin:4px 0}table{width:100%;border-collapse:collapse}td{padding:3px 0;vertical-align:top}td:last-child{text-align:right}hr{border:0;border-top:1px dashed #000}.center{text-align:center}.id{overflow-wrap:anywhere;font-size:9px}</style></head><body><div class="center"><h1>${esc(context.empresa)}</h1><p>${esc(context.cnpj || "")}</p><h2>COMPROVANTE NÃO FISCAL</h2><p>Pedido local nº ${esc(row.numero_local)}</p><p>${esc(new Date(row.criada_em.replace(" ", "T") + "Z").toLocaleString("pt-BR"))}</p></div><hr><table>${d.itens.map((i) => `<tr><td>${esc(i.nome)}<br>${esc(i.quantidade)} × ${brl(i.preco_unitario)}</td><td>${brl(Math.floor((Math.round(i.quantidade * 10000) * Math.round(i.preco_unitario * 100) + 5000) / 10000) / 100)}</td></tr>`).join("")}</table><hr><p><b>TOTAL: ${brl(d.total)}</b></p>${d.prazo ? "<p>NOTA A PRAZO — pagamento pendente</p>" : d.pagamentos.map((p) => `<p>${esc(p.forma_pagamento)}: ${brl(p.valor)}</p>`).join("")}<hr><p>Operador: ${esc(context.operador)}</p><p class="id">Identificador: ${esc(row.id_local)}</p><p class="center">Não é documento fiscal.<br>Obrigado pela preferência!</p></body></html>`;
}
module.exports = { receiptHtml };

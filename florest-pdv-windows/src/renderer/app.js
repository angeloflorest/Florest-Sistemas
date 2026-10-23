"use strict";
const api = window.florestDesktop,
  $ = (id) => document.getElementById(id);
const Keyboard = window.FlorestKeyboard;
const brl = (v) =>
  Number(v).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const esc = (v) =>
  String(v ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const parse = (v) => {
  let t = String(v ?? "")
    .trim()
    .replace(/R\$|\s/g, "");
  if (t.includes(",")) t = t.replace(/\./g, "").replace(",", ".");
  return /^\d+(\.\d+)?$/.test(t) ? Number(t) : NaN;
};
let state = null,
  cart = [],
  payments = [],
  clienteId = null,
  prazo = false,
  selected = null,
  operacao = crypto.randomUUID(),
  busy = false,
  draftTimer = null,
  restoring = false,
  modalOpen = false,
  lastReceipt = null;
function error(e) {
  $("pdv-msg").textContent = e.message || String(e);
  $("pdv-msg").style.color = "#b42318";
}
function modal(title, html) {
  hideLiveResults();
  $("modal-body").onclick = null;
  $("modal-title").textContent = title;
  $("modal-body").innerHTML = html;
  $("modal-error").textContent = "";
  $("modal").classList.remove("hidden");
  modalOpen = true;
}
function closeModal() {
  $("modal").classList.add("hidden");
  modalOpen = false;
  $("pdv-busca-produto").focus();
}
$("close-modal").onclick = closeModal;
function action(fn) {
  return async (...args) => {
    try {
      await fn(...args);
    } catch (e) {
      if (modalOpen) $("modal-error").textContent = e.message;
      else error(e);
    }
  };
}
function totals() {
  let sub = 0;
  for (const i of cart)
    sub += Math.floor(
      (Math.round(i.quantidade * 10000) * Math.round(i.preco_unitario * 100) +
        5000) /
        10000,
    );
  const d = Math.min(
    Math.round((Number($("pdv-desconto").value) || 0) * 100),
    sub,
  );
  const f = sub ? (sub - d) / sub : 1;
  const total = cart.reduce(
    (s, i) =>
      s +
      Math.floor(
        (Math.round(i.quantidade * 10000) *
          Math.round(i.preco_unitario * f * 100) +
          5000) /
          10000,
      ),
    0,
  );
  return {
    sub,
    total,
    discount: d,
    paid: payments.reduce((s, p) => s + Math.round(p.valor * 100), 0),
  };
}
function draft() {
  return {
    cart,
    payments,
    clienteId,
    prazo,
    desconto: $("pdv-desconto").value,
    cpf: $("pdv-cpf-nota").value,
    operacao,
  };
}
function saveDraft() {
  if (restoring || busy || !state?.context) return;
  clearTimeout(draftTimer);
  draftTimer = setTimeout(() => api.draft(draft()).catch(error), 150);
}
function render() {
  const t = totals();
  $("pdv-carrinho").innerHTML = cart.length
    ? cart
        .map(
          (i, n) =>
            `<div class="cart-row"><b>${esc(i.nome)}</b><span>${i.quantidade.toLocaleString("pt-BR")}</span><span>${brl(i.preco_unitario)}</span><b>${brl(Math.floor((Math.round(i.quantidade * 10000) * Math.round(i.preco_unitario * 100) + 5000) / 10000) / 100)}</b><button data-remove="${n}" title="Remover item">×</button></div>`,
        )
        .join("")
    : '<div class="cart-empty">Nenhum item no cupom ainda.</div>';
  $("pdx-itens").textContent = cart.length + " itens";
  $("pdv-subtotal").textContent = brl(t.sub / 100);
  $("pdv-total").textContent = brl(t.total / 100);
  $("pdx-fin-total").textContent = brl(t.total / 100);
  $("pdx-pag-restante").textContent = brl((prazo ? 0 : t.total - t.paid) / 100);
  $("pdv-valor-forma").disabled = !cart.length || prazo;
  if (document.activeElement !== $("pdv-valor-forma"))
    $("pdv-valor-forma").value = ((t.total - t.paid) / 100)
      .toFixed(2)
      .replace(".", ",");
  $("pdx-pag-lista").innerHTML = payments
    .map(
      (p, n) =>
        `<div class="pay-row"><span>${esc(p.forma_pagamento)} · ${brl(p.valor)}</span><button data-pay-remove="${n}">×</button></div>`,
    )
    .join("");
  $("btn-finalizar-venda").disabled =
    busy ||
    !cart.length ||
    t.total <= 0 ||
    (!prazo && t.total !== t.paid) ||
    !state?.caixa?.aberto ||
    !state?.caixa?.pode_operar ||
    !!state?.blocked;
  $("pdv-nota-prazo").setAttribute("aria-pressed", String(prazo));
  $("pdv-nota-prazo").style.background = prazo ? "#f8c820" : "";
  const cliente = state?.clientes.find((c) => c.id === clienteId);
  $("pdx-cliente-nome").textContent = cliente?.nome || "Consumidor Final";
  saveDraft();
}
function applyState(next, initial = false) {
  state = next;
  $("login").classList.toggle("hidden", !!state.context);
  $("view-pdv").classList.toggle("hidden", !state.context);
  if (!state.context) return;
  $("pdx-empresa").textContent = state.context.empresa;
  $("pdx-operador").textContent = state.context.operador;
  $("pdx-caixa-status").textContent = state.caixa?.aberto
    ? "Aberto nº " + state.caixa.caixa.numero
    : "Fechado";
  $("pdx-caixa-faixa").classList.remove("hidden");
  $("pdx-caixa-faixa-txt").textContent = state.caixa?.aberto
    ? "Caixa aberto · " + brl(state.caixa.caixa.valor_inicial) + " inicial"
    : "Abra o Caixa PDV para iniciar as vendas.";
  $("btn-pdx-caixa-abrir").classList.toggle("hidden", !!state.caixa?.aberto);
  $("btn-pdx-caixa-gerenciar").classList.toggle("hidden", !state.caixa?.aberto);
  const pending =
    (state.pendencias.pendente || 0) +
    (state.pendencias.erro || 0) +
    (state.pendencias.enviando || 0);
  $("sync-status").textContent =
    (state.online ? "Conectado" : "Sem conexão") +
    " · " +
    pending +
    " venda(s) pendente(s)" +
    (state.erros.length ? " · Confira as pendências" : "");
  $("pdx-atalhos-lista").innerHTML = state.atalhos
    .map((a, n) => `<button data-shortcut="${n}">${esc(a.nome)}</button>`)
    .join("");
  $("btn-pdx-config-atalhos").hidden = state.context.papel !== "proprietario";
  if (initial && state.draft) {
    restoring = true;
    ({
      cart = [],
      payments = [],
      clienteId = null,
      prazo = false,
      operacao = crypto.randomUUID(),
    } = state.draft);
    $("pdv-desconto").value = state.draft.desconto || 0;
    $("pdv-cpf-nota").value = state.draft.cpf || "";
    restoring = false;
  }
  if (state.blocked) error(new Error(state.blocked));
  render();
}
function clearSale() {
  clearTimeout(draftTimer);
  cart = [];
  payments = [];
  clienteId = null;
  prazo = false;
  selected = null;
  operacao = crypto.randomUUID();
  $("pdv-desconto").value = 0;
  $("pdv-cpf-nota").value = "";
  $("pdv-msg").textContent = "";
  $("pdv-busca-produto").value = "";
  $("pdv-preview-nome").textContent = "—";
  $("pdv-preview-sub").textContent = "Bipe um produto ou pesquise pelo nome.";
  $("pdv-preview-preco").textContent = "—";
  render();
}
function choose(p) {
  selected = p;
  $("pdv-preview-nome").textContent = p.nome;
  $("pdv-preview-sub").textContent =
    (p.gtin || p.codigo || "") +
    " · Estoque: " +
    Number(p.quantidade_estoque).toLocaleString("pt-BR");
  $("pdv-preview-preco").textContent =
    brl(p.preco_venda) +
    (p.venda_granel ? " / " + (p.unidade_comercial || "KG") : "");
}
function add(p, q = 1) {
  hideLiveResults();
  if (!state.caixa?.aberto) throw new Error("Abra o caixa antes de vender.");
  if (
    !Number.isFinite(q) ||
    q <= 0 ||
    q > 999999 ||
    Math.abs(q * 1000 - Math.round(q * 1000)) > 1e-6
  )
    throw new Error("Quantidade inválida, use até 3 casas decimais.");
  if (payments.length)
    throw new Error("Remova os pagamentos antes de alterar os itens.");
  const old = cart.find((i) => i.produto_id === p.id),
    quantity = Math.round(((old?.quantidade || 0) + q) * 1000) / 1000;
  if (
    !state.context.permitirSemEstoque &&
    p.tipo_fiscal !== "servico" &&
    quantity > p.quantidade_estoque + 1e-9
  )
    throw new Error("Estoque insuficiente: " + p.nome);
  if (old) old.quantidade = quantity;
  else
    cart.push({
      produto_id: p.id,
      nome: p.nome,
      quantidade: q,
      preco_unitario: Number(p.preco_venda),
    });
  choose(p);
  $("pdv-busca-produto").value = "";
  $("pdv-qtd").value = "1";
  $("pdv-msg").textContent = "";
  render();
  $("pdv-busca-produto").focus();
}

function focusPayment() {
  const field = $("pdv-valor-forma");
  if (!field.disabled) { field.focus(); field.select(); }
}
function askQuantity(p, q = 1) {
  choose(p);
  modal(
    p.venda_granel ? "Quantidade / peso" : "Quantidade",
    `<p><b>${esc(p.nome)}</b> · ${brl(p.preco_venda)}${p.venda_granel ? " / " + esc(p.unidade_comercial || "KG") : " por unidade"}</p><label for="weight">Quantidade</label><input id="weight" inputmode="decimal" value="${Number.isFinite(q) && q > 0 ? q : 1}" autocomplete="off"><button id="weight-add" class="primary">Adicionar ao cupom</button>`
  );
  $("weight-add").onclick = action(() => {
    add(p, parse($("weight").value));
    closeModal();
    focusPayment();
  });
  $("weight").focus();
  $("weight").select();
  $("weight").onkeydown = (e) => {
    if (e.key !== "Enter") return;
    e.preventDefault();
    e.stopPropagation();
    if (!e.repeat) $("weight-add").click();
  };
}
function addOrWeigh(p, q = 1) {
  if (p.venda_granel) askQuantity(p, q);
  else add(p, q);
}
function search(term) {
  return Keyboard.filterProducts(state.produtos, term);
}
let liveProducts = [], liveIndex = -1;
const liveInput = $("pdv-busca-produto");
const liveBox = $("pdv-resultados");
liveInput.setAttribute("role", "combobox");
liveInput.setAttribute("aria-autocomplete", "list");
liveInput.setAttribute("aria-controls", "pdv-resultados");
liveInput.setAttribute("aria-expanded", "false");
liveBox.setAttribute("role", "listbox");
function hideLiveResults() {
  liveBox.classList.add("hidden");
  liveInput.setAttribute("aria-expanded", "false");
  liveInput.removeAttribute("aria-activedescendant");
  liveProducts = [];
  liveIndex = -1;
}
function highlightLive() {
  liveBox.querySelectorAll("[data-live-product]").forEach((button, n) => {
    button.classList.toggle("is-active", n === liveIndex);
    button.setAttribute("aria-selected", String(n === liveIndex));
  });
  const button = liveBox.querySelector(`[data-live-product="${liveIndex}"]`);
  if (button) {
    liveInput.setAttribute("aria-activedescendant", button.id);
    button.scrollIntoView({ block: "nearest" });
    choose(liveProducts[liveIndex]);
  }
}
function showLiveResults() {
  selected = null;
  liveIndex = -1;
  const term = liveInput.value.trim();
  if (!term) { hideLiveResults(); return; }
  liveProducts = search(term);
  liveBox.innerHTML = liveProducts.map((p,n) =>
    `<button type="button" class="search-result-item" role="option" aria-selected="false" id="live-product-${n}" data-live-product="${n}"><span class="sr-nome">${esc(p.nome)}</span><span class="sr-meta">${esc(p.codigo || p.gtin || "")} · ${brl(p.preco_venda)} · Estoque ${Number(p.quantidade_estoque).toLocaleString("pt-BR")}</span></button>`
  ).join("") || '<div class="pdx-vazio" role="status">Nenhum produto encontrado.</div>';
  liveBox.classList.remove("hidden");
  liveInput.setAttribute("aria-expanded","true");
  liveInput.removeAttribute("aria-activedescendant");
  if (liveProducts.length === 1) choose(liveProducts[0]);
}
liveBox.onclick = action((event) => {
  const button = event.target.closest("[data-live-product]");
  if (!button) return;
  const product = liveProducts[Number(button.dataset.liveProduct)];
  hideLiveResults();
  askQuantity(product, parse($("pdv-qtd").value));
});
liveInput.oninput = showLiveResults;
liveInput.onkeydown = action((event) => {
  if (event.key === "Escape" && !liveBox.classList.contains("hidden")) {
    event.preventDefault(); event.stopPropagation(); hideLiveResults(); return;
  }
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault(); event.stopPropagation();
    if (liveBox.classList.contains("hidden")) showLiveResults();
    liveIndex = Keyboard.nextIndex(liveIndex, event.key === "ArrowDown" ? 1 : -1, liveProducts.length);
    highlightLive(); return;
  }
  if (event.key !== "Enter") return;
  event.preventDefault(); event.stopPropagation();
  if (event.repeat) return;
  const text = liveInput.value.trim();
  if (!text) { productPicker(); return; }
  const digits = text.replace(/^0+/, "");
  const barcode = /^\d{8,14}$/.test(text) ? state.produtos.find(p => p.gtin === text || (p.gtin && String(p.gtin).replace(/^0+/, "") === digits)) : null;
  if (barcode) { hideLiveResults(); addOrWeigh(barcode, parse($("pdv-qtd").value)); return; }
  const exactCode = state.produtos.find(p => p.codigo === text);
  const product = liveProducts[liveIndex < 0 ? 0 : liveIndex] || exactCode || search(text)[0];
  if (!product) throw new Error("Nenhum produto encontrado.");
  hideLiveResults();
  askQuantity(product, parse($("pdv-qtd").value));
});
document.addEventListener("pointerdown", event => {
  if (!event.target.closest(".pdx-busca-wrap")) hideLiveResults();
});
function productPicker(list = state.produtos, title = "Buscar produto") {
  modal(title, '<input id="product-query" role="combobox" aria-autocomplete="list" aria-controls="product-list" aria-expanded="true" placeholder="Nome, código ou código de barras" style="width:100%"><div id="product-list" role="listbox"></div>');
  let found = [], index = -1;
  const input = $("product-query"), box = $("product-list");
  function highlight() {
    box.querySelectorAll("[data-product]").forEach((button,n) => {
      button.classList.toggle("is-active", n === index);
      button.setAttribute("aria-selected",String(n === index));
    });
    const active = box.querySelector(`[data-product="${index}"]`);
    if (active) { input.setAttribute("aria-activedescendant",active.id); active.scrollIntoView({block:"nearest"}); }
  }
  function pick(n) {
    if (!found[n]) return;
    const product = found[n];
    askQuantity(product, parse($("pdv-qtd").value));
  }
  function show() {
    found = Keyboard.filterProducts(list,input.value);
    index = -1;
    input.removeAttribute("aria-activedescendant");
    box.innerHTML = found.map((p,n) =>
      `<button type="button" class="result" role="option" aria-selected="false" id="picker-product-${n}" data-product="${n}"><b>${esc(p.nome)}</b> · ${brl(p.preco_venda)} <small>Estoque ${Number(p.quantidade_estoque).toLocaleString("pt-BR")}</small></button>`
    ).join("") || "<p>Nenhum produto encontrado.</p>";
  }
  input.oninput = show;
  input.onkeydown = action(event => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault(); event.stopPropagation();
      index = Keyboard.nextIndex(index,event.key === "ArrowDown" ? 1 : -1,found.length); highlight();
    } else if (event.key === "Enter") {
      event.preventDefault(); event.stopPropagation();
      if (!event.repeat) pick(index < 0 ? 0 : index);
    }
  });
  box.onclick = action(event => {
    const button = event.target.closest("[data-product]");
    if (button) pick(Number(button.dataset.product));
  });
  show(); input.focus();
}
$("btn-adicionar-pdv").onclick = action(() => {
  if (selected) addOrWeigh(selected, parse($("pdv-qtd").value));
  else productPicker(search(liveInput.value));
});
$("pdv-carrinho").onclick = action((e) => {
  const b = e.target.closest("[data-remove]");
  if (!b) return;
  if (payments.length)
    throw new Error("Remova os pagamentos antes de alterar o cupom.");
  cart.splice(Number(b.dataset.remove), 1);
  render();
});
$("pdx-pag-lista").onclick = (e) => {
  const b = e.target.closest("[data-pay-remove]");
  if (b) {
    payments.splice(Number(b.dataset.payRemove), 1);
    render();
  }
};
$("pdx-pagto").onclick = action((e) => {
  const b = e.target.closest("button");
  if (!b) return;
  const t = totals();
  if (!cart.length) throw new Error("Adicione itens antes de pagar.");
  if (b.id === "pdv-nota-prazo") {
    if (!clienteId)
      throw new Error("Selecione um cliente para a Nota a Prazo (F2).");
    payments = [];
    prazo = !prazo;
    render();
    return;
  }
  prazo = false;
  if (payments.length >= 10) throw new Error("Limite de 10 pagamentos.");
  const valor = Math.round(parse($("pdv-valor-forma").value) * 100),
    remaining = t.total - t.paid;
  if (!Number.isFinite(valor) || valor <= 0 || !remaining)
    throw new Error("Informe um valor válido.");
  if (valor > remaining && b.dataset.forma !== "Dinheiro")
    throw new Error("O valor excede o restante da venda.");
  payments.push({
    forma_pagamento: b.dataset.forma,
    valor: Math.min(valor, remaining) / 100,
  });
  if (valor > remaining)
    $("pdv-msg").textContent = "Troco: " + brl((valor - remaining) / 100);
  render();
});
function clientPicker() {
  modal(
    "Selecionar cliente",
    '<input id="client-query" placeholder="Nome, CPF ou telefone" style="width:100%"><button id="client-none">Consumidor Final</button><div id="client-list"></div>',
  );
  const show = () => {
    const t = $("client-query").value.toLowerCase();
    const found = state.clientes
      .filter((c) =>
        [c.nome, c.cpf, c.telefone].some((v) =>
          String(v || "")
            .toLowerCase()
            .includes(t),
        ),
      )
      .slice(0, 60);
    $("client-list").innerHTML = found
      .map(
        (c, n) =>
          `<button class="result" data-client="${n}">${esc(c.nome)} · ${esc(c.cpf || "")}</button>`,
      )
      .join("");
    $("client-list").onclick = (e) => {
      const b = e.target.closest("[data-client]");
      if (b) {
        clienteId = found[Number(b.dataset.client)].id;
        closeModal();
        render();
      }
    };
  };
  $("client-none").onclick = () => {
    clienteId = null;
    prazo = false;
    closeModal();
    render();
  };
  $("client-query").oninput = show;
  show();
  $("client-query").focus();
}
$("btn-pdx-cliente").onclick = clientPicker;
$("pdv-desconto").onchange = action(() => {
  if (payments.length) {
    payments = [];
    $("pdv-msg").textContent =
      "Desconto alterado. Lance os pagamentos novamente.";
  }
  render();
});
$("pdv-cpf-nota").oninput = saveDraft;
for (const id of ["btn-pdx-cancelar", "btn-pdx-limpar", "btn-limpar-venda"])
  $(id).onclick = () => {
    if (!cart.length || confirm("Cancelar este cupom?")) clearSale();
  };
$("btn-finalizar-venda").onclick = action(async () => {
  if (busy) return;
  busy = true;
  clearTimeout(draftTimer);
  render();
  try {
    const receipt = await api.sale({
      itens: cart,
      desconto: Number($("pdv-desconto").value) || 0,
      pagamentos: payments,
      clienteId,
      prazo,
      cpf: $("pdv-cpf-nota").value,
      operacao,
    });
    lastReceipt = receipt;
    clearSale();
    applyState(await api.state());
    modal(
      "Venda registrada",
      `<p>Pedido local <b>nº ${receipt.numeroLocal}</b> · ${brl(receipt.dados.total)}</p><p>A venda está salva neste computador.</p><div class="receipt-actions"><button id="receipt-cancel">Cancelar impressão</button><button id="receipt-print" class="primary">Imprimir comprovante não fiscal</button></div>`,
    );
    $("receipt-cancel").onclick = closeModal;
    $("receipt-print").onclick = action(async () => {
      await api.print(receipt.idLocal);
      closeModal();
    });
  } finally {
    busy = false;
    render();
  }
});
async function cashPanel() {
  const c = state.caixa;
  if (!c?.aberto) {
    modal(
      "Abrir Caixa PDV",
      '<label>Valor inicial em dinheiro</label> <input id="initial-cash" inputmode="decimal" value="0,00"><button id="open-cash" class="primary">Abrir caixa</button><p>A abertura precisa de conexão. Após abrir, as vendas continuam sem internet.</p>',
    );
    $("open-cash").onclick = action(async () => {
      const valor = parse($("initial-cash").value);
      if (!Number.isFinite(valor)) throw new Error("Valor inicial inválido");
      await api.cash({ action: "abrir", valor });
      applyState(await api.state());
      closeModal();
    });
    return;
  }
  const r = c.resumo || {};
  modal(
    "Caixa PDV nº " + c.caixa.numero,
    `<p>Aberto por ${esc(c.caixa.aberto_por_nome)} · Inicial ${brl(c.caixa.valor_inicial)}</p><p>Recebido no ERP: ${brl(r.total_recebido || 0)}</p><p>Dinheiro esperado no ERP: ${brl(r.saldo_dinheiro_esperado || 0)}</p><p>Vendas locais pendentes precisam ser enviadas antes do fechamento.</p><button id="refresh-cash">Atualizar</button><button id="close-cash">Fechar caixa</button>`,
  );
  $("refresh-cash").onclick = action(async () => {
    await api.cash({ action: "atualizar" });
    applyState(await api.state());
    await cashPanel();
  });
  $("close-cash").onclick = action(async () => {
    if (!confirm("Enviar as pendências e fechar o Caixa PDV?")) return;
    await api.cash({ action: "fechar" });
    applyState(await api.state());
    closeModal();
  });
}
$("btn-pdx-caixa-abrir").onclick = action(cashPanel);
$("btn-pdx-caixa-gerenciar").onclick = action(cashPanel);
for (const [id, options] of [
  ["send", { enviar: true, receber: true }],
  ["receive", { enviar: false, receber: true }],
])
  $(id).onclick = action(async () => {
    $(id).disabled = true;
    try {
      applyState(await api.sync(options));
      if (state.lastSync?.erros?.length)
        throw new Error(state.lastSync.erros.map((e) => e.mensagem).join("\n"));
    } finally {
      $(id).disabled = false;
    }
  });
$("history").onclick = action(async () => {
  const list = await api.history();
  modal(
    "Histórico / pendências",
    `<table><thead><tr><th>Pedido local</th><th>Valor</th><th>Envio</th><th></th></tr></thead><tbody>${list.map((r, n) => `<tr><td>${r.numero_local}<br><small>${esc(r.criada_em)}</small></td><td>${brl(r.total)}</td><td>${esc(r.estado_sync)}${r.erro_sync ? '<br><small class="error">' + esc(r.erro_sync) + "</small>" : ""}</td><td><button data-print="${n}">Imprimir</button></td></tr>`).join("")}</tbody></table>`,
  );
  $("modal-body").onclick = action(async (e) => {
    const b = e.target.closest("[data-print]");
    if (b) await api.print(list[Number(b.dataset.print)].id_local);
  });
});
$("pdx-atalhos-lista").onclick = action((e) => {
  const b = e.target.closest("[data-shortcut]");
  if (!b) return;
  const a = state.atalhos[Number(b.dataset.shortcut)],
    ids = new Set(a.produtos.map((p) => p.produto_id));
  productPicker(
    state.produtos.filter((p) => ids.has(p.id)),
    a.nome,
  );
});
$("btn-pdx-config-atalhos").onclick = () => {
  modal(
    "Configurar atalhos",
    "<p>Os atalhos são os mesmos do ERP. Cadastre ou altere os grupos no PDV do navegador e clique em Receber atualizações neste aplicativo.</p>",
  );
};
$("login-form").onsubmit = async (e) => {
  e.preventDefault();
  $("login-submit").disabled = true;
  $("login-error").textContent = "";
  try {
    applyState(
      await api.login({
        empresa: $("empresa").value.trim(),
        usuario: $("usuario").value.trim(),
        senha: $("senha").value,
      }),
      true,
    );
    $("senha").value = "";
    $("pdv-busca-produto").focus();
  } catch (e) {
    $("login-error").textContent = e.message;
  } finally {
    $("login-submit").disabled = false;
  }
};
function showManual() {
  modal("Manual de atalhos - Florest PDV", Keyboard.manualBody());
}
$("shortcut-help").onclick = showManual;
for (const shortcut of Keyboard.shortcuts.filter(s => s.action === "payment")) {
  const button = document.querySelector(`#pdx-pagto [data-forma="${shortcut.forma}"]`);
  if (button) {
    const hint = document.createElement("kbd");
    hint.textContent = shortcut.key;
    hint.className = "payment-key";
    button.appendChild(hint);
    button.title = shortcut.label + " (" + shortcut.key + ")";
    button.setAttribute("aria-keyshortcuts", shortcut.key);
  }
}
document.addEventListener("keydown", (event) => {
  if (!state?.context || event.defaultPrevented || event.ctrlKey || event.altKey || event.metaKey || event.shiftKey) return;
  if (event.key === "Escape") {
    event.preventDefault();
    if (!liveBox.classList.contains("hidden")) hideLiveResults();
    else if (modalOpen) closeModal();
    else $("btn-pdx-cancelar").click();
    return;
  }
  const shortcut = Keyboard.shortcuts.find(item => item.key === event.key);
  if (!shortcut) return;
  // Intercepta F1/F10 inclusive em janelas internas, sem disparar ações fora delas.
  event.preventDefault();
  if (modalOpen || event.repeat || busy) return;
  if (shortcut.action === "help") showManual();
  else if (shortcut.action === "client") clientPicker();
  else if (shortcut.action === "finish") $("btn-finalizar-venda").click();
  else if (shortcut.action === "discount") { $("pdv-desconto").focus(); $("pdv-desconto").select(); }
  else if (shortcut.action === "search") productPicker();
  else if (shortcut.action === "payment") {
    const button = document.querySelector(`#pdx-pagto [data-forma="${shortcut.forma}"]`);
    if (!button || button.disabled) return;
    button.focus({preventScroll:true});
    button.click();
    if (totals().total > totals().paid) focusPayment();
    else if (!$("btn-finalizar-venda").disabled) $("btn-finalizar-venda").focus();
  }
});
setInterval(() => {
  $("pdx-relogio").textContent = new Date().toLocaleString("pt-BR");
}, 1000);
api.onChange((next) => applyState(next));
api
  .state()
  .then((s) => applyState(s, true))
  .catch((e) => {
    $("login-error").textContent = e.message;
  });
const remote = (name, args = {}) => api.remote({ name, args });
let cmdBusy = false;
function cmdAction(fn) {
  return action(async (...args) => {
    if (cmdBusy) return;
    cmdBusy = true;
    const buttons = [...$("modal-body").querySelectorAll("button")];
    buttons.forEach((b) => (b.disabled = true));
    try {
      await fn(...args);
    } finally {
      cmdBusy = false;
      buttons.filter((b) => b.isConnected).forEach((b) => (b.disabled = false));
    }
  });
}
async function comandas() {
  const list = await remote("pdv_comandas_listar");
  modal(
    "Comandas do PDV",
    '<p>As comandas são compartilhadas com o ERP e precisam de conexão.</p><div id="cmd-list"></div>',
  );
  $("cmd-list").innerHTML = list
    .map(
      (c, n) =>
        `<button class="result" data-cmd="${n}"><b>Comanda ${String(c.numero).padStart(2, "0")}</b> · ${c.status === "aberta" ? esc(c.cliente_nome) + " · " + brl(c.total) : "Livre"}</button>`,
    )
    .join("");
  $("cmd-list").onclick = cmdAction(async (e) => {
    const b = e.target.closest("[data-cmd]");
    if (!b) return;
    const c = list[Number(b.dataset.cmd)];
    if (c.status === "aberta") return comanda(c.comanda_id);
    modal(
      "Abrir comanda " + c.numero,
      '<label>Cliente obrigatório</label><input id="cmd-client-search" placeholder="Buscar cliente" style="width:100%"><select id="cmd-client" style="width:100%"></select><button id="cmd-open" class="primary">Abrir comanda</button>',
    );
    const show = () => {
      $("cmd-client").innerHTML = state.clientes
        .filter((c) =>
          c.nome
            .toLowerCase()
            .includes($("cmd-client-search").value.toLowerCase()),
        )
        .map((c) => `<option value="${esc(c.id)}">${esc(c.nome)}</option>`)
        .join("");
    };
    $("cmd-client-search").oninput = show;
    show();
    $("cmd-open").onclick = cmdAction(async () => {
      if (!$("cmd-client").value) throw new Error("Selecione um cliente.");
      await remote("pdv_comanda_abrir", {
        p_comanda_id: c.comanda_id,
        p_cliente_id: $("cmd-client").value,
      });
      await comanda(c.comanda_id);
    });
  });
}
async function comanda(id) {
  const c = await remote("pdv_comanda_obter", { p_comanda_id: id });
  if (c.status !== "aberta") return comandas();
  modal(
    "Comanda " + c.numero,
    `<p><b>${esc(c.cliente_nome)}</b> · TOTAL ${brl(c.total)}</p><input id="cmd-query" placeholder="Nome ou código do produto" style="width:100%"><div id="cmd-products"></div><table>${c.itens.map((i, n) => `<tr><td>${esc(i.produto_nome)}</td><td>${i.quantidade}</td><td>${brl(i.subtotal)}</td><td><button data-cmd-remove="${n}">Remover</button></td></tr>`).join("")}</table><button id="cmd-refresh">Atualizar</button><button id="cmd-cancel">Cancelar comanda</button><button id="cmd-finish" class="primary" ${c.itens.length ? "" : "disabled"}>Finalizar comanda</button><button id="cmd-back">Voltar</button>`,
  );
  $("cmd-query").oninput = () => {
    const term = $("cmd-query").value.trim();
    const found = term ? search(term).slice(0, 10) : [];
    $("cmd-products").innerHTML = found
      .map(
        (p, n) =>
          `<button class="result" data-cmd-product="${n}">${esc(p.nome)} · ${brl(p.preco_venda)}</button>`,
      )
      .join("");
    $("cmd-products").onclick = action((e) => {
      const b = e.target.closest("[data-cmd-product]");
      if (!b) return;
      const p = found[Number(b.dataset.cmdProduct)];
      modal(
        "Adicionar à comanda",
        `<p>${esc(p.nome)}</p><input id="cmd-quantity" value="1" inputmode="decimal"><button id="cmd-add" class="primary">Adicionar</button>`,
      );
      $("cmd-add").onclick = cmdAction(async () => {
        const q = parse($("cmd-quantity").value);
        if (!Number.isFinite(q) || q <= 0)
          throw new Error("Quantidade inválida.");
        await remote("pdv_comanda_item_adicionar", {
          p_sessao_id: c.sessao_id,
          p_produto_id: p.id,
          p_quantidade: q,
        });
        await comanda(id);
      });
    });
  };
  $("modal-body")
    .querySelectorAll("[data-cmd-remove]")
    .forEach(
      (b) =>
        (b.onclick = cmdAction(async () => {
          if (!confirm("Remover este item da comanda?")) return;
          await remote("pdv_comanda_item_cancelar", {
            p_item_id: c.itens[Number(b.dataset.cmdRemove)].item_id,
          });
          await comanda(id);
        })),
    );
  $("cmd-refresh").onclick = action(() => comanda(id));
  $("cmd-back").onclick = action(comandas);
  $("cmd-cancel").onclick = cmdAction(async () => {
    if (!confirm("Cancelar esta comanda e todos os itens?")) return;
    await remote("pdv_comanda_cancelar", { p_sessao_id: c.sessao_id });
    await comandas();
  });
  $("cmd-finish").onclick = () => {
    modal(
      "Receber comanda " + c.numero,
      `<p>Total: <b>${brl(c.total)}</b></p><select id="cmd-payment"><option>Dinheiro</option><option>Pix</option><option>Cartão de Débito</option><option>Cartão de Crédito</option><option>Nota a Prazo</option></select><button id="cmd-confirm" class="primary">Confirmar recebimento</button><p>A finalização é registrada no ERP com proteção contra repetição.</p>`,
    );
    $("cmd-confirm").onclick = cmdAction(async () => {
      const forma = $("cmd-payment").value;
      if (!confirm("Confirmar " + brl(c.total) + " em " + forma + "?")) return;
      const r = await remote("pdv_comanda_finalizar", {
        p_sessao_id: c.sessao_id,
        p_nota_prazo: forma === "Nota a Prazo",
        ...(forma === "Nota a Prazo"
          ? {}
          : {
              p_pagamentos: [
                { forma_pagamento: forma, valor: Number(c.total) },
              ],
            }),
      });
      modal(
        "Comanda finalizada",
        `<p>Venda nº ${esc(r.numero_venda)} · ${brl(r.total ?? c.total)}</p><button id="cmd-result-print" class="primary">Imprimir comprovante não fiscal</button><button id="cmd-result-cancel">Cancelar impressão</button>`,
      );
      $("cmd-result-print").onclick = action(async () => {
        await api.print(r.idLocal);
        closeModal();
      });
      $("cmd-result-cancel").onclick = closeModal;
      applyState(await api.state());
    });
  };
}
$("btn-pdv-comandas").onclick = action(comandas);
$("btn-pdx-config-atalhos").onclick = () => {
  const groups = structuredClone(state.atalhos);
  const draw = () => {
    modal(
      "Configurar atalhos",
      `<p>Grupos compartilhados com o PDV do navegador.</p><div>${groups.map((g, n) => `<p><b>${esc(g.nome)}</b> (${g.produtos.length} produtos) <button data-edit-group="${n}">Editar</button><button data-remove-group="${n}">Excluir</button></p>`).join("")}</div><input id="group-name" placeholder="Nome do novo grupo"><button id="group-add">Adicionar grupo</button><button id="group-save" class="primary">Salvar no ERP</button>`,
    );
    $("group-add").onclick = () => {
      const nome = $("group-name").value.trim();
      if (!nome) return;
      groups.push({
        id: crypto.randomUUID(),
        nome,
        imagem: null,
        produtos: [],
      });
      draw();
    };
    $("modal-body")
      .querySelectorAll("[data-remove-group]")
      .forEach(
        (b) =>
          (b.onclick = () => {
            groups.splice(Number(b.dataset.removeGroup), 1);
            draw();
          }),
      );
    $("modal-body")
      .querySelectorAll("[data-edit-group]")
      .forEach(
        (b) =>
          (b.onclick = () => {
            const g = groups[Number(b.dataset.editGroup)],
              ids = new Set(g.produtos.map((p) => p.produto_id));
            modal(
              "Produtos de " + g.nome,
              `<input id="group-query" placeholder="Buscar produto" style="width:100%"><div id="group-products"></div><button id="group-done" class="primary">Concluir seleção</button>`,
            );
            const show = () => {
              const found = search($("group-query").value);
              $("group-products").innerHTML = found
                .map(
                  (p) =>
                    `<label style="display:block;padding:8px"><input type="checkbox" data-group-product="${esc(p.id)}" ${ids.has(p.id) ? "checked" : ""}> ${esc(p.nome)}</label>`,
                )
                .join("");
              $("group-products").onchange = (e) => {
                const id = e.target.dataset.groupProduct;
                if (e.target.checked) ids.add(id);
                else ids.delete(id);
              };
            };
            $("group-query").oninput = show;
            show();
            $("group-done").onclick = () => {
              g.produtos = [...ids].map(
                (produto_id) =>
                  g.produtos.find((p) => p.produto_id === produto_id) || {
                    produto_id,
                    imagem: null,
                  },
              );
              draw();
            };
          }),
      );
    $("group-save").onclick = action(async () => {
      await remote("pdv_atalhos_salvar", { p_atalhos: groups });
      applyState(await api.state());
      closeModal();
    });
  };
  draw();
};

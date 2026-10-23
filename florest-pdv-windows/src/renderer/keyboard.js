"use strict";
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else Object.defineProperty(root, "FlorestKeyboard", { value: api });
})(globalThis, function () {
  const shortcuts = Object.freeze([
    { key: "F1", label: "Abrir o manual de atalhos", action: "help" },
    { key: "F2", label: "Selecionar ou alterar o cliente", action: "client" },
    { key: "F3", label: "Finalizar a venda", action: "finish" },
    { key: "F4", label: "Pagamento em dinheiro", action: "payment", forma: "Dinheiro" },
    { key: "F5", label: "Informar desconto", action: "discount" },
    { key: "F6", label: "Pagamento por Pix", action: "payment", forma: "Pix" },
    { key: "F7", label: "Pagamento no cartão de débito", action: "payment", forma: "Cartão de Débito" },
    { key: "F8", label: "Pagamento no cartão de crédito", action: "payment", forma: "Cartão de Crédito" },
    { key: "F9", label: "Abrir a pesquisa de produtos", action: "search" }
  ].map(Object.freeze));
  function normalize(value) {
    return String(value ?? "").trim().toLocaleLowerCase("pt-BR").normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  }
  function filterProducts(products, term) {
    const query = normalize(term);
    if (!query) return products.slice().sort((a,b) => a.nome.localeCompare(b.nome, "pt-BR"));
    const parts = query.split(/\s+/);
    function rank(p) {
      const name = normalize(p.nome);
      if (name.startsWith(query)) return 0;
      const words = name.split(/[^a-z0-9]+/).filter(Boolean);
      if (words.some((_, index) => parts.every((part, offset) => words[index + offset]?.startsWith(part)))) return 1;
      if ([p.codigo, p.gtin].some(v => normalize(v).startsWith(query))) return 2;
      return -1;
    }
    return products.map(p => ({ p, rank: rank(p) })).filter(item => item.rank >= 0)
      .sort((a,b) => a.rank - b.rank || a.p.nome.localeCompare(b.p.nome,"pt-BR") || String(a.p.id).localeCompare(String(b.p.id))).map(item => item.p);
  }
  function nextIndex(current, direction, length) {
    if (!length) return -1;
    if (current < 0) return direction > 0 ? 0 : length - 1;
    return (current + direction + length) % length;
  }
  function manualBody() {
    return '<p>Para vender pelo teclado:</p><ol><li>Digite parte do nome, como <b>BR</b>. A lista mostra nomes que começam com essas letras, inclusive palavras como <b>BRAHMA</b> em <b>CERVEJA BRAHMA</b>.</li><li>Use <b>seta para baixo / cima</b> para escolher o produto e <b>Enter</b> para abrir a quantidade.</li><li>Digite a quantidade (por exemplo, <b>2</b>) e pressione <b>Enter</b>. O item entra no cupom e o foco vai para o valor do pagamento.</li><li>O valor restante já aparece selecionado. Se for dividir o pagamento, digite o valor desta parte. Pressione a tecla da forma desejada.</li><li>Confira o cupom e pressione <b>F3</b> para finalizar. Depois escolha imprimir o comprovante não fiscal ou cancelar a impressão.</li></ol>'
      + '<table><thead><tr><th>Tecla</th><th>Função</th></tr></thead><tbody>'
      + shortcuts.map(s => '<tr><td><b>' + s.key + '</b></td><td>' + s.label + '</td></tr>').join('')
      + '<tr><td><b>Setas para baixo / cima</b></td><td>Selecionar um produto na lista de pesquisa</td></tr><tr><td><b>Enter</b></td><td>Abrir a quantidade do produto selecionado ou confirmar a quantidade</td></tr><tr><td><b>Esc</b></td><td>Fechar a lista de busca ou a janela atual. Na tela principal, pedir confirmação para cancelar o cupom</td></tr></tbody></table>'
      + '<p><b>Pagamento:</b> cada atalho lança o valor informado na forma escolhida. Não finaliza a venda automaticamente. Dinheiro aceita valor maior e mostra o troco. A Nota a Prazo continua disponível no botão e exige cliente cadastrado.</p>'
      + '<p><b>Leitor de código de barras:</b> continua adicionando produtos comuns diretamente ao cupom. Produtos a granel pedem quantidade/peso. Para digitar decimais, use por exemplo <b>0,500</b>.</p>'
      + '<p><b>Notebook:</b> se as teclas F controlarem brilho ou volume, utilize <b>Fn + F4</b>, por exemplo, ou ative o Fn Lock do teclado.</p>';
  }
  return Object.freeze({ shortcuts, normalize, filterProducts, nextIndex, manualBody });
});

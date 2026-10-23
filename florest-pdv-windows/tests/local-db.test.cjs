"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { openLocalDatabase } = require("../src/local-db.cjs");

test("vendas offline recebem ids distintos, numeração por empresa e confirmação segura", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "florest-pdv-test-"));
  let storage;
  try {
    storage = openLocalDatabase(dir);
    const primeira = storage.registrarVenda({
      empresaId: "empresa-a",
      dados: { total: 10 },
    });
    const segunda = storage.registrarVenda({
      empresaId: "empresa-a",
      dados: { total: 20 },
    });
    const outra = storage.registrarVenda({
      empresaId: "empresa-b",
      dados: { total: 30 },
    });
    assert.equal(primeira.numeroLocal, 1);
    assert.equal(segunda.numeroLocal, 2);
    assert.equal(outra.numeroLocal, 1);
    assert.notEqual(primeira.idLocal, segunda.idLocal);
    assert.equal(storage.pendentes("empresa-a").length, 2);
    storage.confirmarSincronizacao({
      empresaId: "empresa-a",
      idLocal: primeira.idLocal,
      idRemoto: "remota-1",
    });
    assert.equal(storage.pendentes("empresa-a").length, 1);
    assert.throws(
      () =>
        storage.confirmarSincronizacao({
          empresaId: "empresa-a",
          idLocal: primeira.idLocal,
          idRemoto: "remota-2",
        }),
      /conflitante/,
    );
    assert.throws(
      () => storage.registrarVenda({ empresaId: "", dados: {} }),
      /Empresa obrigatória/,
    );
    storage.fechar();
    storage = openLocalDatabase(dir);
    assert.equal(storage.pendentes("empresa-a").length, 1);
    assert.equal(
      storage.registrarVenda({ empresaId: "empresa-a", dados: { total: 40 } })
        .numeroLocal,
      3,
    );
  } finally {
    if (storage) storage.fechar();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("catálogo local permite pesquisa por nome e código sem misturar empresas", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "florest-produtos-test-"));
  const storage = openLocalDatabase(dir);
  try {
    storage.atualizarProdutos("empresa-a", [
      { id: "1", nome: "Coca-Cola 2L", codigo_barras: "789000001" },
      { id: "2", nome: "Água mineral", codigo_barras: "789000002" },
    ]);
    storage.atualizarProdutos("empresa-b", [
      { id: "1", nome: "Outro produto" },
    ]);
    assert.equal(storage.buscarProdutos("empresa-a", "coca").length, 1);
    assert.equal(
      storage.buscarProdutos("empresa-a", "789000002")[0].nome,
      "Água mineral",
    );
    assert.equal(storage.buscarProdutos("empresa-b", "coca").length, 0);
    assert.throws(
      () => storage.atualizarProdutos("empresa-a", [{ nome: "Sem ID" }]),
      /Produto sem ID/,
    );
    assert.equal(storage.buscarProdutos("empresa-a").length, 2);
  } finally {
    storage.fechar();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("clientes offline ficam isolados por empresa e pendências têm resumo correto", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "florest-clientes-test-"));
  const storage = openLocalDatabase(dir);
  try {
    storage.atualizarClientes("empresa-a", [
      {
        id: "c1",
        nome: "Maria Silva",
        cpf: "12345678900",
        telefone: "34999990000",
      },
    ]);
    storage.atualizarClientes("empresa-b", [
      { id: "c1", nome: "João Souza", cpf: "98765432100" },
    ]);
    assert.equal(
      storage.buscarClientes("empresa-a", "12345678900")[0].nome,
      "Maria Silva",
    );
    assert.equal(storage.buscarClientes("empresa-a", "João").length, 0);
    assert.equal(storage.buscarClientes("empresa-b", "João").length, 1);
    assert.throws(
      () => storage.atualizarClientes("empresa-a", [{ nome: "Sem ID" }]),
      /Cliente sem ID/,
    );
    const venda = storage.registrarVenda({
      empresaId: "empresa-a",
      dados: { total: 10 },
    });
    assert.equal(storage.resumoPendencias("empresa-a").pendente, 1);
    assert.deepEqual(storage.resumoPendencias("empresa-b"), {});
    storage.registrarErro({
      empresaId: "empresa-a",
      idLocal: venda.idLocal,
      mensagem: "Sem conexão",
    });
    assert.equal(storage.resumoPendencias("empresa-a").erro, 1);
  } finally {
    storage.fechar();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("catálogo completo remove excluídos e falha sem apagar dados anteriores", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "florest-catalogo-"));
  const storage = openLocalDatabase(dir);
  try {
    storage.atualizarProdutos("a", [{ id: "antigo", nome: "Antigo" }]);
    storage.atualizarProdutos("b", [{ id: "outro", nome: "Outra empresa" }]);
    storage.atualizarCatalogo("a", {
      empresaId: "a",
      produtos: [{ id: "novo", nome: "Novo" }],
      clientes: [{ id: "c" }],
    });
    assert.equal(storage.buscarProdutos("a")[0].id, "novo");
    assert.equal(storage.buscarProdutos("b")[0].id, "outro");
    assert.throws(() =>
      storage.atualizarCatalogo("a", {
        empresaId: "a",
        produtos: [],
        clientes: [{ id: "x", empresa_id: "b" }],
      }),
    );
    assert.equal(storage.buscarProdutos("a")[0].id, "novo");
    assert.equal(storage.buscarClientes("a")[0].id, "c");
  } finally {
    storage.fechar();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("confirmação atualiza estoque uma vez mesmo sem receber catálogo e clique repetido não duplica", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "florest-idempotencia-"));
  const storage = openLocalDatabase(dir);
  try {
    storage.atualizarProdutos("a", [{ id: "p", quantidade_estoque: 10 }]);
    const input = {
      empresaId: "a",
      chaveOperacao: "12345678-1234-1234-1234-123456789012",
      dados: { itens: [{ produto_id: "p", quantidade: 2 }] },
    };
    const first = storage.registrarVenda(input),
      second = storage.registrarVenda(input);
    assert.equal(first.idLocal, second.idLocal);
    assert.equal(storage.pendentes("a").length, 1);
    storage.confirmarSincronizacao({
      empresaId: "a",
      idLocal: first.idLocal,
      idRemoto: "remote",
    });
    storage.confirmarSincronizacao({
      empresaId: "a",
      idLocal: first.idLocal,
      idRemoto: "remote",
    });
    assert.equal(storage.buscarProdutos("a")[0].quantidade_estoque, 8);
    assert.throws(
      () => storage.registrarVenda({ ...input, dados: { total: 99 } }),
      /outros dados/,
    );
  } finally {
    storage.fechar();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

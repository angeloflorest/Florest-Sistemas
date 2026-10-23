"use strict";
const {
  app,
  BrowserWindow,
  ipcMain,
  safeStorage,
  dialog,
} = require("electron");
const path = require("node:path");
const fs = require("node:fs");
const crypto = require("node:crypto");
const { createClient } = require("@supabase/supabase-js");
const { openLocalDatabase } = require("./local-db.cjs");
const { createSync } = require("./sync.cjs");
const { validarVenda } = require("./sale.cjs");
const config = require("./config.cjs");
let db,
  client,
  win,
  context = null,
  caixa = null,
  sync = null,
  lastSync = null,
  online = false,
  quitting = false,
  blocked = null,
  cashClosing = false;
const smokeTest = process.argv.includes("--smoke-test");
if (smokeTest)
  app.setPath(
    "userData",
    require("node:os").tmpdir() + "/florest-pdv-smoke-" + process.pid,
  );
const lock = app.requestSingleInstanceLock();
if (!lock) app.quit();
function secretFile(k) {
  return path.join(
    app.getPath("userData"),
    crypto.createHash("sha256").update(k).digest("hex") + ".secure",
  );
}
const secrets = {
  getItem(k) {
    try {
      if (!safeStorage.isEncryptionAvailable()) return null;
      return safeStorage.decryptString(fs.readFileSync(secretFile(k)));
    } catch {
      return null;
    }
  },
  setItem(k, v) {
    if (!safeStorage.isEncryptionAvailable())
      throw new Error("Proteção de dados do Windows indisponível.");
    const f = secretFile(k);
    fs.writeFileSync(f + ".tmp", safeStorage.encryptString(v), { mode: 0o600 });
    fs.renameSync(f + ".tmp", f);
  },
  removeItem(k) {
    try {
      fs.unlinkSync(secretFile(k));
    } catch {}
  },
};
function cfg(k, v) {
  if (arguments.length === 2) {
    db.db
      .prepare(
        "INSERT INTO configuracoes(chave,valor) VALUES(?,?) ON CONFLICT(chave) DO UPDATE SET valor=excluded.valor",
      )
      .run(k, JSON.stringify(v));
    return v;
  }
  const r = db.db
    .prepare("SELECT valor FROM configuracoes WHERE chave=?")
    .get(k);
  return r ? JSON.parse(r.valor) : null;
}
function isNetwork(e) {
  return (
    !e?.code &&
    (/fetch|network|timeout|timed out|ECONN|ENOTFOUND|abort|connection/i.test(
      String(e?.message || e),
    ) ||
      e?.status === 0)
  );
}
async function rpc(name, args = {}) {
  const { data, error } = await client.rpc(name, args);
  if (error) {
    online = !isNetwork(error);
    if (["42501", "28000", "PGRST301", "PGRST303"].includes(error.code)) {
      blocked = error.message;
      secrets.removeItem("context");
    }
    throw Object.assign(new Error(error.message), error);
  }
  online = true;
  return data;
}
function pendingRows() {
  return db.db
    .prepare(
      "SELECT * FROM vendas_locais WHERE empresa_id=? AND estado_sync<>'sincronizada'",
    )
    .all(context.empresaId);
}
function products() {
  const all = db.db
    .prepare("SELECT dados_json FROM produtos_cache WHERE empresa_id=?")
    .all(context.empresaId)
    .map((r) => JSON.parse(r.dados_json));
  const quantities = new Map();
  for (const row of pendingRows())
    for (const i of JSON.parse(row.dados_json).itens || [])
      quantities.set(
        i.produto_id,
        (quantities.get(i.produto_id) || 0) + i.quantidade,
      );
  return all.map((p) => ({
    ...p,
    quantidade_estoque:
      Number(p.quantidade_estoque) - (quantities.get(p.id) || 0),
  }));
}
function snapshot() {
  return {
    context,
    caixa,
    online,
    blocked,
    lastSync,
    produtos: context ? products() : [],
    clientes: context
      ? db.db
          .prepare("SELECT dados_json FROM clientes_cache WHERE empresa_id=?")
          .all(context.empresaId)
          .map((r) => JSON.parse(r.dados_json))
      : [],
    atalhos: context ? cfg("atalhos:" + context.empresaId) || [] : [],
    pendencias: context ? db.resumoPendencias(context.empresaId) : {},
    erros: context
      ? pendingRows()
          .filter((r) => r.erro_sync)
          .map((r) => ({ numero: r.numero_local, mensagem: r.erro_sync }))
      : [],
    draft: context ? cfg("draft:" + context.userId) : null,
  };
}
function broadcast() {
  if (win && !win.isDestroyed())
    win.webContents.send("pdv:changed", snapshot());
}
async function refreshContext() {
  const next = await rpc("pdv_desktop_contexto");
  if (!next?.empresaId || !next?.userId)
    throw new Error("Perfil não confirmado.");
  if (
    context &&
    (context.empresaId !== next.empresaId || context.userId !== next.userId)
  )
    throw new Error("Sessão alterada. Reinicie o aplicativo.");
  context = next;
  blocked = null;
  secrets.setItem("context", JSON.stringify(next));
  online = true;
  return next;
}
async function loadCash() {
  caixa = await rpc("caixa_atual", { p_tipo: "PDV" });
  cfg("caixa:" + context.userId, caixa);
  return caixa;
}
async function catalog() {
  await refreshContext();
  const data = { empresaId: context.empresaId, produtos: [], clientes: [] };
  for (const recurso of ["produtos", "clientes"]) {
    let after = null;
    for (let n = 0; n < 2000; n++) {
      const page = await rpc("pdv_desktop_catalogo", {
        p_recurso: recurso,
        p_apos: after,
        p_limite: 500,
      });
      if (page.empresaId !== context.empresaId || !Array.isArray(page.itens))
        throw new Error("Catálogo inválido.");
      data[recurso].push(...page.itens);
      if (page.itens.length < 500) break;
      const last = page.itens.at(-1).id;
      if (last === after) throw new Error("Paginação inválida");
      after = last;
      if (n === 1999) throw new Error("Catálogo excedeu o limite.");
    }
  }
  const atalhos = await rpc("pdv_atalhos_listar");
  await loadCash();
  cfg("atalhos:" + context.empresaId, atalhos);
  return data;
}
function installSync() {
  sync = createSync({
    storage: db,
    empresaId: context.empresaId,
    transport: {
      async sendSale(v) {
        await refreshContext();
        if (v.dados.userId !== context.userId)
          throw new Error(
            "Entre com o operador que registrou esta venda para enviá-la.",
          );
        return rpc("pdv_desktop_sincronizar", {
          p_id_local: v.idLocal,
          p_caixa_id: v.dados.caixaId,
          p_pedido: v.dados,
          p_criada_em: v.criadaEm.endsWith("Z")
            ? v.criadaEm
            : v.criadaEm.replace(" ", "T") + "Z",
        });
      },
      receiveCatalog: catalog,
    },
    onStatus: (s) => {
      lastSync = s;
      broadcast();
    },
  });
  sync.start().catch((e) => {
    lastSync = { erros: [{ mensagem: e.message }] };
    online = false;
    broadcast();
  });
}
async function init() {
  db = openLocalDatabase(app.getPath("userData"));
  cfg("terminal", cfg("terminal") || crypto.randomUUID());
  client = createClient(config.url, config.key, {
    auth: {
      storage: secrets,
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
    },
    global: {
      fetch: (url, options) =>
        fetch(url, {
          ...options,
          signal: options?.signal || AbortSignal.timeout(15000),
        }),
    },
  });
  const saved = secrets.getItem("context");
  if (saved) {
    context = JSON.parse(saved);
    caixa = cfg("caixa:" + context.userId);
    try {
      await refreshContext();
      await loadCash();
    } catch (e) {
      if (!isNetwork(e)) {
        context = null;
        caixa = null;
        secrets.removeItem("context");
      } else online = false;
    }
    if (context) installSync();
  }
}
function needContext() {
  if (blocked) throw new Error(blocked);
  if (!context) throw new Error("Faça login para continuar.");
}
const handlers = {
  state: () => snapshot(),
  async login(input) {
    if (context) throw new Error("Já existe um operador conectado.");
    const response = await fetch(config.url + "/functions/v1/florest-login", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        apikey: config.key,
        authorization: "Bearer " + config.key,
      },
      body: JSON.stringify({
        empresa: input.empresa,
        usuario: input.usuario,
        senha: input.senha,
        superficie: "erp",
      }),
      signal: AbortSignal.timeout(20000),
    });
    const r = await response.json();
    if (!r.ok)
      throw new Error(r.mensagem || "Empresa, usuário ou senha inválidos.");
    const { error } = await client.auth.setSession(r.session);
    if (error) throw error;
    try {
      await refreshContext();
      await catalog().then((c) => db.atualizarCatalogo(context.empresaId, c));
      installSync();
      return snapshot();
    } catch (e) {
      context = null;
      secrets.removeItem("context");
      await client.auth.signOut({ scope: "local" });
      throw e;
    }
  },
  async sync(options) {
    needContext();
    await sync.run(options);
    return snapshot();
  },
  draft(draft) {
    needContext();
    cfg("draft:" + context.userId, draft);
    return true;
  },
  sale(input) {
    needContext();
    if (cashClosing) throw new Error("Aguarde o fechamento do caixa.");
    if (!caixa?.aberto || !caixa?.pode_operar)
      throw new Error("Abra o caixa antes de vender.");
    if (!/^[0-9a-f-]{36}$/i.test(input.operacao || ""))
      throw new Error("Operação inválida");
    const existing = db.db
      .prepare(
        "SELECT * FROM vendas_locais WHERE empresa_id=? AND chave_operacao=?",
      )
      .get(context.empresaId, input.operacao);
    if (existing) {
      const dados = JSON.parse(existing.dados_json);
      if (dados.userId !== context.userId)
        throw new Error("Operação de outro usuário");
      if (dados.solicitacao && dados.solicitacao !== JSON.stringify(input))
        throw new Error("Este identificador já foi utilizado em outro cupom.");
      return {
        idLocal: existing.id_local,
        numeroLocal: existing.numero_local,
        dados,
      };
    }
    const dados = validarVenda(input, products(), {
      ...context,
      caixaId: caixa.caixa.id,
    });
    if (
      dados.clienteId &&
      !db.db
        .prepare(
          "SELECT 1 FROM clientes_cache WHERE empresa_id=? AND cliente_id=?",
        )
        .get(context.empresaId, dados.clienteId)
    )
      throw new Error("Cliente não encontrado.");
    dados.solicitacao = JSON.stringify(input);
    const venda = db.registrarVenda({
      empresaId: context.empresaId,
      dados,
      chaveOperacao: input.operacao,
    });
    cfg("draft:" + context.userId, null);
    broadcast();
    sync.run().catch(() => {});
    return { ...venda, dados };
  },
  async cash(input) {
    needContext();
    if (input.action === "abrir") {
      caixa = await rpc("caixa_abrir", {
        p_tipo: "PDV",
        p_valor_inicial: input.valor,
      });
    } else if (input.action === "fechar") {
      if (cashClosing) throw new Error("Fechamento em andamento.");
      cashClosing = true;
      try {
        await sync.run();
        if (pendingRows().length)
          throw new Error(
            "Envie todas as vendas pendentes antes de fechar o caixa.",
          );
        await rpc("caixa_fechar", { p_caixa_id: caixa.caixa.id });
        await loadCash();
      } finally {
        cashClosing = false;
      }
    } else await loadCash();
    cfg("caixa:" + context.userId, caixa);
    broadcast();
    return caixa;
  },
  async remote({ name, args }) {
    needContext();
    const allowed = new Set([
      "pdv_comandas_listar",
      "pdv_comanda_abrir",
      "pdv_comanda_obter",
      "pdv_comanda_item_adicionar",
      "pdv_comanda_item_cancelar",
      "pdv_comanda_cancelar",
      "pdv_comanda_finalizar",
      "pdv_atalhos_salvar",
    ]);
    if (!allowed.has(name)) throw new Error("Operação indisponível");
    if (name === "pdv_comanda_obter") {
      const c = await rpc(name, args);
      if (c.sessao_id) cfg("comanda:" + context.userId + ":" + c.sessao_id, c);
      return c;
    }
    if (name === "pdv_comanda_finalizar") {
      const k = "comanda-chave:" + context.userId + ":" + args.p_sessao_id;
      const key = cfg(k) || cfg(k, crypto.randomUUID());
      args = { ...args, p_chave_idempotencia: key };
      const result = await rpc(name, args);
      const c = cfg("comanda:" + context.userId + ":" + args.p_sessao_id);
      if (!c)
        throw new Error(
          "Venda finalizada no ERP. Atualize o histórico no navegador para imprimir.",
        );
      const d = {
        itens: c.itens.map((i) => ({
          produto_id: i.produto_id,
          nome: i.produto_nome,
          quantidade: Number(i.quantidade),
          preco_unitario: Number(i.preco_unitario),
        })),
        total: Number(result.total ?? c.total),
        clienteId: c.cliente_id,
        prazo: args.p_nota_prazo,
        pagamentos: args.p_pagamentos || [],
        userId: context.userId,
        caixaId: caixa?.caixa?.id,
      };
      const v = db.registrarVenda({
        empresaId: context.empresaId,
        dados: d,
        chaveOperacao: key,
      });
      db.confirmarSincronizacao({
        empresaId: context.empresaId,
        idLocal: v.idLocal,
        idRemoto: result.venda_id,
      });
      sync.run().catch(() => {});
      return { ...result, idLocal: v.idLocal };
    }
    const data = await rpc(name, args);
    if (name === "pdv_atalhos_salvar")
      cfg("atalhos:" + context.empresaId, await rpc("pdv_atalhos_listar"));
    return data;
  },
  async print(idLocal) {
    needContext();
    const row = db.db
      .prepare("SELECT * FROM vendas_locais WHERE empresa_id=? AND id_local=?")
      .get(context.empresaId, idLocal);
    if (!row) throw new Error("Comprovante não encontrado.");
    const { receiptHtml } = require("./receipt.cjs");
    const printer = new BrowserWindow({
      show: false,
      webPreferences: {
        sandbox: true,
        nodeIntegration: false,
        contextIsolation: true,
      },
    });
    try {
      await printer.loadURL(
        "data:text/html;charset=utf-8," +
          encodeURIComponent(receiptHtml(context, row)),
      );
      return await new Promise((resolve, reject) =>
        printer.webContents.print(
          {
            silent: false,
            printBackground: false,
            margins: { marginType: "none" },
          },
          (ok, reason) =>
            ok
              ? resolve(true)
              : reason === "cancelled"
                ? resolve(false)
                : reject(new Error(reason || "Falha na impressão")),
        ),
      );
    } finally {
      printer.destroy();
    }
  },
  history() {
    needContext();
    return db.db
      .prepare(
        "SELECT id_local,numero_local,criada_em,estado_sync,erro_sync,id_remoto,dados_json FROM vendas_locais WHERE empresa_id=? ORDER BY numero_local DESC LIMIT 100",
      )
      .all(context.empresaId)
      .map((r) => ({ ...r, total: JSON.parse(r.dados_json).total }));
  },
};
function createWindow() {
  win = new BrowserWindow({
    width: 1366,
    height: 900,
    minWidth: 1024,
    minHeight: 720,
    title: "Florest PDV",
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  win.webContents.on("will-navigate", (e) => e.preventDefault());
  if (smokeTest) {
    const timer = setTimeout(() => app.exit(2), 30000);
    win.webContents.once("did-finish-load", async () => {
      try {
        const valid = await win.webContents.executeJavaScript(
          `document.title === 'Florest PDV' && typeof window.florestDesktop.sale === 'function' && !!document.getElementById('login-form') && !document.getElementById('btn-sair-pdv')`,
        );
        if (!valid || !db.db.prepare("SELECT 1 AS n").get().n)
          throw new Error("Falha no smoke test desktop");
        clearTimeout(timer);
        console.log("FLOREST_DESKTOP_SMOKE_OK");
        app.exit(0);
      } catch (error) {
        console.error(error.message);
        app.exit(1);
      }
    });
  }
  win.loadFile(path.join(__dirname, "renderer", "index.html"));
}
if (lock) {
  app.on("second-instance", () => {
    if (win) {
      win.restore();
      win.focus();
    }
  });
  app
    .whenReady()
    .then(async () => {
      await init();
      for (const [name, handler] of Object.entries(handlers))
        ipcMain.handle("pdv:" + name, async (event, arg) => {
          if (
            event.sender !== win.webContents ||
            event.senderFrame !== win.webContents.mainFrame
          )
            throw new Error("Origem inválida");
          return handler(arg);
        });
      createWindow();
    })
    .catch((e) => {
      if (smokeTest) {
        console.error(e.message);
        app.exit(1);
        return;
      }
      dialog.showErrorBox("Florest PDV", e.message);
      app.quit();
    });
  app.on("window-all-closed", () => app.quit());
  app.on("before-quit", (e) => {
    if (quitting) return;
    e.preventDefault();
    quitting = true;
    (async () => {
      if (sync) await sync.stop();
      client?.auth.stopAutoRefresh();
      db?.fechar();
      app.exit(0);
    })().catch(() => app.exit(1));
  });
}

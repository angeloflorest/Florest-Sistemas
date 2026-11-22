"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { createSync } = require("../src/sync.cjs");
test('rodadas automáticas enviam vendas sem baixar catálogo completo a cada 15 segundos',async()=>{
 const f=fixture();let clock=1000,sends=0,receives=0;
 f.storage.pendentes=()=>[{id_local:'a',numero_local:1,dados_json:'{}'}];
 f.transport.sendSale=async v=>{sends++;return{...v,idRemoto:'r'}};
 f.transport.receiveCatalog=async()=>{receives++;return{empresaId:'empresa-a',produtos:[],clientes:[]}};
 const sync=createSync({...f,empresaId:'empresa-a',now:()=>clock});
 for(let n=0;n<4;n++){await sync.run({automatico:true});clock+=15000;}
 assert.equal(sends,4);assert.equal(receives,1);
 await sync.run({automatico:true});assert.equal(receives,2);
 await sync.run();assert.equal(receives,3);await sync.stop();
});
test('falha do catálogo tem espera progressiva sem bloquear envios nem atualização manual',async()=>{
 const f=fixture();let clock=1000,calls=0;
 f.transport.receiveCatalog=async()=>{calls++;throw Error('offline')};
 const sync=createSync({...f,empresaId:'empresa-a',now:()=>clock});
 await sync.run({automatico:true});assert.equal(f.confirmations.length,1);
 clock+=15000;await sync.run({automatico:true});assert.equal(calls,1);
 clock+=15000;await sync.run({automatico:true});assert.equal(calls,2);
 clock+=30000;await sync.run({automatico:true});assert.equal(calls,2);
 await sync.run();assert.equal(calls,3);await sync.stop();
});
function fixture() {
  const rows = [{ id_local: "a", numero_local: 1, dados_json: '{"total":10}' }];
  const confirmations = [],
    errors = [],
    catalogs = [];
  const storage = {
    pendentes: () =>
      rows.filter((r) => !confirmations.some((c) => c.idLocal === r.id_local)),
    confirmarSincronizacao: (c) => confirmations.push(c),
    registrarErro: (e) => errors.push(e),
    atualizarCatalogo: (...args) => catalogs.push(args),
    resumoPendencias: () => ({ pendente: rows.length - confirmations.length }),
  };
  const transport = {
    sendSale: async (v) => ({
      empresaId: v.empresaId,
      idLocal: v.idLocal,
      idRemoto: "remote-a",
    }),
    receiveCatalog: async () => ({
      empresaId: "empresa-a",
      produtos: [],
      clientes: [],
    }),
  };
  return { storage, transport, confirmations, errors, catalogs };
}
test("confirma apenas a venda e empresa recebidas e recebe catálogo", async () => {
  const f = fixture(),
    sync = createSync({ ...f, empresaId: "empresa-a" });
  const result = await sync.run();
  assert.equal(result.enviados, 1);
  assert.equal(f.confirmations.length, 1);
  assert.equal(f.catalogs.length, 1);
  await sync.run();
  assert.equal(f.confirmations.length, 1);
  await sync.stop();
});
test("resposta perdida mantém mesmo UUID no reenvio", async () => {
  const f = fixture(),
    ids = [];
  let primeira = true;
  f.transport.sendSale = async (v) => {
    ids.push(v.idLocal);
    if (primeira) {
      primeira = false;
      throw new Error("Resposta perdida");
    }
    return { ...v, idRemoto: "remote-a" };
  };
  const sync = createSync({ ...f, empresaId: "empresa-a" });
  assert.equal((await sync.run()).enviados, 0);
  assert.equal((await sync.run()).enviados, 1);
  assert.deepEqual(ids, ["a", "a"]);
  assert.equal(f.errors.length, 1);
  await sync.stop();
});
test("confirmações e catálogos de outra empresa são recusados", async () => {
  const f = fixture();
  f.transport.sendSale = async () => ({
    empresaId: "empresa-b",
    idLocal: "a",
    idRemoto: "x",
  });
  f.transport.receiveCatalog = async () => ({
    empresaId: "empresa-b",
    produtos: [],
    clientes: [],
  });
  const sync = createSync({ ...f, empresaId: "empresa-a" });
  const result = await sync.run();
  assert.equal(result.erros.length, 2);
  assert.equal(f.confirmations.length, 0);
  assert.equal(f.catalogs.length, 0);
  await sync.stop();
});
test("botões e rodada automática simultâneos não enviam duas vezes", async () => {
  const f = fixture();
  let release,
    calls = 0;
  f.transport.sendSale = (v) => {
    calls++;
    return new Promise((resolve) => {
      release = () => resolve({ ...v, idRemoto: "remote-a" });
    });
  };
  const sync = createSync({ ...f, empresaId: "empresa-a" });
  const first = sync.run(),
    second = sync.run();
  assert.equal(first, second);
  release();
  await first;
  assert.equal(calls, 1);
  await sync.stop();
  await assert.rejects(sync.run(), /encerrada/);
});

test('Enviar durante recebimento aguarda e executa o envio solicitado', async () => {
  const f=fixture();let release;let receives=0;
  f.transport.receiveCatalog=()=>{receives++;return new Promise(resolve=>{release=()=>resolve({empresaId:'empresa-a',produtos:[],clientes:[]});});};
  const sync=createSync({...f,empresaId:'empresa-a'});
  const first=sync.run({enviar:false,receber:true});
  const send=sync.run({enviar:true,receber:false});
  release();await first;await send;
  assert.equal(f.confirmations.length,1);assert.equal(receives,1);await sync.stop();
});

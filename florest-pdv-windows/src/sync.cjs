"use strict";

// O transporte deve usar a sessão autenticada e um endpoint idempotente.
// Nunca usar registrar_venda_mista diretamente: uma resposta perdida duplicaria a venda.
function createSync({
  storage,
  transport,
  empresaId,
  intervalMs = 60000,
  onStatus = () => {},
}) {
  if (!empresaId || !storage || !transport)
    throw new Error("Sincronização incompleta");
  let running = null;
  let timer = null;
  let stopped = false;
  const report = (status) => {
    try {
      onStatus(status);
    } catch {}
  };

  async function execute({ enviar = true, receber = true } = {}) {
    const status = { empresaId, enviados: 0, recebidos: 0, erros: [] };
    if (enviar) {
      // Um lote por rodada mantém a interface responsiva; próxima rodada retoma a fila.
      for (const venda of storage.pendentes(empresaId, 50)) {
        if (stopped) break;
        try {
          const result = await transport.sendSale({
            empresaId,
            idLocal: venda.id_local,
            numeroLocal: venda.numero_local,
            criadaEm: venda.criada_em,
            dados: JSON.parse(venda.dados_json),
          });
          if (
            !result ||
            result.idLocal !== venda.id_local ||
            result.empresaId !== empresaId ||
            !result.idRemoto
          )
            throw new Error("Servidor não confirmou a mesma venda e empresa");
          storage.confirmarSincronizacao({
            empresaId,
            idLocal: venda.id_local,
            idRemoto: result.idRemoto,
          });
          status.enviados++;
        } catch (error) {
          const mensagem = String(error.message || error);
          storage.registrarErro({
            empresaId,
            idLocal: venda.id_local,
            mensagem,
          });
          status.erros.push({ idLocal: venda.id_local, mensagem });
          // Falha de rede ou autorização: não bombardear o servidor com o restante da fila.
          break;
        }
      }
    }
    if (receber && !stopped) {
      try {
        const catalogo = await transport.receiveCatalog({ empresaId });
        if (!catalogo || catalogo.empresaId !== empresaId)
          throw new Error("Catálogo de outra empresa");
        storage.atualizarCatalogo(empresaId, catalogo);
        status.recebidos = catalogo.produtos.length + catalogo.clientes.length;
      } catch (error) {
        status.erros.push({ mensagem: String(error.message || error) });
      }
    }
    status.pendencias = storage.resumoPendencias(empresaId);
    report(status);
    return status;
  }

  function run(options) {
    if (stopped) return Promise.reject(new Error("Sincronização encerrada"));
    // Chamadas simultâneas, inclusive dos botões, compartilham a execução atual.
    if (!running)
      running = execute(options).finally(() => {
        running = null;
      });
    return running;
  }
  function start() {
    if (stopped) throw new Error("Sincronização encerrada");
    if (!timer) {
      timer = setInterval(
        () => {
          run().catch((error) =>
            report({ erros: [{ mensagem: error.message }] }),
          );
        },
        Math.max(1000, intervalMs),
      );
      timer.unref?.();
    }
    return run();
  }
  async function stop() {
    stopped = true;
    if (timer) clearInterval(timer);
    timer = null;
    if (running) await running;
  }
  return { run, start, stop };
}

module.exports = { createSync };

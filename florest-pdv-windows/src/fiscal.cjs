"use strict";
function createFiscal({rpc, client, getContext, storage, sync}) {
  const running = new Map();
  async function execute(idLocal) {
    const context = getContext();
    if (!context?.empresaId) throw new Error("Faça login.");
    const company = context.empresaId;
    const row = storage.db.prepare("SELECT * FROM vendas_locais WHERE empresa_id=? AND id_local=?").get(company,idLocal);
    if (!row) throw new Error("Venda não encontrada.");
    const permission = await rpc("fiscal_emissao_caixa_obter");
    if (permission?.empresa_id !== company || permission.emite_nota_fiscal !== true)
      throw new Error("Emissão fiscal não habilitada para esta empresa.");
    // Nunca enfileira emissão automática. Cada tentativa vem de uma ação do operador.
    await sync();
    const sale = storage.db.prepare("SELECT * FROM vendas_locais WHERE empresa_id=? AND id_local=?").get(company,idLocal);
    if (!sale?.id_remoto || sale.estado_sync !== "sincronizada")
      throw new Error("Venda preservada. Aguarde a sincronização para emitir a NFC-e.");
    const contingency = await rpc("fiscal_contingencia_status");
    if (contingency?.ativa) throw new Error("Contingência fiscal ativa. Emita posteriormente pelo ERP; o Windows não emite NFC-e offline.");
    if (getContext()?.empresaId !== company) throw new Error("Sessão alterada.");
    const docs = await rpc("fiscal_emitir_nota", {p_venda_id:sale.id_remoto});
    const nfces = (docs || []).filter(d=>d.tipo_documento === "nfce");
    const doc = nfces.find(d=> !["rejeitada","cancelada"].includes(d.status)) || nfces.at(-1);
    if (!doc) throw new Error("Venda sem mercadoria para NFC-e.");
    if (doc.status === "autorizada") return {status:"autorizada",mensagem:"NFC-e já autorizada. Consulte e imprima na tela Fiscal do ERP."};
    const {data,error} = await client.functions.invoke("fiscal-emitir-documento", {body:{documento_fiscal_id:doc.id}});
    if (error || data?.error) throw new Error(data?.error || "Emissão não confirmada. Consulte a situação no ERP antes de tentar novamente.");
    return data || {status:"processando"};
  }
  return {emit(id) {
    if (running.has(id)) return running.get(id);
    const work=execute(id).finally(()=>running.delete(id)); running.set(id,work); return work;
  }};
}
module.exports={createFiscal};

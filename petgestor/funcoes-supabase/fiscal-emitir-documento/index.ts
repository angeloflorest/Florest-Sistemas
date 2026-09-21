// Edge Function: fiscal-emitir-documento
//
// Fluxo (HOMOLOGAÇÃO — tpAmb "2", async false, tpDanfe Cupom):
//   1. Valida usuário autenticado + empresa (via RLS).
//   2. Trava atômica: evita duas emissões simultâneas da mesma venda,
//      e nunca re-emite um documento já autorizado.
//   3. Confirma que o emitente já está registrado na Dados Jah.
//   4. Obtém (ou renova) o token de USUÁRIO daquela empresa.
//   5. Monta o payload da NFC-e (omitindo "emit", já pré-cadastrado),
//      só com dados reais — nada de valores fiscais fictícios.
//   6. Chama POST /v1/nfce?tpDanfe=Cupom com timeout de ~60s.
//   7. Interpreta cStat/situationDfe/xMotivo/nProt/chDfe com uma função
//      central — nunca conclui "autorizada" sem evidência completa.
//   8. Grava o resultado (+ evento de auditoria) e responde ao frontend
//      sem nenhum dado sensível (token, payload completo).

import {
  DADOSJAH_BASE_URL,
  CODIGO_UF,
  criarClienteAdmin,
  criarClienteUsuario,
  jsonResponse,
  interpretarRetornoFiscal,
  agoraISOComOffsetBrasilia,
  codigoFormaPagamento,
  somenteDigitos,
  formatarValorMonetario,
} from "./dadosjah.ts";

const TP_AMB = "2"; // HOMOLOGAÇÃO — fixo nesta etapa.

async function obterTokenUsuario(admin: ReturnType<typeof criarClienteAdmin>, empresaId: string): Promise<string | null> {
  const { data: cred } = await admin
    .from("dadosjah_credenciais")
    .select("dadosjah_email, dadosjah_token, dadosjah_token_expires_at")
    .eq("empresa_id", empresaId)
    .single();

  if (!cred) return null;

  const margemSegundos = 60;
  const aindaValido =
    cred.dadosjah_token &&
    cred.dadosjah_token_expires_at &&
    new Date(cred.dadosjah_token_expires_at).getTime() - margemSegundos * 1000 > Date.now();

  if (aindaValido) return cred.dadosjah_token as string;

  const { data: credenciaisPlano } = await admin
    .rpc("dadosjah_obter_credenciais", { p_empresa_id: empresaId })
    .single();
  const senha = (credenciaisPlano as { senha?: string } | null)?.senha;
  if (!senha) return null;

  const resp = await fetch(`${DADOSJAH_BASE_URL}/auth/user/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ email: cred.dadosjah_email, password: senha }),
  });
  if (!resp.ok) return null;

  const json = await resp.json();
  const token = json?.data?.accessToken;
  const expiresAt = json?.data?.expiresAt ?? null;
  if (!token) return null;

  await admin
    .from("dadosjah_credenciais")
    .update({ dadosjah_token: token, dadosjah_token_expires_at: expiresAt })
    .eq("empresa_id", empresaId);

  return token as string;
}

Deno.serve(async (req: Request) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Método não permitido." }, 405);
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return jsonResponse({ error: "Não autenticado." }, 401);

    const supabaseUser = criarClienteUsuario(authHeader);
    const { data: userData, error: userError } = await supabaseUser.auth.getUser();
    if (userError || !userData?.user) {
      return jsonResponse({ error: "Sessão inválida." }, 401);
    }

    const { data: perfil } = await supabaseUser.from("perfis").select("empresa_id").single();
    if (!perfil?.empresa_id) {
      return jsonResponse({ error: "Usuário sem empresa vinculada." }, 403);
    }
    const empresaId = perfil.empresa_id as string;

    const body = await req.json().catch(() => null);
    const documentoFiscalId = body?.documento_fiscal_id;
    if (!documentoFiscalId) {
      return jsonResponse({ error: "Informe documento_fiscal_id." }, 400);
    }

    // Busca com RLS (respeitando empresa) — se pertencer a outra empresa, vem vazio.
    const { data: documento, error: docError } = await supabaseUser
      .from("documentos_fiscais")
      .select(`
        *,
        vendas ( id, numero_venda, cliente_id, forma_pagamento, total, clientes ( nome, cpf, cep, logradouro, numero, bairro, cidade, uf ) )
      `)
      .eq("id", documentoFiscalId)
      .single();

    if (docError || !documento) {
      return jsonResponse({ error: "Documento fiscal não encontrado para esta empresa." }, 404);
    }

    if (documento.tipo_documento !== "nfce") {
      return jsonResponse({ error: "Esta função emite apenas NFC-e nesta etapa." }, 400);
    }

    const { data: config } = await supabaseUser.from("configuracoes_fiscais").select("*").single();
    if (!config) {
      return jsonResponse({ error: "Configurações fiscais não encontradas." }, 422);
    }
    if (!config.emitente_registrado) {
      return jsonResponse({ error: "O emitente ainda não foi registrado na Dados Jah. Conclua a configuração fiscal primeiro." }, 422);
    }

    const respTecCnpj = Deno.env.get("RESPTEC_CNPJ");
    const respTecContato = Deno.env.get("RESPTEC_CONTATO");
    const respTecEmail = Deno.env.get("RESPTEC_EMAIL");
    const respTecFone = Deno.env.get("RESPTEC_FONE");
    if (!respTecCnpj || !respTecContato || !respTecEmail || !respTecFone) {
      return jsonResponse(
        { error: "Dados do responsável técnico não configurados (Secrets RESPTEC_CNPJ / RESPTEC_CONTATO / RESPTEC_EMAIL / RESPTEC_FONE)." },
        500
      );
    }

    const admin = criarClienteAdmin();

    // ------------------------------------------------------------
    // Trava atômica: só avança se conseguir passar o status para "processando"
    // partindo de "nao_emitida" ou "rejeitada". Isso impede duas requisições
    // simultâneas emitirem a mesma venda duas vezes.
    // ------------------------------------------------------------
    const { data: travado, error: travaError } = await admin
      .from("documentos_fiscais")
      .update({ status: "processando", updated_at: new Date().toISOString() })
      .eq("id", documentoFiscalId)
      .eq("empresa_id", empresaId)
      .in("status", ["nao_emitida", "rejeitada"])
      .select()
      .maybeSingle();

    if (travaError) {
      console.error("Erro ao travar documento:", documentoFiscalId);
      return jsonResponse({ error: "Erro interno ao iniciar a emissão." }, 500);
    }

    if (!travado) {
      // Não conseguiu travar — ou já está autorizado, ou já está processando agora.
      const { data: atual } = await admin.from("documentos_fiscais").select("status, numero, chave_acesso, protocolo").eq("id", documentoFiscalId).single();
      if (atual?.status === "autorizada") {
        return jsonResponse({ status: "autorizada", jaAutorizada: true, numero: atual.numero, chaveAcesso: atual.chave_acesso, protocolo: atual.protocolo });
      }
      return jsonResponse({ error: "Esta emissão já está em processamento. Aguarde." }, 409);
    }

    // ------------------------------------------------------------
    // Numeração fiscal própria (nunca reaproveita numero_venda)
    // ------------------------------------------------------------
    const serie = config.nfce_serie || "1";
    const { data: proximoNumero, error: numeroError } = await admin.rpc("fiscal_proximo_numero", {
      p_empresa_id: empresaId,
      p_tipo_documento: "nfce",
      p_serie: serie,
    });

    if (numeroError || !proximoNumero) {
      await admin.from("documentos_fiscais").update({ status: "rejeitada", mensagem_rejeicao: "Erro ao gerar numeração fiscal." }).eq("id", documentoFiscalId);
      return jsonResponse({ error: "Erro ao gerar o número fiscal." }, 500);
    }

    // ------------------------------------------------------------
    // Itens: só os de tipo_fiscal = produto entram na NFC-e (serviço vai para NFS-e, etapa futura)
    // ------------------------------------------------------------
    const { data: itens } = await supabaseUser
      .from("itens_venda")
      .select("quantidade, preco_unitario, subtotal, produtos ( nome, codigo, gtin, ncm, cest, cfop, unidade_comercial, origem_mercadoria, cst_csosn, cst_pis, cst_cofins, tipo_fiscal )")
      .eq("venda_id", documento.venda_id);

    const itensProduto = (itens || []).filter((i: any) => (i.produtos?.tipo_fiscal ?? "produto") === "produto");

    if (itensProduto.length === 0) {
      await admin.from("documentos_fiscais").update({ status: "nao_emitida", mensagem_rejeicao: null }).eq("id", documentoFiscalId);
      return jsonResponse({ error: "Esta venda não possui itens de mercadoria para gerar NFC-e." }, 422);
    }

    const venda = documento.vendas;
    const cliente = venda?.clientes;

    const det = itensProduto.map((item: any, index: number) => {
      const p = item.produtos;
      const qtd = Number(item.quantidade);
      const prod: Record<string, unknown> = {
        cProd: p.codigo || p.nome,
        cEAN: p.gtin || "SEM GTIN",
        xProd: p.nome,
        NCM: p.ncm,
        CFOP: p.cfop,
        uCom: p.unidade_comercial || "UN",
        qCom: qtd.toFixed(4),
        vUnCom: Number(item.preco_unitario).toFixed(2),
        vProd: Number(item.subtotal).toFixed(2),
        cEANTrib: p.gtin || "SEM GTIN",
        uTrib: p.unidade_comercial || "UN",
        qTrib: qtd.toFixed(4),
        vUnTrib: Number(item.preco_unitario).toFixed(2),
        indTot: "1",
      };
      if (p.cest) prod.CEST = p.cest;

      const imposto: Record<string, unknown> = {};
      if (p.cst_csosn) {
        imposto.ICMS = { orig: p.origem_mercadoria || "0", CST: p.cst_csosn };
      }
      if (p.cst_pis) imposto.PIS = { CST: p.cst_pis };
      if (p.cst_cofins) imposto.COFINS = { CST: p.cst_cofins };

      return { nItem: String(index + 1), prod, imposto };
    });

    const vNF = itensProduto.reduce((soma: number, i: any) => soma + Number(i.subtotal), 0);

    let dest: Record<string, unknown> | undefined;
    if (cliente?.cpf) {
      const cpfDigits = somenteDigitos(cliente.cpf);
      dest = {
        CNPJCPF: cpfDigits,
        xNome: cliente.nome,
        indIEDest: "9",
      };
      if (cliente.logradouro) {
        dest.enderDest = {
          xLgr: cliente.logradouro,
          nro: cliente.numero || "S/N",
          xBairro: cliente.bairro || "",
          cMun: config.codigo_ibge,
          xMun: cliente.cidade || config.municipio,
          UF: cliente.uf || config.uf,
          CEP: somenteDigitos((cliente as any).cep) || undefined,
          cPais: "1058",
          xPais: "BRASIL",
        };
      }
    }

    const cUF = CODIGO_UF[config.uf] || "35";
    const cNF = String(Math.floor(Math.random() * 99999999)).padStart(8, "0");

    const infNF: Record<string, unknown> = {
      versao: "4.00",
      ide: {
        cUF,
        cNF,
        natOp: "Venda ao consumidor",
        serie,
        nNF: String(proximoNumero),
        dhEmi: agoraISOComOffsetBrasilia(),
        tpNF: "1",
        idDest: "1",
        cMunFG: config.codigo_ibge,
        tpImp: "4",
        tpEmis: "1",
        tpAmb: TP_AMB,
        finNFe: "1",
        indFinal: "1",
        indPres: "1",
        procEmi: "0",
        verProc: "PetGestor 1.0",
      },
      // "emit" omitido de propósito: o emitente já está pré-cadastrado via /v1/emit.
      det,
      total: {
        ICMSTot: {
          vBC: "0.00",
          vICMS: "0.00",
          vICMSDeson: "0.00",
          vFCP: "0.00",
          vBCST: "0.00",
          vFCPST: "0.00",
          vFCPSTRet: "0.00",
          vProd: formatarValorMonetario(vNF),
          vFrete: "0.00",
          vSeg: "0.00",
          vDesc: "0.00",
          vII: "0.00",
          vIPI: "0.00",
          vIPIDevol: "0.00",
          vPIS: "0.00",
          vCOFINS: "0.00",
          vOutro: "0.00",
          vNF: formatarValorMonetario(vNF),
        },
      },
      pag: {
        detPag: [
          {
            tPag: codigoFormaPagamento(venda?.forma_pagamento || ""),
            xPag: venda?.forma_pagamento || "",
            vPag: formatarValorMonetario(Number(documento.valor)),
          },
        ],
      },
      infRespTec: {
        CNPJ: somenteDigitos(respTecCnpj),
        xContato: respTecContato,
        email: respTecEmail,
        fone: somenteDigitos(respTecFone),
      },
    };
    if (dest) infNF.dest = dest;

    const payload = {
      async: false,
      NFCe: [
        {
          idExternal: documentoFiscalId,
          infNF,
        },
      ],
    };

    // ------------------------------------------------------------
    // Autenticação da empresa + chamada real (timeout de 60s)
    // ------------------------------------------------------------
    const tokenUsuario = await obterTokenUsuario(admin, empresaId);
    if (!tokenUsuario) {
      await admin.from("documentos_fiscais").update({ status: "rejeitada", mensagem_rejeicao: "Falha de autenticação com a Dados Jah." }).eq("id", documentoFiscalId);
      await admin.from("documentos_fiscais_eventos").insert({ documento_fiscal_id: documentoFiscalId, empresa_id: empresaId, status: "rejeitada", x_motivo: "Falha de autenticação." });
      return jsonResponse({ error: "Não foi possível autenticar a empresa na Dados Jah." }, 502);
    }

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 60_000);

    let respostaFetch: Response;
    try {
      respostaFetch = await fetch(`${DADOSJAH_BASE_URL}/nfce?tpDanfe=Cupom`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          Authorization: `Bearer ${tokenUsuario}`,
        },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
    } catch (fetchErr) {
      clearTimeout(timeoutId);
      const motivo = (fetchErr as Error)?.name === "AbortError" ? "Tempo esgotado aguardando a SEFAZ." : "Falha de comunicação com a Dados Jah.";
      await admin.from("documentos_fiscais").update({ status: "rejeitada", mensagem_rejeicao: motivo }).eq("id", documentoFiscalId);
      await admin.from("documentos_fiscais_eventos").insert({ documento_fiscal_id: documentoFiscalId, empresa_id: empresaId, status: "rejeitada", x_motivo: motivo });
      return jsonResponse({ error: "Não foi possível concluir a emissão. Tente novamente ou verifique a configuração fiscal." }, 504);
    }
    clearTimeout(timeoutId);

    if (!respostaFetch.ok) {
      console.error("Dados Jah respondeu erro na emissão. Empresa:", empresaId, "Status HTTP:", respostaFetch.status);
      await admin.from("documentos_fiscais").update({ status: "rejeitada", mensagem_rejeicao: `Erro HTTP ${respostaFetch.status} na emissão.` }).eq("id", documentoFiscalId);
      await admin.from("documentos_fiscais_eventos").insert({ documento_fiscal_id: documentoFiscalId, empresa_id: empresaId, status: "rejeitada", x_motivo: `HTTP ${respostaFetch.status}` });
      return jsonResponse({ error: "Não foi possível concluir a emissão. Tente novamente ou verifique a configuração fiscal." }, 502);
    }

    const respostaJson = await respostaFetch.json();
    const itemResposta = respostaJson?.data?.NFCe?.[0];

    if (!itemResposta) {
      await admin.from("documentos_fiscais").update({ status: "rejeitada", mensagem_rejeicao: "Resposta inesperada da Dados Jah." }).eq("id", documentoFiscalId);
      await admin.from("documentos_fiscais_eventos").insert({ documento_fiscal_id: documentoFiscalId, empresa_id: empresaId, status: "rejeitada", x_motivo: "Resposta inesperada." });
      return jsonResponse({ error: "Resposta inesperada da Dados Jah." }, 502);
    }

    const resultado = interpretarRetornoFiscal(itemResposta);

    await admin
      .from("documentos_fiscais")
      .update({
        status: resultado.status,
        id_dfe: itemResposta.idDfe ?? null,
        tp_ambiente: itemResposta.tpAmb ?? TP_AMB,
        numero: itemResposta.nNF ?? String(proximoNumero),
        serie: itemResposta.serie ?? serie,
        chave_acesso: itemResposta.chDfe ?? null,
        protocolo: itemResposta.nProt ?? null,
        c_stat: resultado.cStat,
        mensagem_rejeicao: resultado.status === "rejeitada" ? resultado.xMotivo : null,
        dh_emissao: itemResposta.dhEmi ?? null,
        dh_recebimento: itemResposta.dhRecbto ?? null,
        situation: itemResposta.situation ?? null,
        situation_dfe: itemResposta.situationDfe ?? null,
        xml_conteudo: itemResposta.xml ?? null,
        pdf_conteudo: itemResposta.pdf ?? null,
        xml_url: itemResposta.xmlLink || null,
        pdf_url: itemResposta.pdfLink || null,
        updated_at: new Date().toISOString(),
      })
      .eq("id", documentoFiscalId);

    await admin.from("documentos_fiscais_eventos").insert({
      documento_fiscal_id: documentoFiscalId,
      empresa_id: empresaId,
      status: resultado.status,
      c_stat: resultado.cStat,
      x_motivo: resultado.xMotivo,
    });

    return jsonResponse({
      status: resultado.status,
      cStat: resultado.cStat,
      xMotivo: resultado.xMotivo,
      numero: itemResposta.nNF ?? null,
      chaveAcesso: itemResposta.chDfe ?? null,
      temXml: !!(itemResposta.xml || itemResposta.xmlLink),
      temPdf: !!(itemResposta.pdf || itemResposta.pdfLink),
    });
  } catch (err) {
    console.error("Erro em fiscal-emitir-documento:", (err as Error)?.message);
    return jsonResponse({ error: "Não foi possível concluir a emissão. Tente novamente ou verifique a configuração fiscal." }, 500);
  }
});

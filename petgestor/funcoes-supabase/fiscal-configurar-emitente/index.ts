// Edge Function: fiscal-configurar-emitente
//
// Executa (uma vez por empresa, quando ainda não feito):
//   1. Cria o "usuário" dessa empresa na Dados Jah (POST /v1/user),
//      autenticado com o token de SISTEMA (Florest Sistemas).
//   2. Registra o emitente dessa empresa (POST /v1/emit),
//      autenticado com o token de USUÁRIO daquela empresa.
//
// Nunca usa o token de Sistema para operações fiscais de um cliente,
// e nunca usa o token de um cliente para operações administrativas.

import {
  DADOSJAH_BASE_URL,
  criarClienteAdmin,
  criarClienteUsuario,
  jsonResponse,
  somenteDigitos,
} from "./dadosjah.ts";

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

    const { data: config, error: configError } = await supabaseUser
      .from("configuracoes_fiscais")
      .select("*")
      .single();

    if (configError || !config) {
      return jsonResponse(
        { error: "Preencha e salve as Configurações Fiscais da empresa antes de continuar." },
        422
      );
    }

    const camposObrigatorios = ["razao_social", "cnpj", "cep", "endereco", "numero", "bairro", "municipio", "uf", "codigo_ibge"];
    const faltando = camposObrigatorios.filter((c) => !config[c]);
    if (faltando.length > 0) {
      return jsonResponse(
        { error: `Preencha os seguintes campos em Configurações Fiscais antes de continuar: ${faltando.join(", ")}.` },
        422
      );
    }

    const admin = criarClienteAdmin();

    // ---------------------------------------------------------
    // Etapa 1: criar o usuário dessa empresa na Dados Jah (se ainda não existe)
    // ---------------------------------------------------------
    if (!config.dadosjah_usuario_criado) {
      const emailDadosJah = `fiscal+${empresaId}@petgestor.florestsistemas.com.br`;
      const senhaGerada = crypto.randomUUID() + crypto.randomUUID();

      const sistemaEmail = Deno.env.get("DADOSJAH_SYSTEM_EMAIL");
      const sistemaSenha = Deno.env.get("DADOSJAH_SYSTEM_PASSWORD");
      if (!sistemaEmail || !sistemaSenha) {
        return jsonResponse(
          { error: "Credenciais de Sistema da Dados Jah não configuradas (Secrets DADOSJAH_SYSTEM_EMAIL / DADOSJAH_SYSTEM_PASSWORD)." },
          500
        );
      }

      const loginSistemaResp = await fetch(`${DADOSJAH_BASE_URL}/auth/system/login`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ email: sistemaEmail, password: sistemaSenha }),
      });

      if (!loginSistemaResp.ok) {
        console.error("Falha no login de Sistema na Dados Jah. Status:", loginSistemaResp.status);
        return jsonResponse({ error: "Não foi possível autenticar como Sistema na Dados Jah." }, 502);
      }

      const loginSistemaJson = await loginSistemaResp.json();
      const tokenSistema = loginSistemaJson?.data?.accessToken;
      if (!tokenSistema) {
        return jsonResponse({ error: "Resposta inesperada da Dados Jah ao autenticar o Sistema." }, 502);
      }

      const criarUsuarioResp = await fetch(`${DADOSJAH_BASE_URL}/user`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          Authorization: `Bearer ${tokenSistema}`,
        },
        body: JSON.stringify({
          name: config.razao_social,
          cnpj: somenteDigitos(config.cnpj),
          email: emailDadosJah,
          idExternal: empresaId,
          password: senhaGerada,
          nfceCSC: config.nfce_csc ?? undefined,
          nfceIdCSC: config.nfce_id_csc ?? undefined,
          nfceVersaoQRCode: config.nfce_versao_qrcode ?? undefined,
          notification: true,
          timezone: "-03:00",
          vTotTribCalculate: true,
        }),
      });

      if (!criarUsuarioResp.ok) {
        const corpoErro = await criarUsuarioResp.text();
        console.error("Falha ao criar usuário na Dados Jah. Status:", criarUsuarioResp.status, "Corpo (sem dados sensíveis):", corpoErro.slice(0, 300));
        return jsonResponse({ error: "Não foi possível cadastrar a empresa na Dados Jah. Verifique os dados de Configurações Fiscais." }, 502);
      }

      // Guarda a senha SÓ no Vault (extensão oficial do Supabase) — nunca em texto puro na nossa tabela.
      const { data: vaultData, error: vaultError } = await admin
        .schema("vault")
        .rpc("create_secret", { secret: senhaGerada, name: `dadosjah_${empresaId}` });

      if (vaultError || !vaultData) {
        console.error("Falha ao gravar senha no Vault. Empresa:", empresaId);
        return jsonResponse({ error: "Erro interno ao proteger as credenciais. Tente novamente." }, 500);
      }
      const secretId = vaultData as unknown as string;

      const { error: credError } = await admin.from("dadosjah_credenciais").upsert({
        empresa_id: empresaId,
        dadosjah_email: emailDadosJah,
        dadosjah_password_secret_id: secretId,
      });
      if (credError) {
        console.error("Falha ao salvar credenciais locais para empresa:", empresaId);
        return jsonResponse({ error: "Erro interno ao salvar as credenciais." }, 500);
      }

      await admin.from("configuracoes_fiscais").update({ dadosjah_usuario_criado: true }).eq("empresa_id", empresaId);
    }

    // ---------------------------------------------------------
    // Etapa 2: registrar o emitente (POST /v1/emit), com o token do USUÁRIO
    // ---------------------------------------------------------
    if (!config.emitente_registrado) {
      const { data: cred } = await admin
        .from("dadosjah_credenciais")
        .select("dadosjah_email, dadosjah_password_secret_id")
        .eq("empresa_id", empresaId)
        .single();

      if (!cred) {
        return jsonResponse({ error: "Usuário desta empresa ainda não foi criado na Dados Jah." }, 500);
      }

      const { data: credenciaisPlano } = await admin.rpc("dadosjah_obter_credenciais", { p_empresa_id: empresaId }).single();
      const senha = (credenciaisPlano as { senha?: string } | null)?.senha;
      if (!senha) {
        return jsonResponse({ error: "Não foi possível recuperar as credenciais da empresa." }, 500);
      }

      const loginUsuarioResp = await fetch(`${DADOSJAH_BASE_URL}/auth/user/login`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ email: cred.dadosjah_email, password: senha }),
      });

      if (!loginUsuarioResp.ok) {
        console.error("Falha no login de usuário Dados Jah. Empresa:", empresaId, "Status:", loginUsuarioResp.status);
        return jsonResponse({ error: "Não foi possível autenticar a empresa na Dados Jah." }, 502);
      }

      const loginUsuarioJson = await loginUsuarioResp.json();
      const tokenUsuario = loginUsuarioJson?.data?.accessToken;
      const expiresAt = loginUsuarioJson?.data?.expiresAt ?? null;
      if (!tokenUsuario) {
        return jsonResponse({ error: "Resposta inesperada da Dados Jah ao autenticar a empresa." }, 502);
      }

      await admin
        .from("dadosjah_credenciais")
        .update({ dadosjah_token: tokenUsuario, dadosjah_token_expires_at: expiresAt })
        .eq("empresa_id", empresaId);

      const emitResp = await fetch(`${DADOSJAH_BASE_URL}/emit`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          Authorization: `Bearer ${tokenUsuario}`,
        },
        body: JSON.stringify({
          emit: {
            CNPJCPF: somenteDigitos(config.cnpj),
            xNome: config.razao_social,
            xFant: config.nome_fantasia || config.razao_social,
            enderEmit: {
              xLgr: config.endereco,
              nro: config.numero,
              xBairro: config.bairro,
              cMun: config.codigo_ibge,
              xMun: config.municipio,
              UF: config.uf,
              CEP: somenteDigitos(config.cep),
              cPais: "1058",
              xPais: "BRASIL",
              fone: somenteDigitos(config.telefone),
            },
            IE: config.inscricao_estadual ?? undefined,
            CRT: config.crt ?? undefined,
            IM: config.inscricao_municipal ?? undefined,
          },
        }),
      });

      if (!emitResp.ok) {
        const corpoErro = await emitResp.text();
        console.error("Falha ao registrar emitente. Empresa:", empresaId, "Status:", emitResp.status, corpoErro.slice(0, 300));
        return jsonResponse({ error: "Não foi possível registrar o emitente na Dados Jah. Confira os dados fiscais da empresa." }, 502);
      }

      await admin.from("configuracoes_fiscais").update({ emitente_registrado: true }).eq("empresa_id", empresaId);
    }

    return jsonResponse({ status: "ok", mensagem: "Empresa configurada com sucesso na Dados Jah." });
  } catch (err) {
    console.error("Erro em fiscal-configurar-emitente:", (err as Error)?.message);
    return jsonResponse({ error: "Erro interno ao configurar a integração fiscal." }, 500);
  }
});

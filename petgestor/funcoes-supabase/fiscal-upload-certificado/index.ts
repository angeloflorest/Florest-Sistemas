// Edge Function: fiscal-upload-certificado
//
// Recebe o certificado A1 (Base64) + senha DIRETAMENTE do navegador,
// repassa na hora para a Dados Jah (POST /v1/certificate) usando o token
// do USUÁRIO daquela empresa, e descarta o arquivo e a senha em seguida.
// Só os metadados seguros da resposta são gravados no nosso banco.

import {
  DADOSJAH_BASE_URL,
  criarClienteAdmin,
  criarClienteUsuario,
  jsonResponse,
} from "./dadosjah.ts";

async function obterTokenUsuario(admin: ReturnType<typeof criarClienteAdmin>, empresaId: string) {
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
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      email: cred.dadosjah_email,
      password: senha,
    }),
  });

  if (!resp.ok) return null;

  const json = await resp.json();
  const token = json?.data?.accessToken;
  const expiresAt = json?.data?.expiresAt ?? null;

  if (!token) return null;

  await admin
    .from("dadosjah_credenciais")
    .update({
      dadosjah_token: token,
      dadosjah_token_expires_at: expiresAt,
    })
    .eq("empresa_id", empresaId);

  return token as string;
}

Deno.serve(async (req: Request) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Método não permitido." }, 405);
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ error: "Não autenticado." }, 401);
    }

    const supabaseUser = criarClienteUsuario(authHeader);

    const { data: userData, error: userError } =
      await supabaseUser.auth.getUser();

    if (userError || !userData?.user) {
      return jsonResponse({ error: "Sessão inválida." }, 401);
    }

    const { data: perfil } = await supabaseUser
      .from("perfis")
      .select("empresa_id")
      .single();

    if (!perfil?.empresa_id) {
      return jsonResponse({ error: "Usuário sem empresa vinculada." }, 403);
    }

    const empresaId = perfil.empresa_id as string;

    const { data: config } = await supabaseUser
      .from("configuracoes_fiscais")
      .select("dadosjah_usuario_criado")
      .single();

    if (!config?.dadosjah_usuario_criado) {
      return jsonResponse(
        { error: "Cadastre a empresa na Dados Jah antes de enviar o certificado." },
        422
      );
    }

    // Corpo recebido só nesta requisição — nunca logado, nunca persistido.
    const body = await req.json().catch(() => null);

    const fileBase64: string | undefined = body?.file_base64;
    const senhaCertificado: string | undefined = body?.password;
    const extensao: string | undefined = body?.extension;

    if (!fileBase64 || !senhaCertificado || !extensao) {
      return jsonResponse(
        { error: "Arquivo, senha e extensão do certificado são obrigatórios." },
        400
      );
    }

    const admin = criarClienteAdmin();

    const tokenUsuario = await obterTokenUsuario(admin, empresaId);

    if (!tokenUsuario) {
      return jsonResponse(
        { error: "Não foi possível autenticar a empresa na Dados Jah." },
        502
      );
    }

    const respCertificado = await fetch(
      `${DADOSJAH_BASE_URL}/certificate`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          Authorization: `Bearer ${tokenUsuario}`,
        },
        body: JSON.stringify({
          file: fileBase64,
          password: senhaCertificado,
          extension: extensao,
        }),
      }
    );

    // A partir daqui, arquivo e senha não são persistidos.

    if (!respCertificado.ok) {
      console.error(
        "Falha ao enviar certificado. Empresa:",
        empresaId,
        "Status:",
        respCertificado.status
      );

      return jsonResponse(
        {
          error:
            "Não foi possível validar o certificado. Confira o arquivo e a senha.",
        },
        502
      );
    }

    const respostaJson = await respCertificado.json();
    const dados = respostaJson?.data ?? {};

    const { error: updateError } = await supabaseUser
      .from("configuracoes_fiscais")
      .update({
        certificado_numero_serie: dados.numeroSerie ?? null,
        certificado_razao_social: dados.razaoSocial ?? null,
        certificado_cnpj: dados.cnpj ?? null,
        certificado_validade: dados.validade ?? null,
        certificado_certificadora: dados.certificadora ?? null,
        certificado_status: "ativo",
      })
      .eq("empresa_id", empresaId);

    if (updateError) {
      console.error(
        "Falha ao salvar metadados do certificado. Empresa:",
        empresaId
      );

      return jsonResponse(
        {
          error:
            "Certificado validado, mas houve erro ao salvar o status. Tente novamente.",
        },
        500
      );
    }

    return jsonResponse({
      status: "ok",
      certificado: {
        razaoSocial: dados.razaoSocial ?? null,
        cnpj: dados.cnpj ?? null,
        validade: dados.validade ?? null,
        certificadora: dados.certificadora ?? null,
        numeroSerie: dados.numeroSerie ?? null,
      },
    });
  } catch (err) {
    console.error(
      "Erro em fiscal-upload-certificado:",
      (err as Error)?.message
    );

    return jsonResponse(
      { error: "Erro interno ao enviar o certificado." },
      500
    );
  }
});

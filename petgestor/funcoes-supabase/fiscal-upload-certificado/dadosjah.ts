// Helpers compartilhados entre as Edge Functions fiscais.
// Nenhum valor sensível (senha, token, Base64 de certificado, XML/PDF) deve
// ser passado para console.log/console.error em nenhum lugar deste arquivo
// ou dos arquivos que o importam.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export const DADOSJAH_BASE_URL = "https://api-dfe.dadosjah.com.br/v1";

// ------------------------------------------------------------------
// Cliente administrativo centralizado.
//
// O Supabase está migrando de SUPABASE_SERVICE_ROLE_KEY (legado, formato JWT)
// para SUPABASE_SECRET_KEYS (novo, dicionário JSON de chaves sb_secret_...).
// Ambos continuam funcionando em paralelo durante a migração. Esta função
// tenta o formato novo primeiro e cai para o legado automaticamente — assim
// o projeto continua funcionando independente de qual formato já está
// configurado, sem espalhar essa decisão pelo resto do código.
// ------------------------------------------------------------------
export function criarClienteAdmin(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  if (!url) throw new Error("SUPABASE_URL não configurada no ambiente da função.");

  let chave: string | undefined;

  const secretKeysRaw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (secretKeysRaw) {
    try {
      const parsed = JSON.parse(secretKeysRaw) as Record<string, string>;
      const valores = Object.values(parsed);
      if (valores.length > 0) chave = valores[0];
    } catch (_e) {
      // Formato inesperado — segue para o fallback legado abaixo.
    }
  }

  if (!chave) {
    chave = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  }

  if (!chave) {
    throw new Error(
      "Nenhuma chave administrativa disponível (nem SUPABASE_SECRET_KEYS, nem SUPABASE_SERVICE_ROLE_KEY)."
    );
  }

  return createClient(url, chave, { auth: { persistSession: false } });
}

// Cliente "como o usuário" — todas as leituras feitas com ele respeitam RLS,
// então é impossível acessar dado de outra empresa através dele.
export function criarClienteUsuario(authHeader: string): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey =
    Deno.env.get("SUPABASE_PUBLISHABLE_KEYS")
      ? (() => {
          try {
            const parsed = JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS")!);
            const valores = Object.values(parsed) as string[];
            return valores[0];
          } catch {
            return undefined;
          }
        })()
      : undefined;

  const chave = anonKey ?? Deno.env.get("SUPABASE_ANON_KEY")!;

  return createClient(url, chave, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ------------------------------------------------------------------
// Interpretação do retorno fiscal — nunca marca como autorizado sem
// evidência positiva completa (cStat + protocolo + chave de acesso),
// e nunca conclui autorização só pelo HTTP ter respondido 200/201.
//
// cStat = "100" é o código nacional padrão da SEFAZ para
// "Autorizado o uso da NF-e/NFC-e" (Manual de Orientação do Contribuinte,
// layout nacional — não é específico da Dados Jah, é o padrão usado por
// qualquer emissor no Brasil).
// ------------------------------------------------------------------
export interface ResultadoFiscal {
  status: "autorizada" | "rejeitada" | "processando";
  cStat: string | null;
  xMotivo: string | null;
}

export function interpretarRetornoFiscal(item: Record<string, unknown>): ResultadoFiscal {
  const cStat = item?.cStat != null ? String(item.cStat) : null;
  const xMotivo = item?.xMotivo != null ? String(item.xMotivo) : null;
  const situationDfe = item?.situationDfe != null ? String(item.situationDfe).toLowerCase() : "";
  const temProtocolo = !!item?.nProt;
  const temChave = !!item?.chDfe;

  if (situationDfe.includes("rejeit")) {
    return { status: "rejeitada", cStat, xMotivo };
  }

  if (cStat === "100" && temProtocolo && temChave) {
    return { status: "autorizada", cStat, xMotivo };
  }

  // Qualquer outra combinação (cStat diferente, sem protocolo/chave,
  // situação ainda não conclusiva) fica em estado seguro — nunca "autorizada".
  return { status: "processando", cStat, xMotivo };
}

// Data/hora no formato ISO 8601 com offset fixo de Brasília.
// O Brasil não usa mais horário de verão desde 2019, então -03:00 é estável.
export function agoraISOComOffsetBrasilia(): string {
  const agora = new Date();
  const local = new Date(agora.getTime() - 3 * 60 * 60 * 1000);
  const iso = local.toISOString().replace("Z", "");
  return `${iso}-03:00`;
}

// Mapa oficial de código UF (padrão IBGE/SEFAZ, usado em cUF) — dado público
// do layout nacional, não específico da Dados Jah.
export const CODIGO_UF: Record<string, string> = {
  AC: "12", AL: "27", AP: "16", AM: "13", BA: "29", CE: "23", DF: "53",
  ES: "32", GO: "52", MA: "21", MT: "51", MS: "50", MG: "31", PA: "15",
  PB: "25", PR: "41", PE: "26", PI: "22", RJ: "33", RN: "24", RS: "43",
  RO: "11", RR: "14", SC: "42", SP: "35", SE: "28", TO: "17",
};

// Código de forma de pagamento (tPag) — tabela nacional padrão do layout NFC-e.
export function codigoFormaPagamento(formaPagamento: string): string {
  const mapa: Record<string, string> = {
    "Dinheiro": "01",
    "Pix": "17",
    "Cartão de Débito": "04",
    "Cartão de Crédito": "03",
  };
  return mapa[formaPagamento] ?? "99"; // 99 = Outros, padrão nacional para forma não mapeada
}

export function somenteDigitos(valor: string | null | undefined): string {
  return (valor ?? "").replace(/\D/g, "");
}

export function formatarValorMonetario(valor: number): string {
  return valor.toFixed(2);
}

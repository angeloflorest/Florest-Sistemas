-- CPF/CNPJ no PDV principal. Mantém o campo e o contrato p_cpf_nota existentes.
-- Sem alteração de estoque, pagamentos, numeração, permissões ou emissão fiscal.
BEGIN;

CREATE OR REPLACE FUNCTION private.cpf_cnpj_valido(p_documento text)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  d text := regexp_replace(coalesce(p_documento, ''), '[[:space:]./-]', '', 'g');
  pesos1 integer[] := ARRAY[5,4,3,2,9,8,7,6,5,4,3,2];
  pesos2 integer[] := ARRAY[6,5,4,3,2,9,8,7,6,5,4,3,2];
  soma integer := 0;
  resto integer;
  i integer;
BEGIN
  IF d ~ '^[0-9]{11}$' THEN RETURN private.cpf_valido(d); END IF;
  IF d !~ '^[0-9]{14}$' OR d ~ '^([0-9])\1{13}$' THEN RETURN false; END IF;
  FOR i IN 1..12 LOOP soma := soma + substr(d, i, 1)::integer * pesos1[i]; END LOOP;
  resto := soma % 11;
  IF substr(d, 13, 1)::integer <> (CASE WHEN resto < 2 THEN 0 ELSE 11-resto END) THEN RETURN false; END IF;
  soma := 0;
  FOR i IN 1..13 LOOP soma := soma + substr(d, i, 1)::integer * pesos2[i]; END LOOP;
  resto := soma % 11;
  RETURN substr(d, 14, 1)::integer = (CASE WHEN resto < 2 THEN 0 ELSE 11-resto END);
END;
$function$;
REVOKE ALL ON FUNCTION private.cpf_cnpj_valido(text) FROM PUBLIC, anon, authenticated;

-- Reaproveita integralmente a função atualmente publicada. A proteção impede sobrescrever
-- uma revisão posterior com uma implementação antiga de registrar_venda.
DO $patch$
DECLARE
  assinatura regprocedure := 'public.registrar_venda(uuid,text,jsonb,text)'::regprocedure;
  original text;
  novo text;
BEGIN
  original := pg_get_functiondef(assinatura);
  IF md5(original) <> '800ee142b19c43a0e904b4095a4ec93b' THEN
    RAISE EXCEPTION 'registrar_venda mudou desde a análise. Reaplicar somente a validação CPF/CNPJ na versão atual.';
  END IF;
  novo := replace(original,
    $old$regexp_replace(coalesce(p_cpf_nota, ''), '[^0-9]', '', 'g')$old$,
    $new$regexp_replace(coalesce(p_cpf_nota, ''), '[[:space:]./-]', '', 'g')$new$);
  novo := replace(novo, 'not private.cpf_valido(v_cpf_nota)', 'not private.cpf_cnpj_valido(v_cpf_nota)');
  novo := replace(novo, 'CPF informado na nota é inválido.', 'CPF ou CNPJ informado na nota é inválido.');
  IF novo = original OR strpos(novo, 'private.cpf_cnpj_valido(v_cpf_nota)') = 0 THEN
    RAISE EXCEPTION 'Trecho de validação CPF/CNPJ não localizado. Nenhuma função foi substituída.';
  END IF;
  EXECUTE novo;
END;
$patch$;

ALTER TABLE public.vendas DROP CONSTRAINT vendas_cpf_nota_formato_ck;
ALTER TABLE public.vendas ADD CONSTRAINT vendas_cpf_nota_formato_ck
  CHECK (cpf_nota IS NULL OR cpf_nota ~ '^([0-9]{11}|[0-9]{14})$');
COMMIT;

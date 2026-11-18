-- Cadastro documental isolado dos dados operacionais e acessível somente pelo Admin.
CREATE TABLE private.admin_cadastros_documentais (
 empresa_id uuid PRIMARY KEY REFERENCES public.empresas(id) ON DELETE CASCADE,
 dados jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(dados)='object'),
 atualizado_em timestamptz NOT NULL DEFAULT now(), atualizado_por uuid
);
CREATE TABLE private.admin_prestador_documental (
 id boolean PRIMARY KEY DEFAULT true CHECK(id),
 dados jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(dados)='object'),
 atualizado_em timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE private.admin_cadastros_documentais ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.admin_prestador_documental ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.admin_cadastros_documentais,private.admin_prestador_documental FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.admin_validar_cadastro_documental(d jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $fn$
DECLARE k text;v jsonb;keys text[]:=ARRAY['razao_social','cnpj','logradouro','numero','complemento','bairro','cidade','uf','cep','representante','cpf_representante','email_boleto','telefone','telefone_alternativo','inicio','primeiro_vencimento','dia_vencimento'];
BEGIN
 IF d IS NULL OR jsonb_typeof(d)<>'object' THEN RAISE EXCEPTION 'Dados documentais inválidos.';END IF;
 FOR k,v IN SELECT * FROM jsonb_each(d) LOOP
  IF NOT k=ANY(keys) OR jsonb_typeof(v)<>'string' OR length(v#>>'{}')>320 THEN RAISE EXCEPTION 'Campo documental inválido: %',k;END IF;
 END LOOP;
 IF coalesce(d->>'cnpj','')<>'' AND (d->>'cnpj')!~'^[0-9]{14}$' THEN RAISE EXCEPTION 'Informe CNPJ com 14 dígitos.';END IF;
 IF coalesce(d->>'cpf_representante','')<>'' AND (d->>'cpf_representante')!~'^[0-9]{11}$' THEN RAISE EXCEPTION 'Informe CPF com 11 dígitos.';END IF;
 IF coalesce(d->>'cep','')<>'' AND (d->>'cep')!~'^[0-9]{8}$' THEN RAISE EXCEPTION 'Informe CEP com 8 dígitos.';END IF;
 IF coalesce(d->>'uf','')<>'' AND (d->>'uf')!~'^[A-Z]{2}$' THEN RAISE EXCEPTION 'Informe UF com duas letras.';END IF;
 IF coalesce(d->>'dia_vencimento','')<>'' THEN
  IF (d->>'dia_vencimento')!~'^[0-9]{1,2}$' THEN RAISE EXCEPTION 'Dia de vencimento inválido.';END IF;
  IF (d->>'dia_vencimento')::int NOT BETWEEN 1 AND 31 THEN RAISE EXCEPTION 'Informe vencimento entre 1 e 31.';END IF;
 END IF;
 FOREACH k IN ARRAY ARRAY['inicio','primeiro_vencimento'] LOOP
  IF coalesce(d->>k,'')<>'' THEN
   IF (d->>k)!~'^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN RAISE EXCEPTION 'Data inválida.';END IF;
   PERFORM (d->>k)::date;
  END IF;
 END LOOP;
 RETURN d;
END $fn$;
REVOKE ALL ON FUNCTION private.admin_validar_cadastro_documental(jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.admin_ler_cadastro_documental(p_empresa uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
 IF auth.uid() IS NULL OR NOT coalesce(public.florest_eh_admin(),false) THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.empresas WHERE id=p_empresa) THEN RAISE EXCEPTION 'Empresa não encontrada.';END IF;
 RETURN jsonb_build_object('empresa_id',p_empresa,'cliente',coalesce((SELECT dados FROM private.admin_cadastros_documentais WHERE empresa_id=p_empresa),'{}'::jsonb),'prestador',coalesce((SELECT dados FROM private.admin_prestador_documental WHERE id),'{}'::jsonb));
END $fn$;
CREATE FUNCTION public.admin_salvar_cadastro_documental(p_empresa uuid,p_dados jsonb,p_comercial jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
 IF auth.uid() IS NULL OR NOT coalesce(public.florest_eh_admin(),false) THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.empresas WHERE id=p_empresa) THEN RAISE EXCEPTION 'Empresa não encontrada.';END IF;
 IF p_comercial IS NULL OR jsonb_typeof(p_comercial)<>'object' THEN RAISE EXCEPTION 'Dados comerciais inválidos.';END IF;
 PERFORM private.admin_validar_cadastro_documental(p_dados);
 PERFORM public.admin_atualizar_empresa(p_empresa,p_comercial->>'responsavel',p_comercial->>'email',nullif(p_comercial->>'vencimento','')::date,nullif(p_comercial->>'valor_mensal','')::numeric,p_comercial->>'status_pagamento',p_comercial->>'observacoes');
 INSERT INTO private.admin_cadastros_documentais(empresa_id,dados,atualizado_por) VALUES(p_empresa,p_dados,auth.uid())
 ON CONFLICT(empresa_id) DO UPDATE SET dados=EXCLUDED.dados,atualizado_em=now(),atualizado_por=auth.uid();
END $fn$;
REVOKE ALL ON FUNCTION public.admin_ler_cadastro_documental(uuid),public.admin_salvar_cadastro_documental(uuid,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_ler_cadastro_documental(uuid),public.admin_salvar_cadastro_documental(uuid,jsonb,jsonb) TO authenticated;

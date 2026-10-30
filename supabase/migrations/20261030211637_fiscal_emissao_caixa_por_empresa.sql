-- Configuração exclusiva da apresentação fiscal nos caixas. Não altera recebimentos ou documentos.
SET LOCAL lock_timeout = '5s';
DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='configuracoes_fiscais' AND column_name='emite_nota_fiscal') THEN
    RAISE EXCEPTION 'Configuração já instalada: preservar escolhas existentes e conferir a migration.';
  END IF;
  IF md5(pg_get_functiondef('private.empresa_id_ativa()'::regprocedure)) <> '7c98898949efdc14cf18e69b4f8a65ed' THEN RAISE EXCEPTION 'Dependência fiscal incompatível: private.empresa_id_ativa()'; END IF;
  IF md5(pg_get_functiondef('private.set_atualizado_em()'::regprocedure)) <> 'bcb1484d315ec167a3191f2aeef0afb1' THEN RAISE EXCEPTION 'Dependência fiscal incompatível: private.set_atualizado_em()'; END IF;
  IF md5(pg_get_functiondef('private.empresas_regras()'::regprocedure)) <> '170fce05118b133ded58de982c10e834' THEN RAISE EXCEPTION 'Dependência fiscal incompatível: private.empresas_regras()'; END IF;
  IF md5(pg_get_functiondef('private.proteger_config_fiscal()'::regprocedure)) <> '77c65f3093397b39ed93505ff1c2b208' THEN RAISE EXCEPTION 'Dependência fiscal incompatível: private.proteger_config_fiscal()'; END IF;
  IF md5(pg_get_functiondef('private.florest_empresas_outbox()'::regprocedure)) <> '7fe745de9e85dfe961bb49109d9ed6c8' THEN RAISE EXCEPTION 'Dependência fiscal incompatível: private.florest_empresas_outbox()'; END IF;
  IF md5(pg_get_functiondef('private.perm_alguma(text[])'::regprocedure)) <> '1ceceb63c94eab984ca61004caa9a531' THEN RAISE EXCEPTION 'Dependência fiscal incompatível: private.perm_alguma(text[])'; END IF;
  IF md5(pg_get_functiondef('private.pdv_comandas_semear_nova_empresa()'::regprocedure)) <> '0ee09e7f1103e0ac391528fa47b6121c' THEN RAISE EXCEPTION 'Dependência fiscal incompatível: private.pdv_comandas_semear_nova_empresa()'; END IF;
  IF md5(pg_get_functiondef('gastronomia_rpc(text,jsonb,uuid)'::regprocedure)) <> '7b65e1391ea24072c8adef7405497630' THEN RAISE EXCEPTION 'Dependência fiscal incompatível: gastronomia_rpc(text,jsonb,uuid)'; END IF;
  IF md5(pg_get_functiondef('mesas_pagamento_produtos(text,text,uuid,jsonb,uuid)'::regprocedure)) <> 'ab7b86924d09b711add754f87e55f3ba' THEN RAISE EXCEPTION 'Dependência fiscal incompatível: mesas_pagamento_produtos(text,text,uuid,jsonb,uuid)'; END IF;
END $guard$;

ALTER TABLE public.configuracoes_fiscais ADD COLUMN emite_nota_fiscal boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.configuracoes_fiscais.emite_nota_fiscal IS 'Controla somente a apresentação de emissão NFC-e no fechamento; padrão true por empresa.';

-- Configurações existentes recebem true pelo DEFAULT, sem substituir qualquer campo fiscal.
-- Empresa sem linha fiscal recebe somente os defaults já definidos pela tabela.
INSERT INTO public.configuracoes_fiscais(empresa_id)
SELECT e.id FROM public.empresas e
WHERE NOT EXISTS(SELECT 1 FROM public.configuracoes_fiscais c WHERE c.empresa_id=e.id)
ON CONFLICT (empresa_id) DO NOTHING;

CREATE FUNCTION private.fiscal_config_nova_empresa() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  INSERT INTO public.configuracoes_fiscais(empresa_id) VALUES (NEW.id)
  ON CONFLICT (empresa_id) DO NOTHING;
  RETURN NEW;
END $fn$;
REVOKE ALL ON FUNCTION private.fiscal_config_nova_empresa() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER fiscal_config_nova_empresa AFTER INSERT ON public.empresas
FOR EACH ROW EXECUTE FUNCTION private.fiscal_config_nova_empresa();

-- Leitura mínima: operadores de caixa não recebem acesso ao CSC ou certificado.
CREATE FUNCTION private.fiscal_emissao_caixa_ler() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE e uuid; habilitada boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Autenticação necessária.' USING ERRCODE='42501'; END IF;
  e := private.empresa_id_ativa();
  IF e IS NULL OR NOT private.perm_alguma(ARRAY['configuracoes','fiscal','pdv','bar_caixa','gastronomia_caixa']) THEN
    RAISE EXCEPTION 'Sem permissão para consultar a configuração fiscal do caixa.' USING ERRCODE='42501';
  END IF;
  SELECT c.emite_nota_fiscal INTO habilitada FROM public.configuracoes_fiscais c WHERE c.empresa_id=e;
  RETURN jsonb_build_object('empresa_id',e,'emite_nota_fiscal',coalesce(habilitada,true));
END $fn$;
REVOKE ALL ON FUNCTION private.fiscal_emissao_caixa_ler() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.fiscal_emissao_caixa_ler() TO authenticated;
CREATE FUNCTION public.fiscal_emissao_caixa_obter() RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $fn$
  SELECT private.fiscal_emissao_caixa_ler();
$fn$;
REVOKE ALL ON FUNCTION public.fiscal_emissao_caixa_obter() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fiscal_emissao_caixa_obter() TO authenticated;

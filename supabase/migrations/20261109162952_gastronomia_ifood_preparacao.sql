-- Preparação exclusiva do Gastronomia. Nenhum consumidor/cron ou credencial é ativado.
CREATE TABLE private.gastronomia_ifood_config (
 empresa_id uuid PRIMARY KEY REFERENCES public.empresas(id),
 merchant_id uuid UNIQUE, nome_loja text NOT NULL DEFAULT '' CHECK(length(nome_loja)<=120),
 ambiente text NOT NULL DEFAULT 'teste' CHECK(ambiente IN ('teste','producao')),
 estado text NOT NULL DEFAULT 'preparacao' CHECK(estado='preparacao'),
 versao integer NOT NULL DEFAULT 1, atualizado_em timestamptz NOT NULL DEFAULT now(), atualizado_por uuid
);
CREATE TABLE private.gastronomia_ifood_vinculos (
 empresa_id uuid NOT NULL REFERENCES public.empresas(id), tipo text NOT NULL CHECK(tipo IN ('produto','adicional')),
 codigo_externo text NOT NULL CHECK(length(codigo_externo) BETWEEN 1 AND 100),
 produto_id uuid NOT NULL REFERENCES public.produtos(id), ativo boolean NOT NULL DEFAULT true,
 atualizado_em timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(empresa_id,tipo,codigo_externo)
);
-- Reservas duráveis para a etapa de conexão; não recebem pedidos nesta preparação.
CREATE TABLE private.gastronomia_ifood_eventos (
 empresa_id uuid NOT NULL REFERENCES public.empresas(id), merchant_id uuid NOT NULL,
 evento_id uuid NOT NULL, pedido_id uuid, codigo text NOT NULL, ocorrido_em timestamptz NOT NULL,
 recebido_em timestamptz NOT NULL DEFAULT now(), payload jsonb NOT NULL,
 estado text NOT NULL DEFAULT 'pendente' CHECK(estado IN ('pendente','processando','processado','falha','ignorado')),
 tentativas integer NOT NULL DEFAULT 0 CHECK(tentativas>=0), proxima_tentativa timestamptz,
 PRIMARY KEY(empresa_id,evento_id),
 FOREIGN KEY(empresa_id) REFERENCES private.gastronomia_ifood_config(empresa_id)
);
CREATE INDEX gastronomia_ifood_eventos_fila ON private.gastronomia_ifood_eventos(estado,proxima_tentativa) WHERE estado IN ('pendente','falha');
CREATE TABLE private.gastronomia_ifood_comandos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), empresa_id uuid NOT NULL REFERENCES public.empresas(id),
 pedido_id uuid NOT NULL, chave uuid NOT NULL,
 acao text NOT NULL CHECK(acao IN ('confirmar','preparar','pronto','despachar','solicitar_cancelamento')),
 estado text NOT NULL DEFAULT 'pendente' CHECK(estado IN ('pendente','enviado','confirmado','incerto','falha')),
 payload jsonb NOT NULL DEFAULT '{}', criado_em timestamptz NOT NULL DEFAULT now(),
 tentativas integer NOT NULL DEFAULT 0 CHECK(tentativas>=0), proxima_tentativa timestamptz,
 UNIQUE(empresa_id,chave), FOREIGN KEY(empresa_id) REFERENCES private.gastronomia_ifood_config(empresa_id)
);
CREATE INDEX gastronomia_ifood_comandos_fila ON private.gastronomia_ifood_comandos(estado,proxima_tentativa) WHERE estado IN ('pendente','falha');
ALTER TABLE private.gastronomia_ifood_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_ifood_vinculos ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_ifood_eventos ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_ifood_comandos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.gastronomia_ifood_config,private.gastronomia_ifood_vinculos,private.gastronomia_ifood_eventos,private.gastronomia_ifood_comandos FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.gastronomia_ifood_admin(p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_configurar'); c private.gastronomia_ifood_config;
 d jsonb:=coalesce(p_dados,'{}'); v integer; external_code text; product uuid; kind text;
BEGIN
 IF (d->>'empresa_esperada')::uuid IS DISTINCT FROM e THEN
  RAISE EXCEPTION 'A empresa da sessão mudou. Atualize a tela.' USING ERRCODE='42501';
 END IF;
 IF p_acao NOT IN ('obter','salvar','vincular') OR p_acao IS NULL THEN RAISE EXCEPTION 'Operação iFood indisponível nesta preparação.'; END IF;
 IF p_acao<>'obter' THEN
  PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':gastronomia_ifood',0));
  SELECT * INTO c FROM private.gastronomia_ifood_config WHERE empresa_id=e FOR UPDATE;
  v:=coalesce(c.versao,0);
  IF (d->>'versao')::integer IS DISTINCT FROM v THEN RAISE EXCEPTION 'A preparação foi alterada em outro terminal. Atualize antes de salvar.'; END IF;
  IF p_acao='salvar' THEN
   IF coalesce(d->>'ambiente','') NOT IN ('teste','producao') OR length(coalesce(d->>'nome_loja',''))>120 THEN RAISE EXCEPTION 'Confira o ambiente e o nome da loja.'; END IF;
   INSERT INTO private.gastronomia_ifood_config(empresa_id,merchant_id,nome_loja,ambiente,atualizado_por)
    VALUES(e,nullif(d->>'merchant_id','')::uuid,btrim(coalesce(d->>'nome_loja','')),d->>'ambiente',auth.uid())
    ON CONFLICT(empresa_id) DO UPDATE SET merchant_id=excluded.merchant_id,nome_loja=excluded.nome_loja,ambiente=excluded.ambiente,versao=gastronomia_ifood_config.versao+1,atualizado_em=now(),atualizado_por=auth.uid();
  ELSE
   external_code:=btrim(coalesce(d->>'codigo_externo','')); kind:=d->>'tipo'; product:=(d->>'produto_id')::uuid;
   IF length(external_code) NOT BETWEEN 1 AND 100 OR kind IS NULL OR kind NOT IN ('produto','adicional') THEN RAISE EXCEPTION 'Informe o código e o tipo do vínculo.'; END IF;
   IF NOT EXISTS(SELECT 1 FROM public.produtos WHERE id=product AND empresa_id=e AND ativo) THEN RAISE EXCEPTION 'Selecione um produto ativo desta empresa.'; END IF;
   INSERT INTO private.gastronomia_ifood_config(empresa_id,atualizado_por) VALUES(e,auth.uid()) ON CONFLICT(empresa_id) DO UPDATE SET versao=gastronomia_ifood_config.versao+1,atualizado_em=now(),atualizado_por=auth.uid();
   INSERT INTO private.gastronomia_ifood_vinculos(empresa_id,tipo,codigo_externo,produto_id,ativo)
    VALUES(e,kind,external_code,product,coalesce((d->>'ativo')::boolean,true))
    ON CONFLICT(empresa_id,tipo,codigo_externo) DO UPDATE SET produto_id=excluded.produto_id,ativo=excluded.ativo,atualizado_em=now();
  END IF;
 END IF;
 SELECT * INTO c FROM private.gastronomia_ifood_config WHERE empresa_id=e;
 RETURN jsonb_build_object('empresa_id',e,'estado','preparacao','conectado',false,'versao',coalesce(c.versao,0),
  'config',jsonb_build_object('merchant_id',c.merchant_id,'nome_loja',coalesce(c.nome_loja,''),'ambiente',coalesce(c.ambiente,'teste')),
  'vinculos',(SELECT coalesce(jsonb_agg(jsonb_build_object('tipo',m.tipo,'codigo_externo',m.codigo_externo,'produto_id',m.produto_id,'ativo',m.ativo,'nome',p.nome) ORDER BY m.tipo,m.codigo_externo),'[]') FROM private.gastronomia_ifood_vinculos m JOIN public.produtos p ON p.id=m.produto_id AND p.empresa_id=m.empresa_id WHERE m.empresa_id=e));
END $$;
REVOKE ALL ON FUNCTION public.gastronomia_ifood_admin(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_ifood_admin(text,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';

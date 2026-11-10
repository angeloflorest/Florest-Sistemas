-- Preparação exclusiva do Gastronomia. Nenhum consumidor/cron ou credencial é ativado.
CREATE TABLE private.gastronomia_99food_config (
 empresa_id uuid PRIMARY KEY REFERENCES public.empresas(id),
 shop_id text CHECK(shop_id IS NULL OR shop_id ~ '^[1-9][0-9]{0,18}$'),
 app_shop_id text NOT NULL CHECK(length(app_shop_id) BETWEEN 1 AND 100),
 sincronizar_cardapio boolean NOT NULL DEFAULT false, nome_loja text NOT NULL DEFAULT '' CHECK(length(nome_loja)<=120),
 ambiente text NOT NULL DEFAULT 'teste' CHECK(ambiente IN ('teste','producao')),
 estado text NOT NULL DEFAULT 'preparacao' CHECK(estado='preparacao'),
 UNIQUE(ambiente,shop_id), UNIQUE(ambiente,app_shop_id),
 versao integer NOT NULL DEFAULT 1, atualizado_em timestamptz NOT NULL DEFAULT now(), atualizado_por uuid
);
CREATE TABLE private.gastronomia_99food_vinculos (
 empresa_id uuid NOT NULL REFERENCES public.empresas(id), tipo text NOT NULL CHECK(tipo IN ('produto','adicional')),
 codigo_externo text NOT NULL CHECK(length(codigo_externo) BETWEEN 1 AND 100),
 produto_id uuid NOT NULL REFERENCES public.produtos(id), ativo boolean NOT NULL DEFAULT true,
 atualizado_em timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(empresa_id,tipo,codigo_externo)
);
-- Reservas duráveis para a etapa de conexão; não recebem pedidos nesta preparação.
CREATE TABLE private.gastronomia_99food_eventos (
 empresa_id uuid NOT NULL REFERENCES public.empresas(id), shop_id text NOT NULL,
 evento_id text NOT NULL, pedido_id text, codigo text NOT NULL, ocorrido_em timestamptz NOT NULL,
 recebido_em timestamptz NOT NULL DEFAULT now(), payload jsonb NOT NULL,
 estado text NOT NULL DEFAULT 'pendente' CHECK(estado IN ('pendente','processando','processado','falha','ignorado')),
 tentativas integer NOT NULL DEFAULT 0 CHECK(tentativas>=0), proxima_tentativa timestamptz,
 PRIMARY KEY(empresa_id,evento_id),
 FOREIGN KEY(empresa_id) REFERENCES private.gastronomia_99food_config(empresa_id)
);
CREATE INDEX gastronomia_99food_eventos_fila ON private.gastronomia_99food_eventos(estado,proxima_tentativa) WHERE estado IN ('pendente','falha');
CREATE TABLE private.gastronomia_99food_comandos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), empresa_id uuid NOT NULL REFERENCES public.empresas(id),
 pedido_id text NOT NULL, chave uuid NOT NULL,
 acao text NOT NULL CHECK(acao IN ('confirmar','pronto','retirada','entregue','solicitar_cancelamento','confirmar_dinheiro','atualizar_item','disponibilidade')),
 estado text NOT NULL DEFAULT 'pendente' CHECK(estado IN ('pendente','enviado','confirmado','incerto','falha')),
 payload jsonb NOT NULL DEFAULT '{}', criado_em timestamptz NOT NULL DEFAULT now(),
 tentativas integer NOT NULL DEFAULT 0 CHECK(tentativas>=0), proxima_tentativa timestamptz,
 UNIQUE(empresa_id,chave), FOREIGN KEY(empresa_id) REFERENCES private.gastronomia_99food_config(empresa_id)
);
CREATE INDEX gastronomia_99food_comandos_fila ON private.gastronomia_99food_comandos(estado,proxima_tentativa) WHERE estado IN ('pendente','falha');
ALTER TABLE private.gastronomia_99food_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_99food_vinculos ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_99food_eventos ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_99food_comandos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.gastronomia_99food_config,private.gastronomia_99food_vinculos,private.gastronomia_99food_eventos,private.gastronomia_99food_comandos FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.gastronomia_99food_admin(p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_configurar'); c private.gastronomia_99food_config;
 d jsonb:=coalesce(p_dados,'{}'); v integer; external_code text; product uuid; kind text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Autenticação necessária.' USING ERRCODE='42501'; END IF;
 IF (d->>'empresa_esperada')::uuid IS DISTINCT FROM e THEN
  RAISE EXCEPTION 'A empresa da sessão mudou. Atualize a tela.' USING ERRCODE='42501';
 END IF;
 IF p_acao NOT IN ('obter','salvar','vincular') OR p_acao IS NULL THEN RAISE EXCEPTION 'Operação 99Food indisponível nesta preparação.'; END IF;
 IF p_acao<>'obter' THEN
  PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':gastronomia_99food',0));
  SELECT * INTO c FROM private.gastronomia_99food_config WHERE empresa_id=e FOR UPDATE;
  v:=coalesce(c.versao,0);
  IF (d->>'versao')::integer IS DISTINCT FROM v THEN RAISE EXCEPTION 'A preparação foi alterada em outro terminal. Atualize antes de salvar.'; END IF;
  IF p_acao='salvar' THEN
   IF coalesce(d->>'ambiente','') NOT IN ('teste','producao') OR length(coalesce(d->>'nome_loja',''))>120 THEN RAISE EXCEPTION 'Confira o ambiente e o nome da loja.'; END IF;
   INSERT INTO private.gastronomia_99food_config(empresa_id,shop_id,app_shop_id,nome_loja,ambiente,sincronizar_cardapio,atualizado_por)
    VALUES(e,nullif(btrim(d->>'shop_id'),''),coalesce(nullif(btrim(d->>'app_shop_id'),''),e::text),btrim(coalesce(d->>'nome_loja','')),d->>'ambiente',coalesce((d->>'sincronizar_cardapio')::boolean,false),auth.uid())
    ON CONFLICT(empresa_id) DO UPDATE SET shop_id=excluded.shop_id,app_shop_id=excluded.app_shop_id,sincronizar_cardapio=excluded.sincronizar_cardapio,nome_loja=excluded.nome_loja,ambiente=excluded.ambiente,versao=gastronomia_99food_config.versao+1,atualizado_em=now(),atualizado_por=auth.uid();
  ELSE
   external_code:=btrim(coalesce(d->>'codigo_externo','')); kind:=d->>'tipo'; product:=(d->>'produto_id')::uuid;
   IF length(external_code) NOT BETWEEN 1 AND 100 OR kind IS NULL OR kind NOT IN ('produto','adicional') THEN RAISE EXCEPTION 'Informe o código e o tipo do vínculo.'; END IF;
   IF NOT EXISTS(SELECT 1 FROM public.produtos WHERE id=product AND empresa_id=e AND ativo) THEN RAISE EXCEPTION 'Selecione um produto ativo desta empresa.'; END IF;
   INSERT INTO private.gastronomia_99food_config(empresa_id,app_shop_id,atualizado_por) VALUES(e,e::text,auth.uid()) ON CONFLICT(empresa_id) DO UPDATE SET versao=gastronomia_99food_config.versao+1,atualizado_em=now(),atualizado_por=auth.uid();
   INSERT INTO private.gastronomia_99food_vinculos(empresa_id,tipo,codigo_externo,produto_id,ativo)
    VALUES(e,kind,external_code,product,coalesce((d->>'ativo')::boolean,true))
    ON CONFLICT(empresa_id,tipo,codigo_externo) DO UPDATE SET produto_id=excluded.produto_id,ativo=excluded.ativo,atualizado_em=now();
  END IF;
 END IF;
 SELECT * INTO c FROM private.gastronomia_99food_config WHERE empresa_id=e;
 RETURN jsonb_build_object('empresa_id',e,'estado','preparacao','conectado',false,'versao',coalesce(c.versao,0),
  'config',jsonb_build_object('shop_id',c.shop_id,'app_shop_id',coalesce(c.app_shop_id,e::text),'sincronizar_cardapio',coalesce(c.sincronizar_cardapio,false),'nome_loja',coalesce(c.nome_loja,''),'ambiente',coalesce(c.ambiente,'teste')),
  'vinculos',(SELECT coalesce(jsonb_agg(jsonb_build_object('tipo',m.tipo,'codigo_externo',m.codigo_externo,'produto_id',m.produto_id,'ativo',m.ativo,'nome',p.nome) ORDER BY m.tipo,m.codigo_externo),'[]') FROM private.gastronomia_99food_vinculos m JOIN public.produtos p ON p.id=m.produto_id AND p.empresa_id=m.empresa_id WHERE m.empresa_id=e));
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_admin(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.gastronomia_99food_admin(text,jsonb) TO authenticated;
CREATE FUNCTION public.gastronomia_99food_admin(p_acao text,p_dados jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.gastronomia_99food_admin(p_acao,p_dados);
$$;
REVOKE ALL ON FUNCTION public.gastronomia_99food_admin(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_99food_admin(text,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';

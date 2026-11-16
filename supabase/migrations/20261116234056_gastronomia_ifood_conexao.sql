-- iFood exclusivo da Gastronomia. Credenciais no Vault, filas isoladas por empresa.
ALTER TABLE private.gastronomia_ifood_config ADD COLUMN habilitada boolean NOT NULL DEFAULT false,
 ADD COLUMN credencial_id uuid, ADD COLUMN ultimo_poll timestamptz, ADD COLUMN proximo_poll timestamptz,
 ADD COLUMN lease_ate timestamptz, ADD COLUMN ultimo_erro text, ADD COLUMN ultima_conexao timestamptz;
ALTER TABLE private.gastronomia_ifood_eventos ADD COLUMN ack_em timestamptz, ADD COLUMN erro text;
ALTER TABLE private.gastronomia_ifood_pedidos ADD COLUMN revisao_motivo text, ADD COLUMN negociacao jsonb,
 ADD COLUMN importado_em timestamptz, ADD COLUMN impresso_em timestamptz;
CREATE TABLE private.gastronomia_ifood_pagamentos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), empresa_id uuid NOT NULL, merchant_id uuid NOT NULL,
 pedido_id uuid NOT NULL, indice integer NOT NULL, tipo text NOT NULL CHECK(tipo IN ('ONLINE','OFFLINE')),
 forma text NOT NULL, valor_centavos bigint NOT NULL CHECK(valor_centavos>0), bandeira text,
 ativo boolean NOT NULL DEFAULT true, UNIQUE(empresa_id,pedido_id,indice),
 FOREIGN KEY(empresa_id,merchant_id,pedido_id) REFERENCES private.gastronomia_ifood_pedidos(empresa_id,merchant_id,pedido_id)
);
ALTER TABLE private.gastronomia_ifood_pagamentos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.gastronomia_ifood_pagamentos FROM PUBLIC,anon,authenticated;
ALTER TABLE private.gastronomia_ifood_comandos DROP CONSTRAINT gastronomia_ifood_comandos_acao_check;
ALTER TABLE private.gastronomia_ifood_comandos ADD CONSTRAINT gastronomia_ifood_comandos_acao_check CHECK(acao IN ('confirmar','preparar','pronto','despachar','solicitar_cancelamento','aceitar_negociacao','recusar_negociacao'));
-- Preserva integralmente o cadastro existente, delegando apenas as ações antigas.
ALTER FUNCTION private.gastronomia_ifood_admin(text,jsonb) RENAME TO gastronomia_ifood_preparacao;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_preparacao(text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.gastronomia_ifood_admin(p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid:=private.gastronomia_exigir(CASE WHEN p_acao IN ('comando','pedidos') THEN 'gastronomia_pedidos' ELSE 'gastronomia_configurar' END); c private.gastronomia_ifood_config;
 d jsonb:=coalesce(p_dados,'{}'); result jsonb; secret_id uuid; p private.gastronomia_ifood_pedidos; cmd uuid; ac text;
BEGIN
 IF (d->>'empresa_esperada')::uuid IS DISTINCT FROM e THEN RAISE EXCEPTION 'A empresa da sessão mudou.' USING ERRCODE='42501'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':gastronomia_ifood',0));
 SELECT * INTO c FROM private.gastronomia_ifood_config WHERE empresa_id=e FOR UPDATE;
 IF p_acao='pedidos' THEN RETURN private.gastronomia_ifood_painel(e); END IF;
 IF p_acao IN ('obter','salvar','vincular') THEN
  IF p_acao='salvar' AND c.habilitada AND ((d->>'merchant_id')::uuid IS DISTINCT FROM c.merchant_id OR d->>'ambiente' IS DISTINCT FROM c.ambiente) THEN RAISE EXCEPTION 'Pause a conexão antes de alterar a loja.'; END IF;
  result:=private.gastronomia_ifood_preparacao(p_acao,d);
 ELSIF p_acao='credenciais' THEN
  IF c.empresa_id IS NULL OR c.merchant_id IS NULL THEN RAISE EXCEPTION 'Salve primeiro a loja.'; END IF;
  IF c.habilitada THEN RAISE EXCEPTION 'Pause a conexão antes de alterar as credenciais.'; END IF;
  IF coalesce(length(d->>'clientSecret'),0)<20 OR NOT coalesce(d->>'clientId','') ~* '^[a-f0-9-]{36}$' THEN RAISE EXCEPTION 'Confira as credenciais do aplicativo.'; END IF;
  IF c.credencial_id IS NULL THEN
   SELECT vault.create_secret(jsonb_build_object('clientId',d->>'clientId','clientSecret',d->>'clientSecret')::text,'gastronomia_ifood_'||e) INTO secret_id;
  ELSE
   secret_id:=c.credencial_id;
   PERFORM vault.update_secret(secret_id,jsonb_build_object('clientId',d->>'clientId','clientSecret',d->>'clientSecret')::text);
  END IF;
  UPDATE private.gastronomia_ifood_config SET credencial_id=secret_id,ultimo_erro=NULL,versao=versao+1,atualizado_por=auth.uid(),atualizado_em=now() WHERE empresa_id=e;
 ELSIF p_acao='reprocessar' THEN
  UPDATE private.gastronomia_ifood_eventos SET estado='pendente',tentativas=0,proxima_tentativa=NULL WHERE empresa_id=e AND pedido_id=(d->>'pedido_id')::uuid AND estado='falha';
 ELSIF p_acao='pausar' THEN
  UPDATE private.gastronomia_ifood_config SET habilitada=false,versao=versao+1 WHERE empresa_id=e;
 ELSIF p_acao='comando' THEN
  PERFORM private.gastronomia_exigir('gastronomia_pedidos');
  IF NOT coalesce(c.habilitada,false) THEN RAISE EXCEPTION 'Conexão pausada.'; END IF;
  SELECT * INTO p FROM private.gastronomia_ifood_pedidos WHERE empresa_id=e AND merchant_id=c.merchant_id AND pedido_id=(d->>'pedido_id')::uuid FOR UPDATE;
  IF p.pedido_id IS NULL THEN RAISE EXCEPTION 'Pedido não encontrado nesta empresa.' USING ERRCODE='42501'; END IF;
  ac:=d->>'acao';
  IF ac NOT IN ('confirmar','preparar','pronto','despachar','solicitar_cancelamento','aceitar_negociacao','recusar_negociacao') OR ac IS NULL THEN RAISE EXCEPTION 'Comando inválido.'; END IF;
  IF ac IN ('aceitar_negociacao','recusar_negociacao') THEN
   PERFORM private.gastronomia_exigir('gastronomia_cancelar');
   IF p.negociacao->>'disputeId' IS NULL OR coalesce((p.negociacao->>'expiresAt')::timestamptz,now()-interval '1 second')<=now() THEN RAISE EXCEPTION 'Negociação ausente ou expirada.'; END IF;
   IF d#>>'{payload,disputeId}' IS DISTINCT FROM p.negociacao->>'disputeId' THEN RAISE EXCEPTION 'Negociação de outro pedido.'; END IF;
  END IF;
  IF p.estado_ifood IN ('cancelado','concluido') AND ac NOT IN ('aceitar_negociacao','recusar_negociacao') THEN RAISE EXCEPTION 'Pedido encerrado no iFood.'; END IF;
  IF (ac='confirmar' AND p.estado_ifood<>'recebido') OR (ac='preparar' AND p.estado_ifood<>'confirmado') OR (ac='pronto' AND p.estado_ifood NOT IN ('confirmado','em_preparo')) THEN RAISE EXCEPTION 'Aguarde a etapa anterior do pedido no iFood.'; END IF;
  IF ac='confirmar' THEN
   IF p.normalizado='{}' OR jsonb_array_length(coalesce(p.normalizado->'avisos','[]'))>0 THEN RAISE EXCEPTION 'Revise os vínculos e valores do pedido antes de confirmar.'; END IF;
   PERFORM private.gastronomia_ifood_validar_itens(e,p.normalizado);
  END IF;
  IF ac IN ('preparar','pronto','despachar') AND p.atendimento_id IS NULL THEN RAISE EXCEPTION 'Aguarde a confirmação e importação do pedido.'; END IF;
  IF ac='preparar' AND coalesce((p.normalizado->>'agendado')::boolean,false) AND (p.normalizado->>'inicio_preparo')::timestamptz>now() THEN RAISE EXCEPTION 'Aguarde o horário de preparo agendado.'; END IF;
  IF ac='despachar' AND (p.normalizado->>'tipo'<>'DELIVERY' OR p.normalizado->>'entrega_por'<>'MERCHANT' OR p.estado_ifood<>'pronto') THEN RAISE EXCEPTION 'Despacho exige pedido pronto com entrega própria.'; END IF;
  IF ac='solicitar_cancelamento' THEN
   PERFORM private.gastronomia_exigir('gastronomia_cancelar');
   IF length(coalesce(d#>>'{payload,cancellationCode}',''))=0 OR length(coalesce(d#>>'{payload,reason}',''))=0 THEN RAISE EXCEPTION 'Selecione o motivo de cancelamento consultado no iFood.'; END IF;
  END IF;
  -- Um comando incerto não é reenviado. Reconciliar por eventos antes de nova tentativa.
  IF EXISTS(SELECT 1 FROM private.gastronomia_ifood_comandos WHERE empresa_id=e AND pedido_id=p.pedido_id AND acao=ac AND estado IN ('pendente','enviado','incerto','confirmado')) THEN RETURN jsonb_build_object('empresa_id',e,'mensagem','Comando já registrado; aguarde a confirmação do iFood.'); END IF;
  INSERT INTO private.gastronomia_ifood_comandos(empresa_id,pedido_id,chave,acao,payload)
  VALUES(e,p.pedido_id,(d->>'chave')::uuid,ac,coalesce(d->'payload','{}')) RETURNING id INTO cmd;
 ELSE RAISE EXCEPTION 'Ação iFood inválida.'; END IF;
 IF p_acao='comando' THEN RETURN private.gastronomia_ifood_painel(e); END IF;
 SELECT * INTO c FROM private.gastronomia_ifood_config WHERE empresa_id=e;
 IF result IS NULL THEN result:=private.gastronomia_ifood_preparacao('obter',jsonb_build_object('empresa_esperada',e)); END IF;
 RETURN result||jsonb_build_object('conectado',coalesce(c.habilitada,false),'credenciais_configuradas',c.credencial_id IS NOT NULL,
  'ultimo_poll',c.ultimo_poll,'ultimo_erro',c.ultimo_erro,'ultima_conexao',c.ultima_conexao,
  'pedidos',(SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.criado_em DESC),'[]') FROM (
   SELECT pedido_id,estado_ifood,atendimento_id,normalizado,revisao_motivo,negociacao,criado_em,
    (SELECT coalesce(jsonb_agg(jsonb_build_object('acao',acao,'estado',estado,'criado_em',criado_em)),'[]') FROM private.gastronomia_ifood_comandos WHERE empresa_id=e AND pedido_id=p1.pedido_id) comandos
   FROM private.gastronomia_ifood_pedidos p1 WHERE empresa_id=e ORDER BY criado_em DESC LIMIT 100) z));
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_admin(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.gastronomia_ifood_admin(text,jsonb) TO authenticated;
-- O wrapper público antigo é SQL e resolve por nome; aponta para a nova função privada.
CREATE OR REPLACE FUNCTION public.gastronomia_ifood_admin(p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.gastronomia_ifood_admin(p_acao,p_dados) $$;

CREATE FUNCTION public.gastronomia_ifood_worker(p_acao text,p_empresa uuid DEFAULT NULL,p_dados jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c private.gastronomia_ifood_config; x jsonb; p private.gastronomia_ifood_pedidos; ev private.gastronomia_ifood_eventos; out jsonb; cmd private.gastronomia_ifood_comandos;
BEGIN
 IF p_acao='listar' THEN RETURN (SELECT coalesce(jsonb_agg(empresa_id),'[]') FROM private.gastronomia_ifood_config WHERE habilitada AND ambiente='teste'); END IF;
 IF p_acao='cron_validar' THEN
  IF coalesce(p_dados->>'momento','') !~ '^[0-9]{10}$' THEN RETURN 'false'::jsonb; END IF;
  IF abs(extract(epoch FROM clock_timestamp())-(p_dados->>'momento')::bigint)>120 THEN RETURN 'false'::jsonb; END IF;
  RETURN to_jsonb(EXISTS(SELECT 1 FROM vault.decrypted_secrets WHERE name='gastronomia_ifood_cron' AND encode(extensions.hmac((p_dados->>'momento')||':'||(p_dados->>'corpo'),decrypted_secret,'sha256'),'hex')=p_dados->>'assinatura'));
 END IF;
 SELECT * INTO c FROM private.gastronomia_ifood_config WHERE empresa_id=p_empresa FOR UPDATE;
 IF c.credencial_id IS NULL OR c.merchant_id IS NULL THEN RAISE EXCEPTION 'Credenciais ou loja não configuradas.'; END IF;
 -- Liberação inicial somente para a empresa e loja de teste explicitamente autorizadas.
 IF c.ambiente<>'teste' OR c.empresa_id<>'773dfacb-c0e7-4bd9-8eb4-5208818b1848' OR c.merchant_id<>'9dc78f12-d874-4d66-a454-40268effa19d' THEN RAISE EXCEPTION 'Loja ainda não liberada para testes.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.empresas e JOIN public.empresa_modulos m ON m.empresa_id=e.id WHERE e.id=p_empresa AND e.status_conta='aprovado' AND NOT e.bloqueado AND m.modulo='gastronomia' AND m.ativo) THEN RAISE EXCEPTION 'Empresa ou módulo indisponível.'; END IF;
 IF p_acao='config' OR p_acao='reservar' THEN
  IF p_acao='reservar' THEN
   IF NOT c.habilitada OR c.proximo_poll>clock_timestamp() OR c.lease_ate>clock_timestamp() THEN RETURN NULL; END IF;
   UPDATE private.gastronomia_ifood_config SET proximo_poll=clock_timestamp()+interval '30 seconds',lease_ate=clock_timestamp()+interval '90 seconds' WHERE empresa_id=p_empresa;
  END IF;
  RETURN jsonb_build_object('merchant_id',c.merchant_id,'habilitada',c.habilitada,'credenciais',(SELECT decrypted_secret::jsonb FROM vault.decrypted_secrets WHERE id=c.credencial_id),
   'vinculos',(SELECT coalesce(jsonb_agg(to_jsonb(v)),'[]') FROM private.gastronomia_ifood_vinculos v WHERE v.empresa_id=p_empresa));
 ELSIF p_acao='conectar' THEN
  UPDATE private.gastronomia_ifood_config SET habilitada=true,ultima_conexao=now(),ultimo_erro=NULL WHERE empresa_id=p_empresa;
 ELSIF p_acao='liberar' THEN
  UPDATE private.gastronomia_ifood_config SET lease_ate=NULL,ultimo_erro=p_dados->>'erro',
   proximo_poll=greatest(proximo_poll,clock_timestamp()+coalesce((p_dados->>'espera_ms')::numeric,0)*interval '1 millisecond') WHERE empresa_id=p_empresa;
 ELSIF p_acao='eventos' THEN
  IF NOT c.habilitada THEN RAISE EXCEPTION 'Conexão pausada.'; END IF;
  IF jsonb_typeof(p_dados->'eventos') IS DISTINCT FROM 'array' OR jsonb_array_length(p_dados->'eventos')>2000 THEN RAISE EXCEPTION 'Lote inválido.'; END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(p_dados->'eventos') LOOP
   IF (x->>'merchantId')::uuid IS DISTINCT FROM c.merchant_id THEN RAISE EXCEPTION 'Evento de outra loja.'; END IF;
   INSERT INTO private.gastronomia_ifood_eventos(empresa_id,merchant_id,evento_id,pedido_id,codigo,ocorrido_em,payload)
   VALUES(p_empresa,c.merchant_id,(x->>'id')::uuid,nullif(x->>'orderId','')::uuid,coalesce(x->>'fullCode',x->>'code'),(x->>'createdAt')::timestamptz,x) ON CONFLICT DO NOTHING;
  END LOOP;
  UPDATE private.gastronomia_ifood_config SET ultimo_poll=now(),ultimo_erro=NULL WHERE empresa_id=p_empresa;
 ELSIF p_acao='ack' THEN
  UPDATE private.gastronomia_ifood_eventos SET ack_em=now() WHERE empresa_id=p_empresa AND evento_id IN (SELECT value::text::uuid FROM jsonb_array_elements_text(p_dados->'ids'));
 ELSIF p_acao='revisar' THEN
  RETURN (SELECT coalesce(jsonb_agg(pedido_id),'[]') FROM (SELECT pedido_id FROM private.gastronomia_ifood_pedidos WHERE empresa_id=p_empresa AND atendimento_id IS NULL AND estado_ifood='recebido' ORDER BY criado_em DESC LIMIT 20) z);
 ELSIF p_acao='pendentes' THEN
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(z)),'[]') FROM (SELECT * FROM private.gastronomia_ifood_eventos WHERE empresa_id=p_empresa AND estado IN ('pendente','falha') AND tentativas<10 AND coalesce(proxima_tentativa,now())<=now() ORDER BY ocorrido_em,recebido_em LIMIT 30) z);
 ELSIF p_acao='pedido' THEN
  IF (p_dados#>>'{detalhe,merchant,id}')::uuid IS DISTINCT FROM c.merchant_id THEN RAISE EXCEPTION 'Pedido de outra loja.'; END IF;
  INSERT INTO private.gastronomia_ifood_pedidos(empresa_id,merchant_id,pedido_id,detalhe,normalizado,total_centavos,pago_online_centavos,a_cobrar_centavos)
  VALUES(p_empresa,c.merchant_id,(p_dados#>>'{detalhe,id}')::uuid,p_dados->'detalhe',p_dados->'normalizado',(p_dados#>>'{normalizado,total}')::bigint,(p_dados#>>'{normalizado,pago_online}')::bigint,(p_dados#>>'{normalizado,a_cobrar}')::bigint)
  ON CONFLICT(empresa_id,merchant_id,pedido_id) DO UPDATE SET detalhe=excluded.detalhe,normalizado=CASE WHEN gastronomia_ifood_pedidos.atendimento_id IS NULL THEN excluded.normalizado ELSE gastronomia_ifood_pedidos.normalizado END,atualizado_em=now();
 ELSIF p_acao='processar' THEN
  SELECT * INTO ev FROM private.gastronomia_ifood_eventos WHERE empresa_id=p_empresa AND evento_id=(p_dados->>'evento_id')::uuid FOR UPDATE;
  IF ev.estado='processado' THEN RETURN '{}'::jsonb; END IF;
  PERFORM private.gastronomia_ifood_evento(p_empresa,ev.evento_id);
  UPDATE private.gastronomia_ifood_eventos SET estado='processado',erro=NULL WHERE empresa_id=p_empresa AND evento_id=ev.evento_id;
 ELSIF p_acao='falha_evento' THEN
  UPDATE private.gastronomia_ifood_eventos SET estado='falha',erro=left(p_dados->>'erro',300),tentativas=tentativas+1,proxima_tentativa=now()+least(300,power(2,tentativas+1))*interval '1 second' WHERE empresa_id=p_empresa AND evento_id=(p_dados->>'evento_id')::uuid;
 ELSIF p_acao='comandos' THEN
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(z)),'[]') FROM (SELECT * FROM private.gastronomia_ifood_comandos WHERE empresa_id=p_empresa AND estado='pendente' ORDER BY criado_em LIMIT 10) z);
 ELSIF p_acao='reservar_comando' THEN
  IF NOT c.habilitada THEN RETURN NULL; END IF;
  UPDATE private.gastronomia_ifood_comandos SET estado='incerto',tentativas=tentativas+1 WHERE empresa_id=p_empresa AND id=(p_dados->>'id')::uuid AND estado='pendente' AND NOT EXISTS(SELECT 1 FROM private.gastronomia_ifood_pedidos p WHERE p.empresa_id=p_empresa AND p.pedido_id=gastronomia_ifood_comandos.pedido_id AND p.estado_ifood IN ('cancelado','concluido')) RETURNING * INTO cmd;
  RETURN CASE WHEN cmd.id IS NULL THEN NULL ELSE to_jsonb(cmd) END;
 ELSIF p_acao='resultado_comando' THEN
  UPDATE private.gastronomia_ifood_comandos SET estado=p_dados->>'estado' WHERE empresa_id=p_empresa AND id=(p_dados->>'id')::uuid AND estado='incerto' AND p_dados->>'estado' IN ('enviado','incerto','falha');
 ELSIF p_acao='agendados' THEN
  FOR p IN SELECT * FROM private.gastronomia_ifood_pedidos WHERE empresa_id=p_empresa AND estado_ifood IN ('confirmado','em_preparo','pronto') AND atendimento_id IS NULL AND normalizado<>'{}' AND coalesce((normalizado->>'inicio_preparo')::timestamptz,now())<=now() LOOP
   BEGIN PERFORM private.gastronomia_ifood_importar(p_empresa,p.pedido_id); EXCEPTION WHEN OTHERS THEN UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo=left(SQLERRM,300) WHERE empresa_id=p_empresa AND pedido_id=p.pedido_id; END;
  END LOOP;
 ELSE RAISE EXCEPTION 'Operação interna iFood inválida.'; END IF;
 RETURN jsonb_build_object('ok',true);
END $$;
REVOKE ALL ON FUNCTION public.gastronomia_ifood_worker(text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.gastronomia_ifood_worker(text,uuid,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';

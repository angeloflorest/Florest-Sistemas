-- Operação nativa da loja de TESTE já vinculada. Nenhuma loja de produção é ativada.
ALTER TABLE public.gastronomia_99food_sandbox_recebimentos
 ADD COLUMN detalhe jsonb,
 ADD COLUMN status_99food integer,
 ADD COLUMN pronto boolean NOT NULL DEFAULT false,
 ADD COLUMN ultima_consulta timestamptz,
 ADD COLUMN ultimo_erro text;
GRANT UPDATE ON public.gastronomia_99food_sandbox_recebimentos TO service_role;

CREATE TABLE private.gastronomia_99food_sandbox_runtime (
 id boolean PRIMARY KEY DEFAULT true CHECK(id),
 auth_token text, token_expira_em timestamptz,
 token_consultar_apos timestamptz NOT NULL DEFAULT '-infinity',
 token_renovar_apos timestamptz NOT NULL DEFAULT '-infinity',
 token_erro text, ultima_autenticacao timestamptz,
 worker_segredo text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32),'hex'),
 worker_reserva uuid, worker_ate timestamptz,
 ultima_execucao timestamptz, worker_proxima timestamptz, ultimo_erro text
);
INSERT INTO private.gastronomia_99food_sandbox_runtime(id) VALUES(true);
CREATE TABLE private.gastronomia_99food_sandbox_eventos (
 id text PRIMARY KEY CHECK(length(id)=64), tipo text NOT NULL,
 order_id text, payload jsonb NOT NULL,
 recebido_em timestamptz NOT NULL DEFAULT now(),
 processado_em timestamptz, tentativas integer NOT NULL DEFAULT 0,
 tentar_apos timestamptz NOT NULL DEFAULT now(), erro text
);
CREATE INDEX gastronomia_99food_sandbox_eventos_pedido ON private.gastronomia_99food_sandbox_eventos(order_id,recebido_em DESC);
CREATE INDEX gastronomia_99food_sandbox_eventos_fila ON private.gastronomia_99food_sandbox_eventos(tentar_apos,recebido_em) WHERE processado_em IS NULL;
CREATE TABLE private.gastronomia_99food_sandbox_comandos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), chave uuid NOT NULL UNIQUE,
 app_shop_id text NOT NULL DEFAULT 'florest-gastronomia-teste-01' CHECK(app_shop_id='florest-gastronomia-teste-01'),
 order_id text NOT NULL, acao text NOT NULL CHECK(acao IN ('confirmar','pronto','despachar','entregue','retirada','concluir','cancelar','responder_cancelamento','responder_reembolso')),
 payload jsonb NOT NULL DEFAULT '{}',
 estado text NOT NULL DEFAULT 'pendente' CHECK(estado IN ('pendente','enviando','enviado','confirmado','incerto','falha')),
 criado_em timestamptz NOT NULL DEFAULT now(), criado_por uuid NOT NULL,
 atualizado_em timestamptz NOT NULL DEFAULT now(), erro text, request_id text,
 FOREIGN KEY(app_shop_id,order_id) REFERENCES public.gastronomia_99food_sandbox_recebimentos(app_shop_id,order_id)
);
CREATE UNIQUE INDEX gastronomia_99food_sandbox_comando_ativo ON private.gastronomia_99food_sandbox_comandos(order_id) WHERE estado IN ('pendente','enviando','enviado','incerto');
ALTER TABLE private.gastronomia_99food_sandbox_runtime ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_99food_sandbox_eventos ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_99food_sandbox_comandos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.gastronomia_99food_sandbox_runtime,private.gastronomia_99food_sandbox_eventos,private.gastronomia_99food_sandbox_comandos FROM PUBLIC,anon,authenticated;

-- Interface exclusiva do servidor; nenhum segredo é retornado aos usuários.
CREATE FUNCTION private.gastronomia_99food_sandbox_worker(p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r private.gastronomia_99food_sandbox_runtime; d jsonb:=coalesce(p_dados,'{}');
 o public.gastronomia_99food_sandbox_recebimentos; x jsonb; lease uuid; n integer;
BEGIN
 IF p_acao='validar_cron' THEN
  SELECT * INTO r FROM private.gastronomia_99food_sandbox_runtime WHERE id;
  IF coalesce(d->>'momento','') !~ '^[0-9]{10}$' OR abs(extract(epoch FROM clock_timestamp())-(d->>'momento')::numeric)>90 THEN RETURN 'false'; END IF;
  RETURN to_jsonb(encode(extensions.hmac((d->>'momento')||'.'||(d->>'corpo'),r.worker_segredo,'sha256'),'hex')=coalesce(d->>'assinatura',''));
 ELSIF p_acao='reservar' THEN
  lease:=gen_random_uuid();
  UPDATE private.gastronomia_99food_sandbox_runtime SET worker_reserva=lease,worker_ate=now()+interval '90 seconds',worker_proxima=now()+interval '10 seconds'
   WHERE id AND (worker_ate IS NULL OR worker_ate<now()) AND (worker_proxima IS NULL OR worker_proxima<=now());
  IF NOT FOUND THEN RETURN 'null'; END IF;
  RETURN to_jsonb(lease);
 ELSIF p_acao='liberar' THEN
  UPDATE private.gastronomia_99food_sandbox_runtime SET worker_reserva=NULL,worker_ate=NULL,ultima_execucao=now(),ultimo_erro=nullif(left(d->>'erro',500),'') WHERE id AND worker_reserva=(d->>'reserva')::uuid;
  RETURN 'true';
 ELSIF p_acao='token' THEN
  SELECT * INTO r FROM private.gastronomia_99food_sandbox_runtime WHERE id;
  RETURN jsonb_build_object('token',r.auth_token,'expira_em',r.token_expira_em,'consultar_apos',r.token_consultar_apos,'renovar_apos',r.token_renovar_apos);
 ELSIF p_acao='token_reservar' THEN
  UPDATE private.gastronomia_99food_sandbox_runtime SET token_consultar_apos=now()+interval '30 seconds' WHERE id AND token_consultar_apos<=now();
  RETURN to_jsonb(FOUND);
 ELSIF p_acao='token_renovar' THEN
  UPDATE private.gastronomia_99food_sandbox_runtime SET token_renovar_apos=now()+interval '2 minutes' WHERE id AND token_renovar_apos<=now();
  RETURN to_jsonb(FOUND);
 ELSIF p_acao='token_salvar' THEN
  IF length(coalesce(d->>'token','')) NOT BETWEEN 1 AND 4096 OR (d->>'expira_em')::timestamptz<=now() THEN RAISE EXCEPTION 'Token inválido.'; END IF;
  UPDATE private.gastronomia_99food_sandbox_runtime SET auth_token=d->>'token',token_expira_em=(d->>'expira_em')::timestamptz,ultima_autenticacao=now(),token_erro=NULL WHERE id;
  RETURN 'true';
 ELSIF p_acao='token_erro' THEN
  UPDATE private.gastronomia_99food_sandbox_runtime SET token_erro=left(d->>'erro',500),auth_token=NULL,token_expira_em=NULL WHERE id;
  RETURN 'true';
 ELSIF p_acao='evento' THEN
  -- O endpoint já verificou assinatura e vínculo. O RPC também limita a loja de teste.
  x:=d->'payload';
  IF x->>'app_id'<>'5764607791191296200' OR x->>'app_shop_id'<>'florest-gastronomia-teste-01' OR coalesce(x->>'type','')='' THEN RAISE EXCEPTION 'Evento de outra loja.'; END IF;
  IF x#>>'{data,order_info,shop,shop_id}' IS NOT NULL AND x#>>'{data,order_info,shop,shop_id}'<>'5764619883330929453' THEN RAISE EXCEPTION 'Loja divergente.'; END IF;
  IF coalesce(d->>'order_id','')<>'' AND (d->>'order_id') !~ '^[1-9][0-9]{0,18}$' THEN RAISE EXCEPTION 'Pedido inválido.'; END IF;
  INSERT INTO private.gastronomia_99food_sandbox_eventos(id,tipo,order_id,payload,processado_em)
   VALUES(d->>'id',x->>'type',nullif(d->>'order_id',''),x,CASE WHEN coalesce(d->>'order_id','')='' THEN now() END) ON CONFLICT DO NOTHING;
  IF coalesce(d->>'order_id','')<>'' THEN
   INSERT INTO public.gastronomia_99food_sandbox_recebimentos(app_shop_id,order_id,order_index,detalhe,status_99food)
    VALUES('florest-gastronomia-teste-01',d->>'order_id',CASE WHEN (x#>>'{data,order_info,order_index}') ~ '^[0-9]{1,9}$' THEN (x#>>'{data,order_info,order_index}')::integer END,
     CASE WHEN x->>'type'='orderNew' THEN x#>'{data,order_info}' END,CASE WHEN x->>'type'='orderNew' THEN 100 END)
    ON CONFLICT DO NOTHING;
   IF x->>'type'='orderReady' THEN UPDATE public.gastronomia_99food_sandbox_recebimentos SET pronto=true WHERE app_shop_id='florest-gastronomia-teste-01' AND order_id=d->>'order_id'; END IF;
  END IF;
  RETURN 'true';
 ELSIF p_acao='fila' THEN
  -- No máximo quatro consultas por execução; abaixo do limite de 10/10s da API.
  RETURN jsonb_build_object('eventos',(SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM(SELECT id,order_id,tipo FROM private.gastronomia_99food_sandbox_eventos WHERE processado_em IS NULL AND tentar_apos<=now() AND tentativas<10 ORDER BY recebido_em LIMIT 3)t),
   'comando',(SELECT to_jsonb(t) FROM(SELECT id,order_id,acao,payload,estado,atualizado_em FROM private.gastronomia_99food_sandbox_comandos WHERE estado IN ('pendente','enviando','enviado','incerto') ORDER BY CASE WHEN estado='pendente' THEN 0 ELSE 1 END,atualizado_em LIMIT 1)t),
   'reconciliar',(SELECT coalesce(jsonb_agg(order_id),'[]') FROM(SELECT order_id FROM public.gastronomia_99food_sandbox_recebimentos WHERE app_shop_id='florest-gastronomia-teste-01' AND (ultima_consulta IS NULL OR ultima_consulta<now()-interval '2 minutes') AND recebido_em>now()-interval '3 days' AND (status_99food IS NULL OR status_99food NOT IN (600,901,902,903,921,922,923,941,942,943,944,945,946,961,971,981)) ORDER BY ultima_consulta NULLS FIRST LIMIT 1)t));
 ELSIF p_acao='evento_resultado' THEN
  UPDATE private.gastronomia_99food_sandbox_eventos SET tentativas=tentativas+1,erro=nullif(left(d->>'erro',500),''),processado_em=CASE WHEN coalesce(d->>'erro','')='' THEN now() END,tentar_apos=now()+least(interval '15 minutes',interval '30 seconds'*power(2,least(tentativas,5))) WHERE id=d->>'id';
  RETURN 'true';
 ELSIF p_acao='pedido' THEN
  SELECT * INTO o FROM public.gastronomia_99food_sandbox_recebimentos WHERE app_shop_id='florest-gastronomia-teste-01' AND order_id=d->>'order_id';
  RETURN to_jsonb(o)||jsonb_build_object('solicitacoes',(SELECT coalesce(jsonb_agg((payload->'data')||jsonb_build_object('tipo',tipo,'recebido_em',recebido_em)),'[]') FROM private.gastronomia_99food_sandbox_eventos WHERE order_id=o.order_id AND tipo IN ('orderCancelApply','orderRefundApply')));
 ELSIF p_acao='detalhe' THEN
  x:=d->'detalhe';n:=(x->>'status')::integer;
  IF x->>'order_id' IS DISTINCT FROM d->>'order_id' OR coalesce(x#>>'{shop,shop_id}',x->>'shop_id') IS DISTINCT FROM '5764619883330929453' OR n IS NULL THEN RAISE EXCEPTION 'Detalhe de outra loja.'; END IF;
  SELECT * INTO o FROM public.gastronomia_99food_sandbox_recebimentos WHERE app_shop_id='florest-gastronomia-teste-01' AND order_id=d->>'order_id' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não recebido.'; END IF;
  -- Não reabrir pedido terminal com uma consulta atrasada.
  IF (o.status_99food=600 OR o.status_99food>=900) AND n<600 THEN RETURN to_jsonb(o); END IF;
  UPDATE public.gastronomia_99food_sandbox_recebimentos SET detalhe=x,status_99food=n,order_index=coalesce((x->>'order_index')::integer,order_index),
    estado=CASE WHEN n>=900 OR n=600 THEN 'encerrado' WHEN n>=200 THEN 'aceito' ELSE 'recebido' END,ultima_consulta=now(),atualizado_em=now(),ultimo_erro=NULL
   WHERE app_shop_id='florest-gastronomia-teste-01' AND order_id=d->>'order_id' RETURNING * INTO o;
  RETURN to_jsonb(o);
 ELSIF p_acao='pedido_erro' THEN
  UPDATE public.gastronomia_99food_sandbox_recebimentos SET ultimo_erro=left(d->>'erro',500),ultima_consulta=now() WHERE app_shop_id='florest-gastronomia-teste-01' AND order_id=d->>'order_id'; RETURN 'true';
 ELSIF p_acao='comando_resultado' THEN
  UPDATE private.gastronomia_99food_sandbox_comandos SET estado=d->>'estado',erro=nullif(left(d->>'erro',500),''),request_id=coalesce(nullif(d->>'request_id',''),request_id),atualizado_em=now() WHERE id=(d->>'id')::uuid;
  RETURN 'true';
 END IF;
 RAISE EXCEPTION 'Operação interna inválida.';
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_sandbox_worker(text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.gastronomia_99food_sandbox_worker(p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.gastronomia_99food_sandbox_worker(p_acao,p_dados)$$;
REVOKE ALL ON FUNCTION public.gastronomia_99food_sandbox_worker(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.gastronomia_99food_sandbox_worker(text,jsonb),public.gastronomia_99food_sandbox_worker(text,jsonb) TO service_role;

CREATE OR REPLACE FUNCTION private.gastronomia_99food_sandbox_pedidos(p_empresa uuid,p_order_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE empresa uuid:=private.empresa_id_ativa();
BEGIN
 IF auth.uid() IS NULL OR empresa IS DISTINCT FROM p_empresa OR empresa IS DISTINCT FROM '773dfacb-c0e7-4bd9-8eb4-5208818b1848'::uuid THEN RETURN '[]'; END IF;
 PERFORM private.gastronomia_exigir('gastronomia_pedidos');
 RETURN(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY recebido_em DESC),'[]') FROM(
  SELECT p.order_id,p.order_index,p.recebido_em,p.estado,p.status_99food,p.pronto,p.detalhe,p.ultima_consulta,p.ultimo_erro,
   (SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY criado_em DESC),'[]') FROM(SELECT id,acao,estado,criado_em,atualizado_em,erro,request_id FROM private.gastronomia_99food_sandbox_comandos WHERE order_id=p.order_id ORDER BY criado_em DESC LIMIT 20)c) comandos,
   (SELECT coalesce(jsonb_agg(jsonb_build_object('tipo',ev.tipo,'recebido_em',ev.recebido_em,'erro',ev.erro,'dados',CASE WHEN ev.tipo IN ('orderCancelApply','orderRefundApply') THEN ev.payload->'data' END) ORDER BY ev.recebido_em DESC),'[]') FROM(SELECT * FROM private.gastronomia_99food_sandbox_eventos WHERE order_id=p.order_id ORDER BY recebido_em DESC LIMIT 20)ev) eventos
  FROM public.gastronomia_99food_sandbox_recebimentos p WHERE p.app_shop_id='florest-gastronomia-teste-01' AND (p_order_id IS NULL OR p.order_id=p_order_id) ORDER BY p.recebido_em DESC LIMIT 30)t);
END $$;
CREATE FUNCTION private.gastronomia_99food_sandbox_admin(p_empresa uuid,p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE empresa uuid:=private.empresa_id_ativa(); d jsonb:=coalesce(p_dados,'{}'); o public.gastronomia_99food_sandbox_recebimentos; cmd private.gastronomia_99food_sandbox_comandos;
BEGIN
 IF auth.uid() IS NULL OR empresa IS DISTINCT FROM p_empresa OR empresa IS DISTINCT FROM '773dfacb-c0e7-4bd9-8eb4-5208818b1848'::uuid THEN RAISE EXCEPTION 'Empresa indisponível.' USING ERRCODE='42501'; END IF;
 PERFORM private.gastronomia_exigir('gastronomia_pedidos');
 IF p_acao='estado' THEN
  RETURN(SELECT jsonb_build_object('ambiente','teste','token_valido',auth_token IS NOT NULL AND token_expira_em>now(),'token_expira_em',token_expira_em,'erro',coalesce(token_erro,ultimo_erro),'ultima_execucao',ultima_execucao,'ultima_autenticacao',ultima_autenticacao) FROM private.gastronomia_99food_sandbox_runtime WHERE id);
 END IF;
 IF p_acao NOT IN ('confirmar','pronto','despachar','entregue','retirada','concluir','cancelar','responder_cancelamento','responder_reembolso') OR p_acao IS NULL THEN RAISE EXCEPTION 'Ação inválida.'; END IF;
 IF d->>'chave' IS NULL THEN RAISE EXCEPTION 'Chave obrigatória.'; END IF;
 IF p_acao IN ('cancelar','responder_cancelamento','responder_reembolso') THEN PERFORM private.gastronomia_exigir('gastronomia_cancelar'); END IF;
 SELECT * INTO o FROM public.gastronomia_99food_sandbox_recebimentos WHERE app_shop_id='florest-gastronomia-teste-01' AND order_id=d->>'order_id' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Pedido desta loja não encontrado.'; END IF;
 SELECT * INTO cmd FROM private.gastronomia_99food_sandbox_comandos WHERE chave=(d->>'chave')::uuid;
 IF FOUND THEN IF cmd.order_id<>o.order_id OR cmd.acao<>p_acao OR cmd.criado_por<>auth.uid() OR cmd.payload<>coalesce(d->'payload','{}') THEN RAISE EXCEPTION 'Chave reutilizada com dados diferentes.'; END IF;RETURN jsonb_build_object('id',cmd.id,'estado',cmd.estado); END IF;
 IF p_acao IN ('responder_cancelamento','responder_reembolso') AND EXISTS(SELECT 1 FROM private.gastronomia_99food_sandbox_comandos WHERE order_id=o.order_id AND acao=p_acao AND payload->>'apply_id'=d#>>'{payload,apply_id}' AND estado IN ('enviado','confirmado','incerto')) THEN RAISE EXCEPTION 'Esta solicitação já foi respondida ou aguarda confirmação.'; END IF;
 IF EXISTS(SELECT 1 FROM private.gastronomia_99food_sandbox_comandos WHERE order_id=o.order_id AND estado IN ('pendente','enviando','enviado','incerto')) THEN RAISE EXCEPTION 'Existe uma operação pendente. Consulte o estado antes de repetir.'; END IF;
 IF o.status_99food>=900 OR o.status_99food=600 THEN RAISE EXCEPTION 'Pedido encerrado na 99Food.'; END IF;
 IF length(coalesce(d->'payload','{}')::text)>8000 THEN RAISE EXCEPTION 'Dados excessivos.'; END IF;
 INSERT INTO private.gastronomia_99food_sandbox_comandos(chave,order_id,acao,payload,criado_por) VALUES((d->>'chave')::uuid,o.order_id,p_acao,coalesce(d->'payload','{}'),auth.uid()) RETURNING * INTO cmd;
 RETURN jsonb_build_object('id',cmd.id,'estado',cmd.estado);
END $$;
CREATE FUNCTION public.gastronomia_99food_sandbox_admin(p_empresa uuid,p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.gastronomia_99food_sandbox_admin(p_empresa,p_acao,p_dados)$$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_sandbox_admin(uuid,text,jsonb),public.gastronomia_99food_sandbox_admin(uuid,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.gastronomia_99food_sandbox_admin(uuid,text,jsonb),public.gastronomia_99food_sandbox_admin(uuid,text,jsonb) TO authenticated;

CREATE FUNCTION private.gastronomia_99food_sandbox_disparar() RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE instante text:=floor(extract(epoch FROM clock_timestamp()))::bigint::text; corpo text:=jsonb_build_object('acao','worker')::text; assinatura text; req bigint;
BEGIN
 SELECT encode(extensions.hmac(instante||'.'||corpo,worker_segredo,'sha256'),'hex') INTO assinatura FROM private.gastronomia_99food_sandbox_runtime WHERE id;
 SELECT net.http_post(url:='https://etulhyboogqhyyevpnlo.supabase.co/functions/v1/gastronomia-99food-sandbox-aceite',body:=corpo::jsonb,headers:=jsonb_build_object('Content-Type','application/json','x-99food-momento',instante,'x-99food-assinatura',assinatura),timeout_milliseconds:=55000) INTO req;
 RETURN req;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_sandbox_disparar() FROM PUBLIC,anon,authenticated,service_role;
-- O agendamento será habilitado após a publicação e validação do receptor.
NOTIFY pgrst,'reload schema';

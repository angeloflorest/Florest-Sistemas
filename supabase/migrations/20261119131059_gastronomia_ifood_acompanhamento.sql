-- Rastreamento do retorno real e proteção contra fechamento com alteração parcial pendente.
ALTER TABLE private.gastronomia_ifood_pedidos ADD COLUMN alteracao jsonb;
ALTER TABLE private.gastronomia_ifood_comandos ADD COLUMN motivos_consultados_em timestamptz;
CREATE FUNCTION private.gastronomia_ifood_guardar_alteracao(e uuid,event_id uuid,n jsonb) RETURNS void LANGUAGE plpgsql SET search_path='' AS $fn$
DECLARE ev private.gastronomia_ifood_eventos;p private.gastronomia_ifood_pedidos;
BEGIN
 SELECT * INTO ev FROM private.gastronomia_ifood_eventos WHERE empresa_id=e AND evento_id=event_id AND codigo IN ('ORDER_PATCHED','OPA');
 IF ev.evento_id IS NULL THEN RETURN;END IF;
 SELECT * INTO p FROM private.gastronomia_ifood_pedidos WHERE empresa_id=e AND pedido_id=ev.pedido_id AND merchant_id=ev.merchant_id FOR UPDATE;
 IF p.pedido_id IS NULL OR n->>'id' IS DISTINCT FROM p.pedido_id::text OR n->>'merchant_id' IS DISTINCT FROM p.merchant_id::text THEN RAISE EXCEPTION 'Alteração de outro pedido ou loja.';END IF;
 IF p.alteracao->>'evento_id'=event_id::text OR (p.alteracao->>'ocorrido_em')::timestamptz>ev.ocorrido_em THEN RETURN;END IF;
 UPDATE private.gastronomia_ifood_pedidos SET alteracao=jsonb_build_object('evento_id',event_id,'ocorrido_em',ev.ocorrido_em,'anterior',CASE WHEN coalesce((p.alteracao->>'requer_conciliacao')::boolean,false) THEN p.alteracao->'anterior' ELSE p.normalizado END,'atual',n,'requer_conciliacao',p.atendimento_id IS NOT NULL),
 total_centavos=CASE WHEN p.atendimento_id IS NULL THEN (n->>'total')::bigint ELSE total_centavos END,
 pago_online_centavos=CASE WHEN p.atendimento_id IS NULL THEN (n->>'pago_online')::bigint ELSE pago_online_centavos END,
 a_cobrar_centavos=CASE WHEN p.atendimento_id IS NULL THEN (n->>'a_cobrar')::bigint ELSE a_cobrar_centavos END WHERE empresa_id=e AND pedido_id=p.pedido_id;
END $fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_guardar_alteracao(uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
DO $patch$
DECLARE src text;old text;sig text;
BEGIN
 src:=pg_get_functiondef('public.gastronomia_ifood_worker(text,uuid,jsonb)'::regprocedure);
 old:='ELSIF p_acao=''pedido'' THEN';IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Ramo de pedido divergente';END IF;
 src:=replace(src,old,old||E'\n  IF p_dados->>''evento_id'' IS NOT NULL THEN PERFORM private.gastronomia_ifood_guardar_alteracao(p_empresa,(p_dados->>''evento_id'')::uuid,p_dados->''normalizado'');END IF;');
 old:='status_http=nullif((p_dados->>''status_http'')::integer,0) WHERE';IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Retorno de comando divergente';END IF;
 src:=replace(src,old,'status_http=nullif((p_dados->>''status_http'')::integer,0),motivos_consultados_em=coalesce((p_dados->>''motivos_consultados_em'')::timestamptz,motivos_consultados_em) WHERE');
 old:='ELSIF p_acao=''reservar_comando'' THEN';IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Reserva divergente';END IF;
 src:=replace(src,old,old||E'\n  UPDATE private.gastronomia_ifood_comandos cmd_pendente SET estado=''falha'',erro=''Pedido alterado pelo iFood: concilie os valores antes de prosseguir.'' WHERE cmd_pendente.empresa_id=p_empresa AND cmd_pendente.id=(p_dados->>''id'')::uuid AND cmd_pendente.estado=''pendente'' AND cmd_pendente.acao IN (''confirmar'',''preparar'',''pronto'',''despachar'') AND EXISTS(SELECT 1 FROM private.gastronomia_ifood_pedidos ip WHERE ip.empresa_id=p_empresa AND ip.pedido_id=cmd_pendente.pedido_id AND coalesce((ip.alteracao->>''requer_conciliacao'')::boolean,false));');EXECUTE src;
 src:=pg_get_functiondef('private.gastronomia_ifood_evento(uuid,uuid)'::regprocedure);
 old:='novo:=CASE ev.codigo';IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Evento divergente';END IF;
 src:=replace(src,old,$new$IF ev.codigo IN ('ORDER_PATCHED','OPA') THEN
  IF (p.alteracao->>'ocorrido_em')::timestamptz>ev.ocorrido_em THEN RETURN;END IF;
  IF p.alteracao->>'evento_id' IS DISTINCT FROM ev.evento_id::text THEN RAISE EXCEPTION 'Consulte os detalhes atualizados antes de processar a alteração.';END IF;
  UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo=CASE WHEN atendimento_id IS NOT NULL THEN 'Alteração parcial recebida do iFood. Concilie itens, pagamentos e eventual documento fiscal antes do fechamento.' ELSE NULL END WHERE empresa_id=p_e AND pedido_id=p.pedido_id;
  INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(p_e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
  RETURN;
 END IF;
 novo:=CASE ev.codigo$new$);EXECUTE src;
 src:=pg_get_functiondef('private.gastronomia_ifood_encerrar(uuid,uuid)'::regprocedure);
 old:='BEGIN';src:=replace(src,old,old||E'\n IF EXISTS(SELECT 1 FROM private.gastronomia_ifood_pedidos WHERE empresa_id=p_empresa AND pedido_id=p_pedido AND coalesce((alteracao->>''requer_conciliacao'')::boolean,false)) THEN RETURN false;END IF;');EXECUTE src;
 src:=pg_get_functiondef('public.gastronomia_ifood_receber(uuid,uuid,numeric,text,uuid)'::regprocedure);
 old:='IF ip.atendimento_id IS NULL';IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Recebimento divergente';END IF;
 src:=replace(src,old,'IF coalesce((ip.alteracao->>''requer_conciliacao'')::boolean,false) THEN RAISE EXCEPTION ''Pedido alterado pelo iFood: concilie o saldo presencial antes de receber.'';END IF; '||old);EXECUTE src;
 FOREACH sig IN ARRAY ARRAY['private.gastronomia_ifood_painel(uuid)','public.gastronomia_pedidos_data(date,uuid)'] LOOP
  src:=pg_get_functiondef(sig::regprocedure);
  IF sig LIKE 'private.%' THEN old:='p.normalizado,';src:=replace(src,old,old||'p.alteracao,');ELSE old:='ip.normalizado,';src:=replace(src,old,old||'ip.alteracao,');END IF;EXECUTE src;
 END LOOP;
END $patch$;
-- Histórico só é consultado ao abrir o detalhe: evita sobrecarregar a lista diária.
CREATE FUNCTION public.gastronomia_ifood_historico(p_empresa uuid,p_pedido uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_pedidos');evs jsonb;cmds jsonb;
BEGIN
 IF p_empresa IS DISTINCT FROM e OR NOT EXISTS(SELECT 1 FROM private.gastronomia_ifood_pedidos WHERE empresa_id=e AND pedido_id=p_pedido) THEN RAISE EXCEPTION 'Pedido de outra empresa.' USING ERRCODE='42501';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY ocorrido_em DESC),'[]') INTO evs FROM(SELECT evento_id,codigo,ocorrido_em,recebido_em,ack_em,estado,erro,payload#>>'{metadata,CANCEL_ORIGIN}' origem,payload#>>'{metadata,CANCEL_CODE}' motivo_codigo,payload#>>'{metadata,CANCEL_REASON}' motivo FROM private.gastronomia_ifood_eventos WHERE empresa_id=e AND pedido_id=p_pedido ORDER BY ocorrido_em DESC LIMIT 60)t;
 SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY criado_em DESC),'[]') INTO cmds FROM(SELECT id,acao,estado,criado_em,status_http,erro,motivos_consultados_em,payload->>'cancellationCode' motivo_codigo,payload->>'reason' motivo FROM private.gastronomia_ifood_comandos WHERE empresa_id=e AND pedido_id=p_pedido ORDER BY criado_em DESC LIMIT 60)t;
 RETURN jsonb_build_object('empresa_id',e,'pedido_id',p_pedido,'eventos',evs,'comandos',cmds);
END $fn$;
REVOKE ALL ON FUNCTION public.gastronomia_ifood_historico(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_ifood_historico(uuid,uuid) TO authenticated;

-- Order/Events: estado do provedor independente de reimportação, ACK recuperável e evidência por UUID.
ALTER TABLE private.gastronomia_ifood_comandos ADD COLUMN enviado_em timestamptz, ADD COLUMN confirmado_em timestamptz;
DO $patch$
DECLARE src text;old text;
BEGIN
 src:=pg_get_functiondef('public.gastronomia_ifood_worker(text,uuid,jsonb)'::regprocedure);
 old:='ELSIF p_acao=''pendentes'' THEN';
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Worker divergente: pendentes';END IF;
 src:=replace(src,old,$new$ELSIF p_acao='acks_pendentes' THEN
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id',evento_id,'merchantId',merchant_id)),'[]') FROM (SELECT evento_id,merchant_id FROM private.gastronomia_ifood_eventos WHERE empresa_id=p_empresa AND ack_em IS NULL ORDER BY recebido_em LIMIT 2000) z);
 ELSIF p_acao='pendentes' THEN$new$);
 old:='SELECT * FROM private.gastronomia_ifood_eventos WHERE empresa_id=p_empresa AND estado IN (''pendente'',''falha'')';
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Worker divergente: consulta de eventos';END IF;
 src:=replace(src,old,$new$SELECT evt_queue.*, (evt_queue.codigo IN ('ORDER_PATCHED','OPA') OR NOT EXISTS(SELECT 1 FROM private.gastronomia_ifood_pedidos ip WHERE ip.empresa_id=p_empresa AND ip.merchant_id=evt_queue.merchant_id AND ip.pedido_id=evt_queue.pedido_id AND ip.normalizado<>'{}')) consultar_detalhe FROM private.gastronomia_ifood_eventos evt_queue WHERE empresa_id=p_empresa AND estado IN ('pendente','falha')$new$);
 old:='atendimento_id IS NULL AND estado_ifood=''recebido'' ORDER BY criado_em DESC LIMIT 20';
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Worker divergente: revisões';END IF;
 src:=replace(src,old,$new$atendimento_id IS NULL AND estado_ifood IN ('recebido','confirmado','em_preparo','pronto') AND jsonb_array_length(coalesce(normalizado->'avisos','[]'))>0 ORDER BY criado_em DESC LIMIT 5$new$);
 old:='status_http=nullif((p_dados->>''status_http'')::integer,0),';
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Worker divergente: resultado';END IF;
 src:=replace(src,old,old||$new$enviado_em=CASE WHEN p_dados->>'estado'='enviado' THEN clock_timestamp() ELSE enviado_em END,$new$);
 old:='IF NOT c.habilitada THEN RETURN NULL; END IF;';
 src:=replace(src,old,$new$UPDATE private.gastronomia_ifood_comandos q SET estado='falha',erro='Cancelamento em andamento. Aguarde o resultado do iFood.' WHERE q.empresa_id=p_empresa AND q.id=(p_dados->>'id')::uuid AND q.estado='pendente' AND q.acao IN ('confirmar','preparar','pronto','despachar') AND EXISTS(SELECT 1 FROM private.gastronomia_ifood_comandos c2 WHERE c2.empresa_id=p_empresa AND c2.pedido_id=q.pedido_id AND c2.acao='solicitar_cancelamento' AND c2.estado IN ('pendente','enviado','incerto'));
  UPDATE private.gastronomia_ifood_comandos q SET estado='falha',erro='Negociação expirada ou já resolvida pelo iFood.' WHERE q.empresa_id=p_empresa AND q.id=(p_dados->>'id')::uuid AND q.estado='pendente' AND q.acao IN ('aceitar_negociacao','recusar_negociacao','alternativa_negociacao') AND NOT EXISTS(SELECT 1 FROM private.gastronomia_ifood_pedidos ip WHERE ip.empresa_id=p_empresa AND ip.pedido_id=q.pedido_id AND ip.negociacao->>'disputeId'=q.payload->>'disputeId' AND ip.negociacao->>'status' IS NULL AND (ip.negociacao->>'expiresAt')::timestamptz>clock_timestamp());
  IF NOT c.habilitada THEN RETURN NULL; END IF;$new$);EXECUTE src;

 src:=pg_get_functiondef('private.gastronomia_ifood_evento(uuid,uuid)'::regprocedure);
 old:='novo:=CASE ev.codigo';
 src:=replace(src,old,$new$IF ev.codigo IN ('DELIVERY_ADDRESS_CHANGE_REQUESTED','DAR') THEN
  IF jsonb_typeof(ev.payload#>'{metadata,address}') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Mudança de endereço sem endereço válido.';END IF;
  IF EXISTS(SELECT 1 FROM private.gastronomia_ifood_eventos newer WHERE newer.empresa_id=p_e AND newer.pedido_id=p.pedido_id AND newer.codigo IN ('DELIVERY_ADDRESS_CHANGE_REQUESTED','DAR') AND newer.estado='processado' AND newer.ocorrido_em>ev.ocorrido_em) THEN RETURN;END IF;
  UPDATE private.gastronomia_ifood_pedidos SET detalhe=jsonb_set(jsonb_set(detalhe,'{delivery}',coalesce(detalhe->'delivery','{}')),'{delivery,deliveryAddress}',ev.payload#>'{metadata,address}'),revisao_motivo='Endereço atualizado pelo iFood. Avise a expedição e o entregador.' WHERE empresa_id=p_e AND pedido_id=p.pedido_id;
  IF p.atendimento_id IS NOT NULL THEN UPDATE public.gastronomia_atendimentos SET endereco=left(concat_ws(', ',ev.payload#>>'{metadata,address,streetName}',ev.payload#>>'{metadata,address,streetNumber}',ev.payload#>>'{metadata,address,neighborhood}',ev.payload#>>'{metadata,address,city}'),500),referencia=left(ev.payload#>>'{metadata,address,reference}',300),versao=versao+1 WHERE empresa_id=p_e AND id=p.atendimento_id;END IF;
  INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(p_e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;RETURN;
 ELSIF ev.codigo IN ('RECOMMENDED_PREPARATION_START','RPS','DELIVERY_GROUP_ASSOCIATED','DGAC') THEN
  -- Eventos informativos não alteram nem regridem o estado operacional.
  RETURN;
 END IF;
 novo:=CASE ev.codigo$new$);
 src:=replace(src,'WHEN ''PREPARATION_STARTED'' THEN ''em_preparo''','WHEN ''PREPARATION_STARTED'' THEN ''em_preparo'' WHEN ''PRS'' THEN ''em_preparo''');
 src:=replace(src,'UPDATE private.gastronomia_ifood_comandos SET estado=''falha'' WHERE empresa_id=p_e AND pedido_id=ev.pedido_id AND acao=''solicitar_cancelamento''','UPDATE private.gastronomia_ifood_comandos SET estado=''falha'',erro=''iFood recusou o cancelamento: ''||left(coalesce(ev.payload#>>''{metadata,reason}'',ev.payload#>>''{metadata,details}'',''confira o histórico do pedido''),250) WHERE empresa_id=p_e AND pedido_id=ev.pedido_id AND acao=''solicitar_cancelamento''');
 old:='UPDATE private.gastronomia_ifood_comandos SET estado=''confirmado'' WHERE empresa_id=p_e AND pedido_id=p.pedido_id AND estado IN (''enviado'',''incerto'')';
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Evento divergente: comandos';END IF;
 src:=replace(src,old,'UPDATE private.gastronomia_ifood_comandos SET estado=''confirmado'',confirmado_em=ev.ocorrido_em WHERE empresa_id=p_e AND pedido_id=p.pedido_id AND criado_em<=ev.ocorrido_em+interval ''1 minute'' AND estado IN (''enviado'',''incerto'')');
 src:=replace(src,$old$coalesce(ev.payload#>>'{metadata,CANCEL_ORIGIN}',ev.payload#>>'{metadata,ORIGIN}','')<>'SCHEDULER'$old$,$new$(coalesce(ev.payload#>>'{metadata,CANCEL_ORIGIN}','')='RESTAURANT' OR (coalesce(ev.payload#>>'{metadata,CANCEL_ORIGIN}','')<>'SCHEDULER' AND coalesce(ev.payload#>>'{metadata,ORIGIN}',ev.payload#>>'{metadata,additional_info,ORIGIN}','')='ORDER_API'))$new$);
 old:='THEN a:=private.gastronomia_ifood_importar(p_e,p.pedido_id); ELSE a:=p.atendimento_id; END IF;';
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Evento divergente: importação';END IF;
 src:=replace(src,old,$new$THEN
  BEGIN a:=private.gastronomia_ifood_importar(p_e,p.pedido_id);
  EXCEPTION WHEN OTHERS THEN UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo='Status recebido do iFood; importação local pendente: '||left(SQLERRM,220) WHERE empresa_id=p_e AND pedido_id=p.pedido_id;END;
 ELSE a:=p.atendimento_id; END IF;$new$);
 -- A confirmação remota permanece gravada mesmo se estoque/vínculo/impressão falhar localmente.
 src:=replace(src,'IF a IS NULL THEN RETURN; END IF;',$new$IF a IS NULL THEN INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(p_e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;RETURN;END IF;$new$);EXECUTE src;

 src:=pg_get_functiondef('private.gastronomia_ifood_admin(text,jsonb)'::regprocedure);
 old:='ac:=d->>''acao'';';
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Admin divergente: comando';END IF;
 src:=replace(src,old,old||$new$
  IF ac IN ('confirmar','preparar','pronto','despachar') AND EXISTS(SELECT 1 FROM private.gastronomia_ifood_comandos WHERE empresa_id=e AND pedido_id=p.pedido_id AND acao='solicitar_cancelamento' AND estado IN ('pendente','enviado','incerto')) THEN RAISE EXCEPTION 'Cancelamento em andamento. Aguarde o resultado do iFood.';END IF;
  IF ac IN ('confirmar','preparar','pronto','despachar') AND coalesce((p.alteracao->>'requer_conciliacao')::boolean,false) THEN RAISE EXCEPTION 'Pedido alterado pelo iFood. Concilie os valores antes de continuar.';END IF;
 $new$);EXECUTE src;
END $patch$;

-- Recebimento presencial não pode concorrer com um cancelamento solicitado.
DO $patch$
DECLARE src text;old text;
BEGIN
 src:=pg_get_functiondef('public.gastronomia_ifood_receber(uuid,uuid,numeric,text,uuid)'::regprocedure);
 old:='IF ip.atendimento_id IS NULL';IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Recebimento divergente';END IF;
 src:=replace(src,old,$new$IF EXISTS(SELECT 1 FROM private.gastronomia_ifood_comandos WHERE empresa_id=e AND pedido_id=p_pedido AND acao='solicitar_cancelamento' AND estado IN ('pendente','enviado','incerto')) THEN RAISE EXCEPTION 'Cancelamento em andamento. Aguarde o resultado do iFood antes de receber.';END IF;
 IF ip.atendimento_id IS NULL$new$);EXECUTE src;
END $patch$;

-- O evento oferece allowedsAdditionalTime*, enquanto o corpo da resposta usa additionalTimeInMinutes/reason.
DO $patch$
DECLARE src text;old text;
BEGIN
 src:=pg_get_functiondef('private.gastronomia_ifood_resposta(jsonb,text,jsonb)'::regprocedure);
 old:='coalesce(alt#>''{metadata,allowedsAdditionalTimeInMinutes}'',''[]'')';
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Validador de negociação divergente';END IF;
 src:=replace(src,old,'coalesce(alt#>''{metadata,allowedsAdditionalTimeInMinutes}'',alt#>''{metadata,additionalTimeInMinutes}'',''[]'')');
 src:=replace(src,'coalesce(alt#>''{metadata,allowedsAdditionalTimeReasons}'',''[]'')','coalesce(alt#>''{metadata,allowedsAdditionalTimeReasons}'',alt#>''{metadata,reasons}'',''[]'')');EXECUTE src;
END $patch$;

-- Evidências locais: não representam aprovação do avaliador iFood nem inventam dados históricos.
CREATE OR REPLACE FUNCTION public.gastronomia_ifood_historico(p_empresa uuid,p_pedido uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_pedidos');p private.gastronomia_ifood_pedidos;evs jsonb;cmds jsonb;
BEGIN
 SELECT * INTO p FROM private.gastronomia_ifood_pedidos WHERE empresa_id=e AND pedido_id=p_pedido;
 IF p_empresa IS DISTINCT FROM e OR p.pedido_id IS NULL THEN RAISE EXCEPTION 'Pedido de outra empresa.' USING ERRCODE='42501';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY ocorrido_em DESC),'[]') INTO evs FROM(SELECT evento_id,codigo,ocorrido_em,recebido_em,ack_em,estado,erro,coalesce(payload#>>'{metadata,CANCEL_ORIGIN}',payload#>>'{metadata,ORIGIN}',payload#>>'{metadata,additional_info,ORIGIN}') origem,coalesce(payload#>>'{metadata,CLIENT_ID}',payload#>>'{metadata,additional_info,CLIENT_ID}') aplicativo_origem,payload#>>'{metadata,CANCEL_CODE}' motivo_codigo,payload#>>'{metadata,CANCEL_REASON}' motivo FROM private.gastronomia_ifood_eventos WHERE empresa_id=e AND pedido_id=p_pedido ORDER BY ocorrido_em DESC LIMIT 100)t;
 SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY criado_em DESC),'[]') INTO cmds FROM(SELECT id,acao,estado,criado_em,enviado_em,confirmado_em,status_http,erro,motivos_consultados_em,payload->>'cancellationCode' motivo_codigo,payload->>'reason' motivo FROM private.gastronomia_ifood_comandos WHERE empresa_id=e AND pedido_id=p_pedido ORDER BY criado_em DESC LIMIT 100)t;
 RETURN jsonb_build_object('empresa_id',e,'merchant_id',p.merchant_id,'pedido_id',p_pedido,'numero',p.normalizado->>'numero','estado_ifood',p.estado_ifood,'consultado_em',clock_timestamp(),'eventos',evs,'comandos',cmds,
 'validacao',jsonb_build_object(
  'confirmacao_enviada',EXISTS(SELECT 1 FROM private.gastronomia_ifood_comandos WHERE empresa_id=e AND pedido_id=p_pedido AND acao='confirmar' AND estado IN ('enviado','confirmado')),
  'confirmacao_recebida',EXISTS(SELECT 1 FROM private.gastronomia_ifood_eventos WHERE empresa_id=e AND pedido_id=p_pedido AND codigo IN ('CONFIRMED','CFM') AND estado='processado' AND ack_em IS NOT NULL),
  'cancelamento_enviado_com_motivos',EXISTS(SELECT 1 FROM private.gastronomia_ifood_comandos WHERE empresa_id=e AND pedido_id=p_pedido AND acao='solicitar_cancelamento' AND estado='confirmado' AND motivos_consultados_em IS NOT NULL),
  'cancelamento_restaurante_recebido',EXISTS(SELECT 1 FROM private.gastronomia_ifood_eventos WHERE empresa_id=e AND pedido_id=p_pedido AND codigo IN ('CANCELLED','CAN') AND estado='processado' AND ack_em IS NOT NULL AND payload#>>'{metadata,CANCEL_ORIGIN}'='RESTAURANT'),
  'eventos_sem_ack',(SELECT count(*) FROM private.gastronomia_ifood_eventos WHERE empresa_id=e AND pedido_id=p_pedido AND ack_em IS NULL),
  'eventos_pendentes',(SELECT count(*) FROM private.gastronomia_ifood_eventos WHERE empresa_id=e AND pedido_id=p_pedido AND estado<>'processado')));
END $fn$;
REVOKE ALL ON FUNCTION public.gastronomia_ifood_historico(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_ifood_historico(uuid,uuid) TO authenticated;

-- Conciliação explícita antes do preparo, sem recebimentos nem venda emitida.
-- Não estorna pagamentos reais nem devolve ao estoque itens já preparados.
CREATE FUNCTION private.gastronomia_ifood_conciliar(e uuid,pedido uuid) RETURNS void LANGUAGE plpgsql SET search_path='' AS $fn$
DECLARE p private.gastronomia_ifood_pedidos;a public.gastronomia_atendimentos;n jsonb;dados jsonb;resolvido jsonb;i jsonb;x jsonb;r record;iid uuid;ord int:=0;idx int;subtotal numeric:=0;dif numeric;dest text;ator uuid;
BEGIN
 SELECT * INTO p FROM private.gastronomia_ifood_pedidos WHERE empresa_id=e AND pedido_id=pedido FOR UPDATE;
 IF NOT coalesce((p.alteracao->>'solicitada')::boolean,false) THEN RETURN;END IF;
 SELECT * INTO a FROM public.gastronomia_atendimentos WHERE empresa_id=e AND id=p.atendimento_id AND origem='ifood' FOR UPDATE;
 IF a.id IS NULL OR p.estado_ifood<>'confirmado' OR a.estado IN ('cancelado','finalizado') OR a.venda_id IS NOT NULL OR EXISTS(SELECT 1 FROM public.gastronomia_pagamentos WHERE empresa_id=e AND atendimento_id=a.id AND NOT estornado) OR EXISTS(SELECT 1 FROM public.gastronomia_preparo pr JOIN public.gastronomia_itens it ON it.id=pr.item_id AND it.empresa_id=e WHERE pr.empresa_id=e AND it.atendimento_id=a.id AND NOT it.cancelado AND pr.estado<>'novo') THEN RAISE EXCEPTION 'Conciliação automática indisponível: há preparo, recebimento, venda ou encerramento. Revise o financeiro e o estoque sem desfazer movimentações reais.';END IF;
 IF EXISTS(SELECT 1 FROM private.gastronomia_ifood_comandos WHERE empresa_id=e AND pedido_id=pedido AND estado IN ('pendente','enviado','incerto')) THEN RAISE EXCEPTION 'Aguarde a conclusão dos comandos deste pedido antes de conciliar.';END IF;
 n:=p.alteracao->'atual';ator:=(p.alteracao->>'solicitada_por')::uuid;
 IF n->>'id' IS DISTINCT FROM pedido::text OR n->>'merchant_id' IS DISTINCT FROM p.merchant_id::text OR jsonb_array_length(coalesce(n->'avisos','[]'))>0 THEN RAISE EXCEPTION 'Confira os vínculos e valores da alteração antes de conciliar.';END IF;
 -- Desfaz somente as reservas de itens ainda não preparados e aplica o detalhe atual atomicamente.
 FOR r IN SELECT (b->>'produto_baixa_id')::uuid produto,sum((b->>'quantidade')::numeric) quantidade FROM public.gastronomia_itens it CROSS JOIN LATERAL jsonb_array_elements(it.snapshot->'baixas') b WHERE it.empresa_id=e AND it.atendimento_id=a.id AND NOT it.cancelado GROUP BY 1 ORDER BY 1 LOOP
  UPDATE public.produtos SET quantidade_estoque=quantidade_estoque+r.quantidade WHERE empresa_id=e AND id=r.produto;
 END LOOP;
 dados:=private.gastronomia_ifood_payload(e,n);resolvido:=private.gastronomia_resolver(dados,e);
 UPDATE public.gastronomia_itens SET cancelado=true WHERE empresa_id=e AND atendimento_id=a.id AND NOT cancelado;
 FOR x IN SELECT value FROM jsonb_array_elements(resolvido) LOOP
  i:=dados->ord;ord:=ord+1;
  x:=x||jsonb_build_object('ifood_observacao',i->>'observacao','lote',p.alteracao->>'evento_id','autor_publico','iFood','ifood_pedido_id',pedido,'preco_venda',round((i->>'ifood_total')::numeric/(i->>'quantidade')::numeric,2));
  INSERT INTO public.gastronomia_itens(empresa_id,atendimento_id,produto_id,quantidade,preco_unitario,snapshot) VALUES(e,a.id,(x->>'produto_id')::uuid,(x->>'quantidade')::numeric,(x->>'preco_venda')::numeric,x) RETURNING id INTO iid;
  subtotal:=subtotal+round((x->>'quantidade')::numeric*(x->>'preco_venda')::numeric,2);
  FOR dest IN SELECT DISTINCT z FROM (SELECT x->>'destino_operacional' z UNION SELECT v->>'destino_operacional' FROM jsonb_array_elements(x->'escolhas_resolvidas') v) s WHERE z IN ('bar','cozinha') LOOP
   INSERT INTO public.gastronomia_preparo(empresa_id,item_id,setor) VALUES(e,iid,dest);
  END LOOP;
 END LOOP;
 UPDATE public.gastronomia_atendimentos SET taxa_entrega=CASE WHEN tipo='entrega' THEN coalesce((p.detalhe#>>'{total,deliveryFee}')::numeric,0) ELSE 0 END WHERE empresa_id=e AND id=a.id;
 SELECT (n->>'total_empresa')::numeric/100-subtotal-taxa_entrega INTO dif FROM public.gastronomia_atendimentos WHERE empresa_id=e AND id=a.id;
 UPDATE public.gastronomia_atendimentos SET desconto=greatest(-dif,0),acrescimo=greatest(dif,0),versao=versao+1 WHERE empresa_id=e AND id=a.id;
 UPDATE private.gastronomia_ifood_pagamentos SET ativo=false WHERE empresa_id=e AND pedido_id=pedido;
 SELECT coalesce(max(indice),0)+1 INTO idx FROM private.gastronomia_ifood_pagamentos WHERE empresa_id=e AND pedido_id=pedido;
 FOR i IN SELECT value FROM jsonb_array_elements(n->'pagamentos') LOOP
  IF (i->>'valor')::bigint>0 THEN INSERT INTO private.gastronomia_ifood_pagamentos(empresa_id,merchant_id,pedido_id,indice,tipo,forma,valor_centavos,bandeira,valor_empresa_centavos) VALUES(e,p.merchant_id,pedido,idx,i->>'tipo',i->>'forma',(i->>'valor')::bigint,i->>'bandeira',(i->>'valor_empresa')::bigint);END IF;idx:=idx+1;
 END LOOP;
 UPDATE private.gastronomia_ifood_pedidos SET normalizado=n,total_centavos=(n->>'total')::bigint,pago_online_centavos=(n->>'pago_online')::bigint,a_cobrar_centavos=(n->>'a_cobrar')::bigint,alteracao=alteracao||jsonb_build_object('requer_conciliacao',false,'solicitada',false,'erro',NULL,'conciliado_em',clock_timestamp(),'conciliado_por',ator),revisao_motivo=NULL,atualizado_em=now() WHERE empresa_id=e AND pedido_id=pedido;
 INSERT INTO public.gastronomia_eventos(empresa_id,atendimento_id,tipo,autor,detalhes) VALUES(e,a.id,'ifood_evento',ator,jsonb_build_object('acao','conciliar_alteracao','pedido_id',pedido,'evento_id',p.alteracao->>'evento_id','anterior',p.normalizado,'atual',n));
 PERFORM private.gastronomia_ifood_imprimir(a.id,e,(p.alteracao->>'evento_id')::uuid,true);
 INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
END $fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_conciliar(uuid,uuid) FROM PUBLIC,anon,authenticated;
DO $patch$
DECLARE src text;old text;
BEGIN
 src:=pg_get_functiondef('private.gastronomia_ifood_admin(text,jsonb)'::regprocedure);
 old:='ELSIF p_acao=''reprocessar'' THEN';IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Admin divergente: conciliação';END IF;
 src:=replace(src,old,$new$ELSIF p_acao='conciliar_alteracao' THEN
  PERFORM private.gastronomia_exigir('gastronomia_pedidos');PERFORM private.gastronomia_exigir('gastronomia_cancelar');
  SELECT * INTO p FROM private.gastronomia_ifood_pedidos WHERE empresa_id=e AND pedido_id=(d->>'pedido_id')::uuid FOR UPDATE;
  IF p.pedido_id IS NULL OR p.alteracao->>'evento_id' IS DISTINCT FROM d->>'evento_id' OR NOT coalesce((p.alteracao->>'requer_conciliacao')::boolean,false) OR d->>'confirmado' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Alteração ausente, atualizada ou ainda não conferida.';END IF;
  IF NOT c.habilitada THEN RAISE EXCEPTION 'Conexão pausada.';END IF;
  UPDATE private.gastronomia_ifood_pedidos SET alteracao=alteracao||jsonb_build_object('solicitada',true,'solicitada_por',auth.uid(),'solicitada_em',clock_timestamp(),'erro',NULL) WHERE empresa_id=e AND pedido_id=p.pedido_id;
 ELSIF p_acao='reprocessar' THEN$new$);EXECUTE src;
 src:=pg_get_functiondef('public.gastronomia_ifood_worker(text,uuid,jsonb)'::regprocedure);
 old:='ELSIF p_acao=''agendados'' THEN';IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Worker divergente: conciliação';END IF;
 src:=replace(src,old,$new$ELSIF p_acao='conciliar_alteracoes' THEN
  FOR p IN SELECT * FROM private.gastronomia_ifood_pedidos WHERE empresa_id=p_empresa AND alteracao->>'solicitada'='true' ORDER BY atualizado_em LIMIT 5 LOOP
   BEGIN PERFORM private.gastronomia_ifood_conciliar(p_empresa,p.pedido_id);
   EXCEPTION WHEN OTHERS THEN UPDATE private.gastronomia_ifood_pedidos SET alteracao=alteracao||jsonb_build_object('solicitada',false,'erro',left(SQLERRM,400)) WHERE empresa_id=p_empresa AND pedido_id=p.pedido_id;END;
  END LOOP;
 ELSIF p_acao='agendados' THEN$new$);EXECUTE src;
END $patch$;

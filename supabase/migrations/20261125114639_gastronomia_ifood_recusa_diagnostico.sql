-- Somente recusa Handshake e comprovação do cancelamento: preserva permissões e demais fluxos.
DO $patch$
DECLARE src text;old text;
BEGIN
 src:=pg_get_functiondef('private.gastronomia_ifood_resposta(jsonb,text,jsonb)'::regprocedure);
 old:=' IF n->>''status'' IS NOT NULL THEN';
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Validação de negociação divergente';END IF;
 src:=replace(src,old,$new$
 IF acao='recusar_negociacao' AND NOT coalesce(p->>'reason'=ANY(ARRAY['HIGH_STORE_DEMAND','UNKNOWN_ISSUE','CUSTOMER_SATISFACTION','INVENTORY_CHECK','SYSTEM_ISSUE','WRONG_ORDER','PRODUCT_QUALITY','LATE_DELIVERY','CUSTOMER_REQUEST']),false) THEN
  RAISE EXCEPTION 'Selecione um motivo de recusa válido do iFood.';
 END IF;
 IF n->>'status' IS NOT NULL THEN$new$);
 EXECUTE src;
 src:=pg_get_functiondef('public.gastronomia_ifood_historico(uuid,uuid)'::regprocedure);
 old:=$old$acao='solicitar_cancelamento' AND estado='confirmado' AND motivos_consultados_em IS NOT NULL$old$;
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Diagnóstico de envio divergente';END IF;
 src:=replace(src,old,$new$acao='solicitar_cancelamento' AND estado IN ('enviado','confirmado') AND status_http=202 AND motivos_consultados_em IS NOT NULL$new$);
 old:=$old$EXISTS(SELECT 1 FROM private.gastronomia_ifood_eventos WHERE empresa_id=e AND pedido_id=p_pedido AND codigo IN ('CANCELLED','CAN') AND estado='processado' AND ack_em IS NOT NULL AND payload#>>'{metadata,CANCEL_ORIGIN}'='RESTAURANT')$old$;
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Diagnóstico de origem divergente';END IF;
 src:=replace(src,old,$new$EXISTS(
  SELECT 1 FROM private.gastronomia_ifood_eventos ev
  WHERE ev.empresa_id=e AND ev.pedido_id=p_pedido AND ev.merchant_id=p.merchant_id
   AND ev.codigo IN ('CANCELLED','CAN') AND ev.estado='processado' AND ev.ack_em IS NOT NULL
   AND (coalesce(ev.payload#>>'{metadata,CANCEL_ORIGIN}','')='RESTAURANT'
     OR (coalesce(ev.payload#>>'{metadata,CANCEL_ORIGIN}','')<>'SCHEDULER'
       AND coalesce(ev.payload#>>'{metadata,ORIGIN}',ev.payload#>>'{metadata,additional_info,ORIGIN}','')='ORDER_API'))
   AND EXISTS(SELECT 1 FROM private.gastronomia_ifood_comandos cmd
    WHERE cmd.empresa_id=e AND cmd.pedido_id=p_pedido AND cmd.acao='solicitar_cancelamento'
     AND cmd.estado='confirmado' AND cmd.motivos_consultados_em IS NOT NULL
     AND cmd.confirmado_em=ev.ocorrido_em AND cmd.criado_em<=ev.ocorrido_em+interval '1 minute')
 )$new$);
 EXECUTE src;
END $patch$;

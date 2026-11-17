-- Aceitação sem lista de motivos admite corpo vazio, conforme contrato Handshake.
DO $fix$ DECLARE src text;old_sql text:='IF length(trim(coalesce(p->>''reason'','''')))=0 THEN';BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_resposta(jsonb,text,jsonb)'::regprocedure);IF strpos(src,old_sql)=0 THEN RAISE EXCEPTION 'Validação de motivo divergente';END IF;
src:=replace(src,old_sql,'IF acao=''recusar_negociacao'' AND length(trim(coalesce(p->>''reason'','''')))=0 THEN');EXECUTE src;
END $fix$;
-- Uma disputa antiga não reabre uma resolução nem substitui a negociação atual.
DO $fix$ DECLARE src text;needle text;BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_evento(uuid,uuid)'::regprocedure);
needle:='IF ev.codigo IN (''HANDSHAKE_DISPUTE'',''HSD'') THEN';
src:=replace(src,needle,needle||$more$
  IF p.negociacao->>'disputeId'=coalesce(ev.payload#>>'{metadata,disputeId}',ev.payload#>>'{metadata,id}') AND p.negociacao->>'status' IS NOT NULL THEN
   UPDATE private.gastronomia_ifood_pedidos SET negociacao=private.gastronomia_ifood_negociacao(ev.payload->'metadata')||p.negociacao WHERE empresa_id=p_e AND pedido_id=ev.pedido_id;RETURN;
  END IF;
  IF coalesce((p.negociacao->>'_evento_em')::timestamptz,(p.negociacao->>'createdAt')::timestamptz)>ev.ocorrido_em THEN RETURN;END IF;
$more$);
src:=replace(src,'negociacao=private.gastronomia_ifood_negociacao(ev.payload->''metadata''),revisao_motivo','negociacao=private.gastronomia_ifood_negociacao(ev.payload->''metadata'')||jsonb_build_object(''_evento_em'',ev.ocorrido_em),revisao_motivo');
src:=replace(src,'revisao_motivo=''Confira o resultado da negociação no iFood.'' WHERE empresa_id=p_e AND pedido_id=ev.pedido_id;','revisao_motivo=''Confira o resultado da negociação no iFood.'' WHERE empresa_id=p_e AND pedido_id=ev.pedido_id AND (negociacao->>''disputeId'' IS NULL OR negociacao->>''disputeId''=ev.payload#>>''{metadata,disputeId}'');');EXECUTE src;
src:=pg_get_functiondef('private.gastronomia_ifood_encerrar(uuid,uuid)'::regprocedure);src:=replace(src,'AND (ip.negociacao->>''action'' IN','AND (ip.negociacao->>''action'' IS NULL OR ip.negociacao->>''action'' IN');EXECUTE src;
END $fix$;

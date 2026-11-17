-- Handshake: valida a oferta recebida e impede respostas contraditórias à mesma disputa.
ALTER TABLE private.gastronomia_ifood_comandos DROP CONSTRAINT gastronomia_ifood_comandos_acao_check;
ALTER TABLE private.gastronomia_ifood_comandos ADD CONSTRAINT gastronomia_ifood_comandos_acao_check CHECK(acao IN ('confirmar','preparar','pronto','despachar','solicitar_cancelamento','aceitar_negociacao','recusar_negociacao','alternativa_negociacao'));
CREATE FUNCTION private.gastronomia_ifood_negociacao(d jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT d||jsonb_build_object('disputeId',coalesce(d->>'disputeId',d->>'id'),'acceptCancellationReasons',coalesce(d->'acceptCancellationReasons',d#>'{metadata,acceptCancellationReasons}','[]'))
$$;
CREATE FUNCTION private.gastronomia_ifood_resposta(n jsonb,acao text,p jsonb) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE alt jsonb; reason jsonb; val numeric;BEGIN
 IF n->>'status' IS NOT NULL THEN RAISE EXCEPTION 'Disputa já respondida.';END IF;
 IF length(coalesce(p->>'detailReason',''))>250 THEN RAISE EXCEPTION 'Detalhe limitado a 250 caracteres.';END IF;
 IF acao='alternativa_negociacao' THEN
  SELECT a INTO alt FROM jsonb_array_elements(coalesce(n->'alternatives','[]')) a WHERE a->>'type'=p->>'type' LIMIT 1;
  IF alt IS NULL OR p->>'type' NOT IN ('REFUND','BENEFIT','ADDITIONAL_TIME') THEN RAISE EXCEPTION 'Alternativa não oferecida pelo iFood.';END IF;
  IF p->>'type' IN ('REFUND','BENEFIT') THEN
   val:=(p#>>'{metadata,amount,value}')::numeric;
   IF val IS NULL OR val<=0 OR val<>trunc(val) OR p#>>'{metadata,amount,currency}'<>'BRL' OR val>coalesce((alt#>>'{metadata,maxAmount,value}')::numeric,0) THEN RAISE EXCEPTION 'Valor fora da oferta iFood (centavos).';END IF;
  ELSE
   IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(alt#>'{metadata,additionalTimeInMinutes}','[]')) a WHERE a=p#>>'{metadata,additionalTimeInMinutes}') OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(alt#>'{metadata,reasons}','[]')) a WHERE a=p#>>'{metadata,reason}') THEN RAISE EXCEPTION 'Prazo ou motivo não oferecido pelo iFood.';END IF;
  END IF;
 ELSE
  IF length(trim(coalesce(p->>'reason','')))=0 THEN RAISE EXCEPTION 'Informe o motivo da resposta.';END IF;
  IF acao='aceitar_negociacao' AND jsonb_array_length(coalesce(n->'acceptCancellationReasons','[]'))>0 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(n->'acceptCancellationReasons') r WHERE coalesce(r->>'code',r->>'reason',r#>>'{}')=p->>'reason') THEN RAISE EXCEPTION 'Selecione um motivo oferecido pelo iFood.';END IF;
 END IF;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_negociacao(jsonb),private.gastronomia_ifood_resposta(jsonb,text,jsonb) FROM PUBLIC,anon,authenticated;
DO $fix$ DECLARE src text;needle text;BEGIN
 src:=pg_get_functiondef('private.gastronomia_ifood_admin(text,jsonb)'::regprocedure);
 IF strpos(src,'''aceitar_negociacao'',''recusar_negociacao''')=0 THEN RAISE EXCEPTION 'Admin iFood divergente';END IF;
 src:=replace(src,'''aceitar_negociacao'',''recusar_negociacao''','''aceitar_negociacao'',''recusar_negociacao'',''alternativa_negociacao''');
 needle:='IF d#>>''{payload,disputeId}'' IS DISTINCT FROM p.negociacao->>''disputeId'' THEN RAISE EXCEPTION ''Negociação de outro pedido.''; END IF;';
 IF strpos(src,needle)=0 THEN RAISE EXCEPTION 'Validação de disputa divergente';END IF;
 src:=replace(src,needle,needle||$more$
   PERFORM private.gastronomia_ifood_resposta(p.negociacao,ac,d->'payload');
   IF EXISTS(SELECT 1 FROM private.gastronomia_ifood_comandos c WHERE c.empresa_id=e AND c.pedido_id=p.pedido_id AND c.acao IN ('aceitar_negociacao','recusar_negociacao','alternativa_negociacao') AND c.payload->>'disputeId'=p.negociacao->>'disputeId' AND c.estado IN ('pendente','enviado','incerto','confirmado')) THEN RAISE EXCEPTION 'Resposta já registrada para esta disputa. Aguarde o iFood.';END IF;
$more$);EXECUTE src;
 src:=pg_get_functiondef('public.gastronomia_ifood_worker(text,uuid,jsonb)'::regprocedure);EXECUTE replace(src,'''aceitar_negociacao'',''recusar_negociacao''','''aceitar_negociacao'',''recusar_negociacao'',''alternativa_negociacao''');
 src:=pg_get_functiondef('private.gastronomia_ifood_evento(uuid,uuid)'::regprocedure);
 src:=replace(src,'negociacao=ev.payload->''metadata'',revisao_motivo=''Negociação pendente','negociacao=private.gastronomia_ifood_negociacao(ev.payload->''metadata''),revisao_motivo=''Negociação pendente');
 src:=replace(src,'''aceitar_negociacao'',''recusar_negociacao''','''aceitar_negociacao'',''recusar_negociacao'',''alternativa_negociacao''');
 src:=replace(src,'negociacao=ev.payload->''metadata'',revisao_motivo=''Confira o resultado','negociacao=coalesce(negociacao,''{}'')||private.gastronomia_ifood_negociacao(ev.payload->''metadata''),revisao_motivo=''Confira o resultado');
 src:=replace(src,'novo:=CASE ev.codigo',$more$
 IF ev.codigo='DELIVERY_DROP_CODE_REQUESTED' THEN
  UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo=CASE WHEN revisao_motivo LIKE '%DELIVERY_DROP_CODE_REQUESTED%' THEN NULL ELSE revisao_motivo END WHERE empresa_id=p_e AND pedido_id=ev.pedido_id;RETURN;
 END IF;
 novo:=CASE ev.codigo$more$);EXECUTE src;
 UPDATE private.gastronomia_ifood_pedidos SET negociacao=private.gastronomia_ifood_negociacao(negociacao) WHERE negociacao IS NOT NULL AND empresa_id='773dfacb-c0e7-4bd9-8eb4-5208818b1848';
END $fix$;

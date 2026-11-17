-- Um cancelamento automático não confirma uma tentativa de comando que falhou.
DO $fix$ DECLARE src text;needle text:='AND acao=CASE novo';BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_evento(uuid,uuid)'::regprocedure);IF strpos(src,needle)=0 THEN RAISE EXCEPTION 'Conciliação de comandos divergente';END IF;
src:=replace(src,needle,'AND estado IN (''enviado'',''incerto'') AND (novo<>''cancelado'' OR coalesce(ev.payload#>>''{metadata,CANCEL_ORIGIN}'',ev.payload#>>''{metadata,ORIGIN}'','''')<>''SCHEDULER'') '||needle);EXECUTE src;
END $fix$;
CREATE INDEX IF NOT EXISTS gastronomia_ifood_eventos_pedido_em_idx ON private.gastronomia_ifood_eventos(empresa_id,pedido_id,ocorrido_em DESC);
CREATE FUNCTION private.gastronomia_ifood_cancelamento(e uuid,pedido uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $fn$
 SELECT jsonb_build_object('origem',coalesce(payload#>>'{metadata,CANCEL_ORIGIN}',payload#>>'{metadata,ORIGIN}'),'codigo',coalesce(payload#>>'{metadata,CANCEL_CODE}',payload#>>'{metadata,reason_code}'),'motivo',coalesce(payload#>>'{metadata,CANCEL_REASON}',payload#>>'{metadata,CANCEL_CODE_DESCRIPTION}',payload#>>'{metadata,details}'),'ocorrido_em',ocorrido_em) FROM private.gastronomia_ifood_eventos WHERE empresa_id=e AND pedido_id=pedido AND codigo IN ('CANCELLED','CAN') AND estado='processado' ORDER BY ocorrido_em DESC LIMIT 1
$fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_cancelamento(uuid,uuid) FROM PUBLIC,anon,authenticated;
DO $fix$ DECLARE src text;sig text;BEGIN
FOREACH sig IN ARRAY ARRAY['private.gastronomia_ifood_painel(uuid)','public.gastronomia_pedidos_data(date,uuid)'] LOOP
src:=pg_get_functiondef(sig::regprocedure);
IF sig LIKE 'private.%' THEN src:=replace(src,'p.normalizado,','p.normalizado,private.gastronomia_ifood_cancelamento(p_e,p.pedido_id) cancelamento,');ELSE src:=replace(src,'ip.normalizado,','ip.normalizado,private.gastronomia_ifood_cancelamento(e,ip.pedido_id) cancelamento,');END IF;EXECUTE src;
END LOOP;
END $fix$;
-- Restaura somente as duas tentativas com falha verificadas no diagnóstico, sem alterar o pedido cancelado.
UPDATE private.gastronomia_ifood_comandos c SET estado='falha',erro='Esta solicitação não foi confirmada. O pedido foi cancelado automaticamente pelo iFood por falta de confirmação da loja.' WHERE c.empresa_id='773dfacb-c0e7-4bd9-8eb4-5208818b1848' AND c.pedido_id='9b22bbea-635e-475a-abf3-e70f220ab6ae' AND c.id IN ('1c3afe8b-0d76-448f-a944-4628abf7cdf7','cc2a3e98-41fd-471b-bf6a-d5ad8b59fb66') AND c.estado='confirmado' AND EXISTS(SELECT 1 FROM private.gastronomia_ifood_eventos ev WHERE ev.empresa_id=c.empresa_id AND ev.pedido_id=c.pedido_id AND ev.codigo='CANCELLED' AND ev.payload#>>'{metadata,CANCEL_ORIGIN}'='SCHEDULER');

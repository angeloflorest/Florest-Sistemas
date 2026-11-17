-- Remover somente o aviso transitório quando o evento final já chegou.
DO $patch$
DECLARE src text; old text := 'SET estado_ifood=novo,ultimo_evento_em=ev.ocorrido_em,atualizado_em=now()';
BEGIN
 src := pg_get_functiondef('private.gastronomia_ifood_evento(uuid,uuid)'::regprocedure);
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Atualização de estado iFood não localizada'; END IF;
 src := replace(src,old,$replacement$SET estado_ifood=novo,revisao_motivo=CASE WHEN novo IN ('cancelado','concluido') AND revisao_motivo='Cancelamento solicitado — aguardando a decisão do iFood.' THEN NULL ELSE revisao_motivo END,ultimo_evento_em=ev.ocorrido_em,atualizado_em=now()$replacement$);
 EXECUTE src;
END $patch$;
UPDATE private.gastronomia_ifood_pedidos
SET revisao_motivo=NULL
WHERE estado_ifood IN ('cancelado','concluido')
AND revisao_motivo='Cancelamento solicitado — aguardando a decisão do iFood.';

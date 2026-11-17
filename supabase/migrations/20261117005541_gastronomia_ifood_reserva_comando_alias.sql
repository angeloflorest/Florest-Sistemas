-- Evita conflito entre o registro PL/pgSQL p e o alias SQL da reserva de envio.
DO $fix$
DECLARE source text; old_sql text := 'FROM private.gastronomia_ifood_pedidos p WHERE p.empresa_id=p_empresa AND p.pedido_id=gastronomia_ifood_comandos.pedido_id AND p.estado_ifood IN'; new_sql text := 'FROM private.gastronomia_ifood_pedidos pedido_cmd WHERE pedido_cmd.empresa_id=p_empresa AND pedido_cmd.pedido_id=gastronomia_ifood_comandos.pedido_id AND pedido_cmd.estado_ifood IN';
BEGIN
source:=pg_get_functiondef('public.gastronomia_ifood_worker(text,uuid,jsonb)'::regprocedure);
IF strpos(source,old_sql)=0 THEN RAISE EXCEPTION 'Reserva de comando divergente da versão revisada'; END IF;
EXECUTE replace(source,old_sql,new_sql);
END $fix$;

-- Solicitações oficiais de reembolso podem chegar depois da conclusão do pedido.
DO $m$ DECLARE src text; BEGIN
 src:=pg_get_functiondef('private.gastronomia_99food_sandbox_admin(uuid,text,jsonb)'::regprocedure);
 IF strpos(src,'IF o.status_99food>=900 OR o.status_99food=600 THEN')=0 THEN RAISE EXCEPTION 'Admin 99Food divergente.'; END IF;
 EXECUTE replace(src,'IF o.status_99food>=900 OR o.status_99food=600 THEN','IF (o.status_99food>=900 OR o.status_99food=600) AND p_acao<>''responder_reembolso'' THEN');
END $m$;
NOTIFY pgrst,'reload schema';

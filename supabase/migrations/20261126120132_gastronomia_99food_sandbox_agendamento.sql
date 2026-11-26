-- Não consultar repetidamente injeções que a API não reconhece como pedidos.
DO $m$ DECLARE src text; BEGIN
 src:=pg_get_functiondef('private.gastronomia_99food_sandbox_worker(text,jsonb)'::regprocedure);
 IF strpos(src,'AND recebido_em>now()')=0 THEN RAISE EXCEPTION 'Worker 99Food divergente.'; END IF;
 EXECUTE replace(src,'AND recebido_em>now()','AND coalesce(ultimo_erro,'''') NOT LIKE ''%12004%'' AND recebido_em>now()');
END $m$;
-- Worker autenticado e limitado à loja de teste. Não confirma pedidos automaticamente.
SELECT cron.schedule('gastronomia-99food-sandbox-worker','30 seconds',$job$SELECT private.gastronomia_99food_sandbox_disparar();$job$);

-- Guarda a resposta do comando iFood sem repetir operações nem alterar pedidos.
ALTER TABLE private.gastronomia_ifood_comandos ADD COLUMN erro text, ADD COLUMN status_http integer CHECK(status_http BETWEEN 100 AND 599);
DO $fix$ DECLARE src text;sig text;old_sql text:='SET estado=p_dados->>''estado'' WHERE';BEGIN
src:=pg_get_functiondef('public.gastronomia_ifood_worker(text,uuid,jsonb)'::regprocedure);IF strpos(src,old_sql)=0 THEN RAISE EXCEPTION 'Resultado de comando divergente';END IF;
src:=replace(src,old_sql,'SET estado=p_dados->>''estado'',erro=left(p_dados->>''erro'',500),status_http=nullif((p_dados->>''status_http'')::integer,0) WHERE');EXECUTE src;
FOREACH sig IN ARRAY ARRAY['private.gastronomia_ifood_painel(uuid)','public.gastronomia_pedidos_data(date,uuid)'] LOOP
src:=pg_get_functiondef(sig::regprocedure);
IF sig LIKE 'private.%' THEN src:=replace(src,'''acao'',acao,''estado'',estado','''acao'',acao,''estado'',estado,''erro'',erro,''status_http'',status_http');ELSE src:=replace(src,'''acao'',ic.acao,''estado'',ic.estado','''acao'',ic.acao,''estado'',ic.estado,''erro'',ic.erro,''status_http'',ic.status_http');END IF;EXECUTE src;
END LOOP;
END $fix$;

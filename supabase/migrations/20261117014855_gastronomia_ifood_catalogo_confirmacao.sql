CREATE INDEX gastronomia_ifood_catalogo_produto ON private.gastronomia_ifood_catalogo(produto_id);
DO $fix$
DECLARE src text;old_expr text := 'estado=CASE WHEN coalesce((p_dados->>''ok'')::boolean,false) THEN ''publicado'' ELSE ''erro'' END';new_expr text := 'estado=CASE WHEN coalesce((p_dados->>''aguardar'')::boolean,false) THEN ''pendente'' WHEN coalesce((p_dados->>''ok'')::boolean,false) THEN ''publicado'' ELSE ''erro'' END';
BEGIN src:=pg_get_functiondef('public.gastronomia_ifood_catalogo_worker(text,uuid,jsonb)'::regprocedure);
IF strpos(src,old_expr)=0 THEN RAISE EXCEPTION 'Versão de publicação divergente';END IF;EXECUTE replace(src,old_expr,new_expr);END $fix$;
UPDATE private.gastronomia_ifood_catalogo SET estado='pendente',erro=NULL WHERE empresa_id='773dfacb-c0e7-4bd9-8eb4-5208818b1848' AND estado='erro' AND erro LIKE '%404%';

DO $fix$
DECLARE src text;old_expr text := 'md5(''florest-ifood-item:''||p_empresa::text||'':''||r.id::text)::uuid';new_expr text := 'overlay(overlay(md5(''florest-ifood-item:''||p_empresa::text||'':''||r.id::text) placing ''5'' from 13 for 1) placing ''a'' from 17 for 1)::uuid';
BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_catalogo_enfileirar(uuid)'::regprocedure);
IF strpos(src,old_expr)=0 THEN RAISE EXCEPTION 'Versão do catálogo divergente';END IF;
EXECUTE replace(src,old_expr,new_expr);
END $fix$;
UPDATE private.gastronomia_ifood_catalogo SET item_id=overlay(overlay(replace(item_id::text,'-','') placing '5' from 13 for 1) placing 'a' from 17 for 1)::uuid,hash=md5(hash||':uuid-valido'),estado='pendente',erro=NULL,lease_ate=NULL
WHERE empresa_id='773dfacb-c0e7-4bd9-8eb4-5208818b1848' AND estado<>'publicado' AND item_id::text !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
UPDATE private.gastronomia_ifood_catalogo SET estado='pendente',erro=NULL WHERE empresa_id='773dfacb-c0e7-4bd9-8eb4-5208818b1848' AND estado='erro' AND erro LIKE '%409%';

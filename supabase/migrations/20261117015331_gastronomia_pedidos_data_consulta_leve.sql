DO $fix$
DECLARE src text;old_line text;start_pos integer;new_line text:=$line$ atds:=(SELECT coalesce(jsonb_agg(z.doc ORDER BY z.criado_em DESC),'[]') FROM (SELECT a.criado_em,to_jsonb(a)||jsonb_build_object('total',private.gastronomia_total(a.id,e),'itens',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',i.id,'produto_id',i.produto_id,'quantidade',i.quantidade,'cancelado',i.cancelado,'snapshot',i.snapshot) ORDER BY i.criado_em),'[]') FROM public.gastronomia_itens i WHERE i.empresa_id=e AND i.atendimento_id=a.id)) doc FROM public.gastronomia_atendimentos a WHERE a.empresa_id=e AND a.tipo<>'mesa' AND a.criado_em>=inicio AND a.criado_em<fim ORDER BY a.criado_em DESC LIMIT 1000) z);$line$;
BEGIN src:=pg_get_functiondef('public.gastronomia_pedidos_data(date,uuid)'::regprocedure);start_pos:=strpos(src,' atds:=');
IF start_pos=0 THEN RAISE EXCEPTION 'Consulta por data divergente';END IF;
old_line:=split_part(substring(src from start_pos),E'\n',1);
IF strpos(old_line,'gastronomia_financeiro_detalhe')=0 THEN RAISE EXCEPTION 'Consulta por data já alterada';END IF;
EXECUTE replace(src,old_line,new_line);
END $fix$;

-- Complementos do iFood preservam a árvore e resolvem cada produto na empresa do pedido.
ALTER TABLE private.gastronomia_ifood_pagamentos ADD COLUMN valor_empresa_centavos bigint,
 ADD CONSTRAINT gastronomia_ifood_pagamento_empresa_valor CHECK(valor_empresa_centavos>=0 AND valor_empresa_centavos<=valor_centavos);
CREATE FUNCTION private.gastronomia_ifood_no_payload(p_e uuid,p_no jsonb,p_total numeric,p_emitir boolean DEFAULT true,p_nivel int DEFAULT 1) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE bp record; op record; child jsonb; escolhas jsonb:='[]'; extras jsonb:='[]'; itens jsonb:='[]'; q numeric; k int;
BEGIN
 IF p_nivel>3 THEN RAISE EXCEPTION 'Complemento além do terceiro nível.'; END IF;
 SELECT * INTO bp FROM private.gastronomia_produtos_operacionais WHERE empresa_id=p_e AND produto_id=(p_no->>'produto_id')::uuid AND ativo_cardapio;
 IF bp.id IS NULL THEN RAISE EXCEPTION 'Vincule % ao cardápio da Gastronomia desta empresa.',p_no->>'nome'; END IF;
 FOR child IN SELECT value FROM jsonb_array_elements(coalesce(p_no->'adicionais','[]')) LOOP
  SELECT count(*) qtd,min(g.id::text)::uuid grupo INTO op FROM private.gastronomia_grupos_operacionais g JOIN private.gastronomia_opcoes_operacionais z ON z.grupo_id=g.id AND z.empresa_id=p_e WHERE g.empresa_id=p_e AND g.bar_produto_id=bp.id AND z.produto_id=(child->>'produto_id')::uuid;
  IF op.qtd>1 THEN RAISE EXCEPTION 'Vínculo ambíguo do adicional %.',child->>'nome'; END IF;
  IF op.qtd=1 THEN
   q:=(child->>'quantidade')::numeric/(p_no->>'quantidade')::numeric;
   IF q<>trunc(q) OR q<=0 OR q>100 THEN RAISE EXCEPTION 'Revise a quantidade do adicional %.',child->>'nome'; END IF;
   FOR k IN 1..q::int LOOP escolhas:=escolhas||jsonb_build_array(jsonb_build_object('grupo_id',op.grupo,'produto_id',child->>'produto_id')); END LOOP;
   IF EXISTS(SELECT 1 FROM private.gastronomia_produtos_operacionais WHERE empresa_id=p_e AND produto_id=(child->>'produto_id')::uuid AND tipo<>'simples') THEN RAISE EXCEPTION 'Escolha composta exige revisão da receita: %.',child->>'nome'; END IF;
   extras:=extras||private.gastronomia_ifood_no_payload(p_e,child,0,false,p_nivel+1);
  ELSE
   extras:=extras||private.gastronomia_ifood_no_payload(p_e,child,0,true,p_nivel+1);
  END IF;
 END LOOP;
 IF p_emitir THEN
  IF round(round(p_total/(p_no->>'quantidade')::numeric,2)*(p_no->>'quantidade')::numeric,2)<>p_total THEN RAISE EXCEPTION 'Preço fracionado exige revisão.'; END IF;
  itens:=jsonb_build_array(jsonb_build_object('bar_produto_id',bp.id,'quantidade',(p_no->>'quantidade')::numeric,'observacao',concat_ws(' · ',p_no->>'observacao',CASE WHEN p_nivel>1 THEN 'Complemento iFood: '||(p_no->>'nome') END),'escolhas',escolhas,'ifood_total',p_total));
 END IF;
 RETURN itens||extras;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_no_payload(uuid,jsonb,numeric,boolean,int) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION private.gastronomia_ifood_payload(p_e uuid,p_normal jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE i jsonb; result jsonb:='[]';BEGIN
 FOR i IN SELECT value FROM jsonb_array_elements(p_normal->'itens') LOOP
  result:=result||private.gastronomia_ifood_no_payload(p_e,i,(i->>'total')::numeric/100);
 END LOOP;RETURN result;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_payload(uuid,jsonb) FROM PUBLIC,anon,authenticated;

DO $patch$ DECLARE d text; BEGIN
 SELECT replace(pg_get_functiondef('private.gastronomia_ifood_importar(uuid,uuid)'::regprocedure),chr(13)||chr(10),chr(10)) INTO d;
 IF md5(d)<>'c8192f6df690da85a21c343baa87e79f' THEN RAISE EXCEPTION 'Base alterada: private.gastronomia_ifood_importar'; END IF;
 d:=replace(d,$old$p.total_centavos::numeric/100$old$,$new$coalesce((p.normalizado->>'total_empresa')::numeric/100,p.total_centavos::numeric/100)$new$);
 d:=replace(d,$old$valor_centavos,bandeira)$old$,$new$valor_centavos,bandeira,valor_empresa_centavos)$new$);
 d:=replace(d,$old$(i->>'valor')::bigint,i->>'bandeira')$old$,$new$(i->>'valor')::bigint,i->>'bandeira',coalesce((i->>'valor_empresa')::bigint,(i->>'valor')::bigint))$new$);
 EXECUTE d;
END $patch$;

DO $patch$ DECLARE d text; BEGIN
 SELECT replace(pg_get_functiondef('private.gastronomia_pago(uuid,uuid)'::regprocedure),chr(13)||chr(10),chr(10)) INTO d;
 IF md5(d)<>'26d3ead701fef81228c880ee4c60fe8d' THEN RAISE EXCEPTION 'Base alterada: private.gastronomia_pago'; END IF;
 d:=replace(d,$old$sum(ip.valor_centavos)::numeric/100$old$,$new$sum(coalesce(ip.valor_empresa_centavos,ip.valor_centavos))::numeric/100$new$);
 EXECUTE d;
END $patch$;

DO $patch$ DECLARE d text; BEGIN
 SELECT replace(pg_get_functiondef('private.gastronomia_venda(uuid,uuid)'::regprocedure),chr(13)||chr(10),chr(10)) INTO d;
 IF md5(d)<>'9998a472ae771a509e5782000f1001de' THEN RAISE EXCEPTION 'Base alterada: private.gastronomia_venda'; END IF;
 d:=replace(d,$old$ip.valor_centavos::numeric/100$old$,$new$coalesce(ip.valor_empresa_centavos,ip.valor_centavos)::numeric/100$new$);
 d:=replace(d,$old$ip.tipo='ONLINE' AND ip.ativo AND p.estado_ifood<>'cancelado'$old$,$new$ip.tipo='ONLINE' AND ip.ativo AND coalesce(ip.valor_empresa_centavos,ip.valor_centavos)>0 AND p.estado_ifood<>'cancelado'$new$);
 EXECUTE d;
END $patch$;

DO $patch$ DECLARE d text; BEGIN
 SELECT replace(pg_get_functiondef('private.gastronomia_ifood_imprimir(uuid,uuid,uuid,boolean)'::regprocedure),chr(13)||chr(10),chr(10)) INTO d;
 IF md5(d)<>'cca229c24e3a541a26fd18ede6b1e222' THEN RAISE EXCEPTION 'Base alterada: private.gastronomia_ifood_imprimir'; END IF;
 d:=replace(d,$old$jsonb_build_object('nome','PEDIDO NÃO FISCAL$old$,$new$jsonb_build_object('nome','Taxas do iFood (fora da venda): R$ '||to_char(coalesce((p.normalizado->>'taxas_ifood')::numeric,0)/100,'FM999999990.00')),
   jsonb_build_object('nome','Valor da empresa: R$ '||to_char(coalesce((p.normalizado->>'total_empresa')::numeric,p.total_centavos)/100,'FM999999990.00')),
   jsonb_build_object('nome','PEDIDO NÃO FISCAL$new$);
 EXECUTE d;
END $patch$;
NOTIFY pgrst,'reload schema';

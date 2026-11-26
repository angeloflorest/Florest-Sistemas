CREATE OR REPLACE FUNCTION private.gastronomia_venda(p_id uuid, p_e uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE a public.gastronomia_atendimentos; n bigint; r record; iv bigint; v uuid; total numeric; BEGIN
 SELECT * INTO a FROM public.gastronomia_atendimentos WHERE id=p_id AND empresa_id=p_e FOR UPDATE;
 total:=private.gastronomia_total(p_id,p_e); v:=a.venda_id;
 IF v IS NULL THEN
  IF total<=0 OR private.gastronomia_pago(p_id,p_e)<total THEN RETURN NULL; END IF;
  INSERT INTO public.contadores_venda AS c(empresa_id,ultimo_numero) VALUES(p_e,1) ON CONFLICT(empresa_id) DO UPDATE SET ultimo_numero=c.ultimo_numero+1 RETURNING ultimo_numero INTO n;
  -- Caixa real de cada recebimento é preservado no razão Gastronomia; a venda pode cruzar turnos.
  INSERT INTO public.vendas(empresa_id,numero_venda,cliente_id,forma_pagamento,total,tipo,criado_por) VALUES(p_e,n,a.cliente_id,'dividido',total,'gastronomia',auth.uid()) RETURNING id INTO v;
  UPDATE public.gastronomia_atendimentos SET venda_id=v WHERE id=p_id AND empresa_id=p_e;
 END IF;
 FOR r IN SELECT * FROM public.gastronomia_itens WHERE atendimento_id=p_id AND empresa_id=p_e AND NOT cancelado AND item_venda_id IS NULL LOOP
  INSERT INTO public.itens_venda(empresa_id,venda_id,produto_id,quantidade,preco_unitario) VALUES(p_e,v,r.produto_id,r.quantidade,r.preco_unitario) RETURNING id INTO iv;
  UPDATE public.gastronomia_itens SET item_venda_id=iv WHERE id=r.id AND empresa_id=p_e;
 END LOOP;
 UPDATE public.vendas SET total=private.gastronomia_total(p_id,p_e) WHERE id=v AND empresa_id=p_e;
 UPDATE public.vendas SET gastronomia_canal=a.tipo WHERE id=v AND empresa_id=p_e;
 INSERT INTO public.vendas_pagamentos(id,empresa_id,venda_id,forma_pagamento,valor,ordem,criado_por,criado_em)
 SELECT p.id,p_e,v,p.forma,p.valor-CASE WHEN a.origem='ifood' THEN coalesce((p.metadados->>'ifood_taxa_plataforma')::numeric,0) ELSE 0 END,row_number() OVER(ORDER BY p.criado_em,p.id),p.criado_por,p.criado_em FROM public.gastronomia_pagamentos p WHERE p.empresa_id=p_e AND p.atendimento_id=p_id AND NOT p.estornado AND (p.valor-CASE WHEN a.origem='ifood' THEN coalesce((p.metadados->>'ifood_taxa_plataforma')::numeric,0) ELSE 0 END)>0 ON CONFLICT(id) DO NOTHING;
 -- O motor existente de taxas lê os pagamentos do núcleo (ramo pdv); nenhum Caixa PDV é usado.
 FOR r IN SELECT p.id,p.metadados FROM public.gastronomia_pagamentos p WHERE p.empresa_id=p_e AND p.atendimento_id=p_id AND NOT p.estornado LOOP
  PERFORM private.taxas_registrar('pdv',r.id,r.metadados);
 END LOOP;
 IF a.origem='ifood' THEN
  INSERT INTO public.vendas_pagamentos(id,empresa_id,venda_id,forma_pagamento,valor,ordem,criado_por)
  SELECT ip.id,p_e,v,CASE ip.forma WHEN 'PIX' THEN 'Pix' WHEN 'CREDIT' THEN 'Cartão de Crédito' WHEN 'DEBIT' THEN 'Cartão de Débito' ELSE 'Outros' END,
   coalesce(ip.valor_empresa_centavos,ip.valor_centavos)::numeric/100,1000+ip.indice,NULL
  FROM private.gastronomia_ifood_pagamentos ip JOIN private.gastronomia_ifood_pedidos p ON p.empresa_id=ip.empresa_id AND p.pedido_id=ip.pedido_id
  WHERE ip.empresa_id=p_e AND p.atendimento_id=p_id AND ip.tipo='ONLINE' AND ip.ativo AND coalesce(ip.valor_empresa_centavos,ip.valor_centavos)>0 AND p.estado_ifood<>'cancelado'
  ON CONFLICT(id) DO NOTHING;
 END IF;
 RETURN v;
END $function$


-- Leituras condicionais, sem alterar operações financeiras.
CREATE OR REPLACE FUNCTION public.gastronomia_atualizacao(p_revisao text DEFAULT NULL, p_catalogo_revisao text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_visualizar'); rev text; cat text; ctx jsonb;
BEGIN
 SELECT md5(coalesce(max(atualizado_em)::text,'')||':'||count(*)::text) INTO cat FROM public.produtos WHERE empresa_id=e;
 cat:=md5(cat||coalesce((SELECT to_jsonb(c)::text FROM public.gastronomia_configuracoes c WHERE empresa_id=e),'')
 ||coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id)::text FROM private.gastronomia_produtos_operacionais x WHERE empresa_id=e),'')
 ||coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id)::text FROM private.gastronomia_componentes_operacionais x WHERE empresa_id=e),'')
 ||coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id)::text FROM private.gastronomia_grupos_operacionais x WHERE empresa_id=e),'')
 ||coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id)::text FROM private.gastronomia_opcoes_operacionais x WHERE empresa_id=e),''));
 rev:=md5(cat||coalesce((SELECT revisao::text FROM public.gastronomia_sinais WHERE empresa_id=e),'0')
 ||coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id)::text FROM public.perfis p WHERE empresa_id=e),'')
 ||auth.uid()::text||floor(extract(epoch FROM statement_timestamp())/30)::text);
 IF p_revisao=rev THEN RETURN jsonb_build_object('empresa_id',e,'revisao',rev,'catalogo_revisao',cat,'inalterado',true); END IF;
 ctx:=public.gastronomia_rpc('contexto',jsonb_build_object('sem_catalogo',p_catalogo_revisao=cat));
 RETURN ctx||jsonb_build_object('revisao',rev,'catalogo_revisao',cat,'catalogo_inalterado',coalesce(p_catalogo_revisao=cat,false));
END $f$;
REVOKE ALL ON FUNCTION public.gastronomia_atualizacao(text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_atualizacao(text,text) TO authenticated;

DO $patch$ DECLARE src text; needle text; BEGIN
 src:=pg_get_functiondef('public.gastronomia_rpc(text,jsonb,uuid)'::regprocedure);
 needle:=$n$'catalogo',CASE WHEN private.perm('gastronomia_pedidos') OR private.perm('gastronomia_configurar') THEN$n$;
 IF strpos(src,needle)=0 THEN RAISE EXCEPTION 'Base da leitura Gastronomia mudou; não aplicar substituição.'; END IF;
 src:=replace(src,needle,$n$'catalogo',CASE WHEN NOT coalesce((dados->>'sem_catalogo')::boolean,false) AND (private.perm('gastronomia_pedidos') OR private.perm('gastronomia_configurar')) THEN$n$);
 EXECUTE src;
END $patch$;

-- Mesmas linhas relevantes aos quatro relatórios, filtradas antes da transferência.
CREATE OR REPLACE FUNCTION public.bar_relatorio_dados(p_tipo text,p_inicio date,p_fim date,p_caixa uuid DEFAULT NULL,p_produtos uuid[] DEFAULT '{}'::uuid[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE e uuid:=private.exigir_empresa_ativa(); ini timestamptz; fim timestamptz; r jsonb;
BEGIN
 IF NOT private.empresa_tem_modulo('bar') OR NOT EXISTS(SELECT 1 FROM public.perfis WHERE id=auth.uid() AND empresa_id=e AND ativo AND papel='proprietario') THEN
 RAISE EXCEPTION 'Relatórios do Bar são exclusivos do proprietário.' USING ERRCODE='42501'; END IF;
 IF p_tipo NOT IN ('periodo','caixa','produto','comparativo') OR p_tipo IS NULL OR p_inicio IS NULL OR p_fim IS NULL OR p_fim<p_inicio THEN
 RAISE EXCEPTION 'Filtros de relatório inválidos.' USING ERRCODE='22023'; END IF;
 ini:=p_inicio::timestamp AT TIME ZONE 'America/Sao_Paulo'; fim:=(p_fim+1)::timestamp AT TIME ZONE 'America/Sao_Paulo';
 WITH vi AS MATERIALIZED (SELECT * FROM public.vendas WHERE empresa_id=e AND p_tipo='periodo' AND tipo='bar' AND criado_em>=ini AND criado_em<fim),
 bi AS MATERIALIZED (SELECT * FROM public.bar_pedidos_itens i WHERE i.empresa_id=e AND p_tipo IN ('produto','comparativo') AND
 ((i.criado_em>=ini AND i.criado_em<fim) OR (p_tipo='comparativo' AND EXISTS(SELECT 1 FROM public.bar_pedidos_itens_baixas b WHERE b.empresa_id=e AND b.pedido_item_id=i.id AND b.criado_em>=ini AND b.criado_em<fim AND b.produto_id=ANY(p_produtos))))),
 cs AS MATERIALIZED (SELECT c.* FROM public.bar_comandas c WHERE c.empresa_id=e AND
 ((p_tipo='periodo' AND c.venda_id IN(SELECT id FROM vi)) OR (p_tipo IN ('produto','comparativo') AND c.id IN(SELECT comanda_id FROM bi)))),
 ps AS MATERIALIZED (SELECT p.* FROM public.bar_pagamentos p WHERE p.empresa_id=e AND
 ((p_tipo='periodo' AND p.comanda_id IN(SELECT id FROM cs)) OR (p_tipo='caixa' AND
 ((((p.criado_em>=ini AND p.criado_em<fim) OR (p.estornado_em>=ini AND p.estornado_em<fim)) AND (p_caixa IS NULL OR p.caixa_id=p_caixa)) OR (p.estornado AND p.estornado_em IS NULL))))),
 vs AS MATERIALIZED (SELECT v.* FROM public.vendas v WHERE v.empresa_id=e AND v.tipo='bar' AND
 ((p_tipo='periodo' AND v.id IN(SELECT id FROM vi)) OR (p_tipo IN ('produto','comparativo') AND v.id IN(SELECT venda_id FROM cs))))
 SELECT jsonb_build_object('empresa_id',e,
 'produtos',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) FROM (SELECT id,nome,unidade_comercial FROM public.produtos WHERE empresa_id=e AND p_tipo IN ('produto','comparativo'))t),
 'mesas',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) FROM (SELECT id,numero FROM public.bar_mesas WHERE empresa_id=e AND id IN(SELECT mesa_id FROM cs))t),
 'caixas',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) FROM (SELECT id,numero,tipo_caixa,aberto_por_nome,aberto_em,fechado_em FROM public.caixas WHERE empresa_id=e AND tipo_caixa='BAR' AND id IN(SELECT caixa_id FROM ps))t),
 'comandas',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) FROM (SELECT id,mesa_id,venda_id,status,cancelada_em FROM cs WHERE true)t),
 'vendas',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) FROM (SELECT id,numero_venda,tipo,total,criado_em,cancelada_em FROM vs WHERE true)t),
 'pagamentos',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) FROM (SELECT id,comanda_id,venda_id,caixa_id,total,criado_em,estornado,estornado_em FROM ps WHERE true)t),
 'formas',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) FROM (SELECT id,pagamento_id,forma_pagamento,valor FROM public.bar_pagamentos_formas WHERE empresa_id=e AND pagamento_id IN(SELECT id FROM ps))t),
 'itens',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) FROM (SELECT id,comanda_id,produto_id,bar_produto_id,quantidade,preco_unitario,criado_em,estornado FROM bi WHERE true)t),
 'baixas',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) FROM (SELECT id,pedido_item_id,produto_id,quantidade,criado_em,estornada FROM public.bar_pedidos_itens_baixas WHERE empresa_id=e AND p_tipo='comparativo' AND pedido_item_id IN(SELECT id FROM bi))t),
 'barProdutos',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) FROM (SELECT id,produto_id FROM public.bar_produtos WHERE empresa_id=e AND id IN(SELECT bar_produto_id FROM bi))t) ) INTO r;
 RETURN r;
END $f$;
REVOKE ALL ON FUNCTION public.bar_relatorio_dados(text,date,date,uuid,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bar_relatorio_dados(text,date,date,uuid,uuid[]) TO authenticated;


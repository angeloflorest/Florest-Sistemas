-- Consultas por data civil de São Paulo; somente leitura e isoladas pela sessão.
CREATE INDEX IF NOT EXISTS gastronomia_atendimentos_data ON public.gastronomia_atendimentos(empresa_id,criado_em DESC);
CREATE INDEX IF NOT EXISTS gastronomia_ifood_pedidos_data ON private.gastronomia_ifood_pedidos(empresa_id,criado_em DESC);
CREATE FUNCTION public.gastronomia_pedidos_data(p_data date DEFAULT (now() AT TIME ZONE 'America/Sao_Paulo')::date,p_empresa uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_visualizar');inicio timestamptz;fim timestamptz;atds jsonb;inbox jsonb;
BEGIN
 IF p_empresa IS DISTINCT FROM e OR p_data IS NULL THEN RAISE EXCEPTION 'Empresa ou data inválida.' USING ERRCODE='42501';END IF;
 inicio:=p_data::timestamp AT TIME ZONE 'America/Sao_Paulo';fim:=(p_data+1)::timestamp AT TIME ZONE 'America/Sao_Paulo';
 atds:=(SELECT coalesce(jsonb_agg(z.doc ORDER BY z.criado_em DESC),'[]') FROM (SELECT a1.criado_em,to_jsonb(a1)||jsonb_build_object('financeiro',private.gastronomia_financeiro_detalhe(a1.id,e),'numero_venda',(SELECT numero_venda FROM public.vendas WHERE id=a1.venda_id AND empresa_id=e),'impressao',private.gastronomia_impressao_estado(a1.id,e),'mesa_numero',(SELECT numero FROM public.gastronomia_mesas WHERE id=a1.mesa_id AND empresa_id=e),'total',private.gastronomia_total(a1.id,e),'pago',private.gastronomia_pago(a1.id,e),'itens',(SELECT coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('autor_nome',(SELECT pf.nome FROM public.perfis pf WHERE pf.id=i.criado_por AND pf.empresa_id=e),'preparo',(SELECT coalesce(jsonb_agg(to_jsonb(pr)),'[]') FROM public.gastronomia_preparo pr WHERE pr.item_id=i.id AND pr.empresa_id=e)) ORDER BY i.criado_em),'[]') FROM public.gastronomia_itens i WHERE i.atendimento_id=a1.id AND i.empresa_id=e),'pagamentos',CASE WHEN private.perm('gastronomia_caixa') OR private.perm('gastronomia_estornar') THEN (SELECT coalesce(jsonb_agg(to_jsonb(p)),'[]') FROM public.gastronomia_pagamentos p WHERE p.atendimento_id=a1.id AND p.empresa_id=e) ELSE '[]'::jsonb END) doc FROM public.gastronomia_atendimentos a1 WHERE a1.empresa_id=e AND a1.tipo<>'mesa' AND a1.criado_em>=inicio AND a1.criado_em<fim ORDER BY (a1.estado='aberto') DESC,a1.criado_em DESC LIMIT 1000) z);
 inbox:=jsonb_build_object('empresa_id',e,'conectado',coalesce((SELECT habilitada FROM private.gastronomia_ifood_config WHERE empresa_id=e),false),'falhas','[]'::jsonb,'pedidos',CASE WHEN private.perm('gastronomia_pedidos') THEN
 (SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.criado_em DESC),'[]') FROM (SELECT ip.pedido_id,ip.atendimento_id,ip.estado_ifood,ip.normalizado,ip.revisao_motivo,ip.negociacao,ip.criado_em,
 (SELECT coalesce(jsonb_agg(jsonb_build_object('acao',ic.acao,'estado',ic.estado)),'[]') FROM private.gastronomia_ifood_comandos ic WHERE ic.empresa_id=e AND ic.pedido_id=ip.pedido_id) comandos
 FROM private.gastronomia_ifood_pedidos ip WHERE ip.empresa_id=e AND ip.criado_em>=inicio AND ip.criado_em<fim ORDER BY ip.criado_em DESC LIMIT 1000) z) ELSE '[]'::jsonb END);
 RETURN jsonb_build_object('empresa_id',e,'data',p_data,'atendimentos',atds,'ifood',inbox,'limite',1000,'total',(SELECT count(*) FROM public.gastronomia_atendimentos a WHERE a.empresa_id=e AND a.tipo<>'mesa' AND a.criado_em>=inicio AND a.criado_em<fim)+(SELECT count(*) FROM private.gastronomia_ifood_pedidos ip WHERE ip.empresa_id=e AND ip.criado_em>=inicio AND ip.criado_em<fim AND ip.atendimento_id IS NULL));
END $fn$;
REVOKE ALL ON FUNCTION public.gastronomia_pedidos_data(date,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_pedidos_data(date,uuid) TO authenticated;

CREATE FUNCTION public.gastronomia_vendas_canais(p_inicio date,p_fim date,p_origem text DEFAULT 'todos',p_empresa uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_caixa');inicio timestamptz;fim timestamptz;rows jsonb;recebimentos jsonb;
BEGIN
 IF p_empresa IS DISTINCT FROM e OR p_inicio IS NULL OR p_fim IS NULL OR p_fim<p_inicio OR p_fim-p_inicio>92 OR p_origem NOT IN ('todos','ifood','99food','site') THEN RAISE EXCEPTION 'Empresa, origem ou período inválido (máximo 93 dias).';END IF;
 inicio:=p_inicio::timestamp AT TIME ZONE 'America/Sao_Paulo';fim:=(p_fim+1)::timestamp AT TIME ZONE 'America/Sao_Paulo';
 WITH pedidos AS (
 SELECT a.id,a.numero::text numero,a.origem,a.criado_em,a.estado,private.gastronomia_total(a.id,e) total,
 0::numeric online,0::numeric taxas,false teste
 FROM public.gastronomia_atendimentos a WHERE a.empresa_id=e AND a.tipo<>'mesa' AND a.origem<>'ifood' AND a.criado_em>=inicio AND a.criado_em<fim AND (p_origem='todos' OR a.origem=p_origem)
 UNION ALL
 SELECT ip.pedido_id,ip.normalizado->>'numero','ifood',ip.criado_em,ip.estado_ifood,ip.total_centavos/100.0,
 CASE WHEN ip.estado_ifood IN ('confirmado','em_preparo','pronto','despachado','concluido') THEN coalesce((ip.normalizado->>'pago_online_empresa')::numeric,ip.pago_online_centavos)/100 ELSE 0 END,
 coalesce((ip.normalizado->>'taxas_ifood')::numeric,0)/100,coalesce((ip.detalhe->>'isTest')::boolean,false)
 FROM private.gastronomia_ifood_pedidos ip WHERE ip.empresa_id=e AND ip.criado_em>=inicio AND ip.criado_em<fim AND p_origem IN ('todos','ifood')
 ) SELECT coalesce(jsonb_agg(to_jsonb(pedidos) ORDER BY criado_em DESC),'[]') INTO rows FROM pedidos;
 SELECT coalesce(jsonb_agg(to_jsonb(z)),'[]') INTO recebimentos FROM (
 SELECT a.origem,pg.forma,sum(pg.valor) valor,count(*) quantidade FROM public.gastronomia_pagamentos pg JOIN public.gastronomia_atendimentos a ON a.id=pg.atendimento_id AND a.empresa_id=e
 WHERE pg.empresa_id=e AND NOT pg.estornado AND pg.criado_em>=inicio AND pg.criado_em<fim AND (p_origem='todos' OR a.origem=p_origem) GROUP BY a.origem,pg.forma) z;
 RETURN jsonb_build_object('empresa_id',e,'inicio',p_inicio,'fim',p_fim,'pedidos',rows,'recebimentos',recebimentos,'repasse_bancario',NULL,'observacao','Vendas pela data de entrada do pedido; recebimentos presenciais pela data do pagamento. Pagamento online não comprova depósito bancário. Comissões, antecipações e ajustes dependem do extrato financeiro da plataforma.');
END $fn$;
REVOKE ALL ON FUNCTION public.gastronomia_vendas_canais(date,date,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_vendas_canais(date,date,text,uuid) TO authenticated;

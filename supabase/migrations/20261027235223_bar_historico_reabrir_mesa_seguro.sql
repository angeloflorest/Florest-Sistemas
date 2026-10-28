-- PROPOSTA PARA REVISÃO. NÃO APLICADA EM PRODUÇÃO.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $guard$ BEGIN
 IF to_regclass('private.bar_reaberturas') IS NOT NULL OR to_regprocedure('public.bar_historico_mesa_editar(uuid,text,jsonb,text,uuid)') IS NOT NULL THEN RAISE EXCEPTION 'Reabertura já instalada. Não reinstalar.'; END IF;
 IF md5(pg_get_functiondef('public.bar_pedido_enviar(uuid,jsonb,uuid)'::regprocedure))<>'c99e1d6ae77f5e010ea682374494ab89' THEN RAISE EXCEPTION 'Função alterada: bar_pedido_enviar. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.bar_comanda_pagar_valor(uuid,numeric,jsonb,uuid,numeric,numeric,numeric)'::regprocedure))<>'0df302432619f770672a588db36ccf36' THEN RAISE EXCEPTION 'Função alterada: bar_comanda_pagar_valor. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.bar_comanda_finalizar_venda(uuid,uuid)'::regprocedure))<>'12c99f4de91cad4cfbf5cca0c2f49588' THEN RAISE EXCEPTION 'Função alterada: bar_comanda_finalizar_venda. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.bar_mesa_fechar(uuid)'::regprocedure))<>'2ffe69a5dd9d17cf474a80f393d65c8e' THEN RAISE EXCEPTION 'Função alterada: bar_mesa_fechar. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.bar_comanda_pagar(uuid,uuid[],jsonb,numeric,numeric,numeric,integer)'::regprocedure))<>'77c602264144db0c3c862c382e4be6d9' THEN RAISE EXCEPTION 'Função alterada: bar_comanda_pagar. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.bar_comanda_finalizar_nota_prazo(uuid,uuid,date)'::regprocedure))<>'7f6def81879034500daae079d25efa8b' THEN RAISE EXCEPTION 'Função alterada: bar_comanda_finalizar_nota_prazo. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.bar_pagamento_estornar(uuid,text)'::regprocedure))<>'25b61326917d3323c113df231ab99154' THEN RAISE EXCEPTION 'Função alterada: bar_pagamento_estornar. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.bar_pedido_item_cancelar(uuid,text)'::regprocedure))<>'9d8bdc87f15cd489377ada28d259cbba' THEN RAISE EXCEPTION 'Função alterada: bar_pedido_item_cancelar. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.bar_mesa_transferir(uuid,integer)'::regprocedure))<>'ca83542de0855dd090dceeab45bc6611' THEN RAISE EXCEPTION 'Função alterada: bar_mesa_transferir. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.florest_venda_corrigir(uuid,jsonb,text,uuid)'::regprocedure))<>'48c54afcee10f9f742d1ad86aeced7e2' THEN RAISE EXCEPTION 'Função alterada: florest_venda_corrigir. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.bar_historico_cancelar(uuid,text,uuid)'::regprocedure))<>'22ab7b44fe05af70a2455432bcce821b' THEN RAISE EXCEPTION 'Função alterada: bar_historico_cancelar. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.bar_historico_refazer(uuid,uuid,text,uuid)'::regprocedure))<>'e5e8cd095946fcd5904d459ef32e8012' THEN RAISE EXCEPTION 'Função alterada: bar_historico_refazer. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.bar_comanda_saldo_calcular(uuid,uuid)'::regprocedure))<>'4094ea7f3b253313c70b54f3a639a586' THEN RAISE EXCEPTION 'Função alterada: bar_comanda_saldo_calcular. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.bar_historico_exigir(text)'::regprocedure))<>'f88eaf62c9180b4b606dac32bcafdac1' THEN RAISE EXCEPTION 'Função alterada: bar_historico_exigir. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.bar_venda_recalcular_forma_pagamento(uuid,uuid)'::regprocedure))<>'8ee12ba8ddce8026ff7cabd609425f16' THEN RAISE EXCEPTION 'Função alterada: bar_venda_recalcular_forma_pagamento. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.caixa_bar_pode_acessar(uuid,uuid)'::regprocedure))<>'b9c3cb650464219e813f4efb905566be' THEN RAISE EXCEPTION 'Função alterada: caixa_bar_pode_acessar. Não remover esta proteção.'; END IF;
END $guard$;
-- PROPOSTA LOCAL. NÃO EXECUTADA. Instalação depende de revisão e autorização posterior.
CREATE TABLE private.bar_reaberturas (
 empresa_id uuid NOT NULL REFERENCES public.empresas(id),
 comanda_id uuid NOT NULL, venda_id uuid NOT NULL, mesa_id uuid NOT NULL, caixa_id uuid NOT NULL,
 ativa boolean NOT NULL DEFAULT true, versao bigint NOT NULL DEFAULT 1,
 aberto_por uuid NOT NULL, motivo text NOT NULL, aberto_em timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(empresa_id,comanda_id), UNIQUE(empresa_id,venda_id)
);
ALTER TABLE private.bar_reaberturas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.bar_reaberturas FROM PUBLIC,anon,authenticated;

-- Nunca deduz o caixa pelo terminal atual nem pelo último caixa da empresa.
CREATE FUNCTION private.bar_reabertura_validar(p_comanda uuid,p_empresa uuid) RETURNS void
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE c public.bar_comandas; v public.vendas; cx public.caixas;
BEGIN
 SELECT * INTO c FROM public.bar_comandas WHERE id=p_comanda AND empresa_id=p_empresa;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada.'; END IF;
 SELECT * INTO v FROM public.vendas WHERE id=c.venda_id AND empresa_id=p_empresa FOR UPDATE;
 IF v.id IS NULL OR v.tipo IS DISTINCT FROM 'bar' OR v.cancelada_em IS NOT NULL THEN RAISE EXCEPTION 'Venda do Bar inconsistente ou cancelada.'; END IF;
 SELECT * INTO cx FROM public.caixas WHERE id=v.caixa_id AND empresa_id=p_empresa FOR SHARE;
 IF cx.id IS NULL OR cx.tipo_caixa<>'BAR' OR cx.status<>'aberto' THEN RAISE EXCEPTION 'O caixa original da venda deve continuar aberto.' USING ERRCODE='CX001'; END IF;
 IF NOT private.caixa_bar_pode_acessar(p_empresa,cx.aberto_por) THEN RAISE EXCEPTION 'Sem permissão para operar o caixa original desta venda.' USING ERRCODE='42501'; END IF;
 IF EXISTS(SELECT 1 FROM public.documentos_fiscais WHERE empresa_id=p_empresa AND venda_id=v.id)
 OR EXISTS(SELECT 1 FROM public.fiscal_contingencia_documentos WHERE empresa_id=p_empresa AND venda_id=v.id)
 THEN RAISE EXCEPTION 'Qualquer documento fiscal vinculado impede esta edição.'; END IF;
 PERFORM 1 FROM public.bar_pagamentos WHERE empresa_id=p_empresa AND comanda_id=c.id ORDER BY id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.bar_pagamentos pa WHERE pa.empresa_id=p_empresa AND pa.comanda_id=c.id AND (pa.caixa_id IS DISTINCT FROM cx.id OR (pa.venda_id IS DISTINCT FROM v.id AND NOT (pa.venda_id IS NULL AND EXISTS(SELECT 1 FROM private.bar_reaberturas re WHERE re.empresa_id=p_empresa AND re.comanda_id=c.id AND re.ativa AND pa.criado_em>=re.aberto_em)))))
 OR EXISTS(SELECT 1 FROM public.bar_pagamentos WHERE empresa_id=p_empresa AND venda_id=v.id AND comanda_id<>c.id)
 THEN RAISE EXCEPTION 'Pagamentos fora do caixa ou da comanda original: conciliação necessária.'; END IF;
 IF EXISTS(SELECT 1 FROM public.bar_pagamentos pa WHERE pa.empresa_id=p_empresa AND pa.comanda_id=c.id AND NOT pa.estornado AND (pa.total IS DISTINCT FROM (SELECT sum(f.valor) FROM public.bar_pagamentos_formas f WHERE f.empresa_id=p_empresa AND f.pagamento_id=pa.id)
 OR EXISTS(SELECT 1 FROM public.bar_pagamentos_formas f WHERE f.empresa_id=p_empresa AND f.pagamento_id=pa.id AND (f.valor<=0 OR length(btrim(f.forma_pagamento))=0))))
 THEN RAISE EXCEPTION 'Formas e total do recebimento não conferem: conciliação necessária.'; END IF;
 IF EXISTS(SELECT 1 FROM public.contas_receber WHERE empresa_id=p_empresa AND venda_id=v.id)
 OR EXISTS(SELECT 1 FROM public.vendas_pagamentos WHERE empresa_id=p_empresa AND venda_id=v.id)
 THEN RAISE EXCEPTION 'Venda com título ou pagamento externo ao Bar: conciliação necessária.'; END IF;
 -- Modelo antigo atribui descontos e pagamentos aos itens. Não converter silenciosamente.
 IF EXISTS(SELECT 1 FROM public.bar_pedidos_itens WHERE empresa_id=p_empresa AND comanda_id=c.id AND pagamento_id IS NOT NULL)
 THEN RAISE EXCEPTION 'Pagamento legado vinculado a itens: reabertura exige conciliação específica, sem conversão automática.'; END IF;
END $$;
REVOKE ALL ON FUNCTION private.bar_reabertura_validar(uuid,uuid) FROM PUBLIC,anon,authenticated;

-- Ordem única nas operações reabertas: mesa -> comanda -> venda -> caixa -> pagamentos.
-- NOWAIT evita espera circular com as rotinas legadas; erro desfaz a transação inteira.
CREATE FUNCTION private.bar_reabertura_guardar(p_comanda uuid,p_empresa uuid) RETURNS boolean
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE r private.bar_reaberturas; c public.bar_comandas; m public.bar_mesas;
BEGIN
 SELECT * INTO r FROM private.bar_reaberturas WHERE empresa_id=p_empresa AND comanda_id=p_comanda AND ativa;
 IF NOT FOUND THEN RETURN false; END IF;
 PERFORM private.bar_historico_exigir('bar_venda_editar');
 IF NOT pg_try_advisory_xact_lock(hashtextextended(p_empresa::text||':bar:reabrir:'||p_comanda::text,0)) THEN RAISE EXCEPTION 'Conta em edição em outro terminal. Atualize e tente novamente.' USING ERRCODE='40001'; END IF;
 SELECT * INTO m FROM public.bar_mesas WHERE id=r.mesa_id AND empresa_id=p_empresa FOR UPDATE NOWAIT;
 SELECT * INTO c FROM public.bar_comandas WHERE id=p_comanda AND empresa_id=p_empresa FOR UPDATE NOWAIT;
 IF m.status<>'ocupada' OR m.comanda_atual_id IS DISTINCT FROM c.id OR c.status<>'aberta' OR c.venda_id IS DISTINCT FROM r.venda_id OR c.mesa_id IS DISTINCT FROM r.mesa_id
 THEN RAISE EXCEPTION 'A mesa não pertence mais à reabertura. Atualize os dados.'; END IF;
 PERFORM private.bar_reabertura_validar(p_comanda,p_empresa);
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION private.bar_reabertura_guardar(uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.bar_reabertura_snapshot(p_comanda uuid,p_empresa uuid) RETURNS jsonb
LANGUAGE sql SET search_path='' AS $$
 SELECT jsonb_build_object('comanda',to_jsonb(c),'venda',(SELECT to_jsonb(v) FROM public.vendas v WHERE v.id=c.venda_id AND v.empresa_id=p_empresa),
 'itens',(SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]') FROM public.bar_pedidos_itens i WHERE i.comanda_id=c.id AND i.empresa_id=p_empresa),
 'baixas',(SELECT coalesce(jsonb_agg(to_jsonb(b) ORDER BY b.id),'[]') FROM public.bar_pedidos_itens_baixas b JOIN public.bar_pedidos_itens i ON i.id=b.pedido_item_id AND i.empresa_id=b.empresa_id WHERE i.comanda_id=c.id AND i.empresa_id=p_empresa),
 'itens_venda',(SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id),'[]') FROM public.itens_venda i WHERE i.venda_id=c.venda_id AND i.empresa_id=p_empresa),
 'pagamentos',(SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY id),'[]') FROM public.bar_pagamentos p WHERE p.comanda_id=c.id AND p.empresa_id=p_empresa),
 'formas',(SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.id),'[]') FROM public.bar_pagamentos_formas f JOIN public.bar_pagamentos p ON p.id=f.pagamento_id AND p.empresa_id=f.empresa_id WHERE p.comanda_id=c.id AND p.empresa_id=p_empresa),
 'escolhas',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.id),'[]') FROM public.bar_pedidos_itens_escolhas x JOIN public.bar_pedidos_itens i ON i.id=x.pedido_item_id AND i.empresa_id=x.empresa_id WHERE i.comanda_id=c.id AND i.empresa_id=p_empresa))
 FROM public.bar_comandas c WHERE c.id=p_comanda AND c.empresa_id=p_empresa
$$;
REVOKE ALL ON FUNCTION private.bar_reabertura_snapshot(uuid,uuid) FROM PUBLIC,anon,authenticated;

-- Atualiza o snapshot COMERCIAL da mesma venda; não movimenta estoque/pagamentos.
CREATE FUNCTION private.bar_reabertura_sincronizar(p_comanda uuid,p_empresa uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE c public.bar_comandas; i public.bar_pedidos_itens; iv bigint; s record;
BEGIN
 SELECT * INTO c FROM public.bar_comandas WHERE id=p_comanda AND empresa_id=p_empresa;
 IF NOT EXISTS(SELECT 1 FROM private.bar_reaberturas WHERE empresa_id=p_empresa AND comanda_id=c.id AND ativa) THEN RETURN c.venda_id; END IF;
 FOR i IN SELECT * FROM public.bar_pedidos_itens WHERE comanda_id=c.id AND empresa_id=p_empresa ORDER BY id FOR UPDATE LOOP
  IF i.item_venda_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.itens_venda WHERE id=i.item_venda_id AND empresa_id=p_empresa AND venda_id=c.venda_id AND produto_id=i.produto_id) THEN RAISE EXCEPTION 'Vínculo de item de venda inconsistente.'; END IF;
  IF i.estornado THEN
   -- Só o snapshot comercial do item cancelado. Registro operacional/baixas/auditoria permanecem.
   DELETE FROM public.itens_venda WHERE id=i.item_venda_id AND empresa_id=p_empresa AND venda_id=c.venda_id;
   UPDATE public.bar_pedidos_itens SET item_venda_id=NULL WHERE id=i.id AND empresa_id=p_empresa;
  ELSIF i.item_venda_id IS NULL THEN
   INSERT INTO public.itens_venda(empresa_id,venda_id,produto_id,quantidade,preco_unitario) VALUES(p_empresa,c.venda_id,i.produto_id,i.quantidade,i.preco_unitario) RETURNING id INTO iv;
   UPDATE public.bar_pedidos_itens SET item_venda_id=iv WHERE id=i.id AND empresa_id=p_empresa;
  ELSE
   UPDATE public.itens_venda SET quantidade=i.quantidade,preco_unitario=i.preco_unitario WHERE id=i.item_venda_id AND empresa_id=p_empresa AND venda_id=c.venda_id;
  END IF;
 END LOOP;
 UPDATE public.bar_pagamentos SET venda_id=c.venda_id WHERE comanda_id=c.id AND empresa_id=p_empresa AND venda_id IS NULL;
 SELECT * INTO s FROM private.bar_comanda_saldo_calcular(c.id,p_empresa);
 IF s.saldo < -0.01 THEN RAISE EXCEPTION 'Pagamentos superam o novo total. Estorne um recebimento antes de reduzir produtos.'; END IF;
 UPDATE public.vendas SET total=s.total_final WHERE id=c.venda_id AND empresa_id=p_empresa;
 PERFORM private.bar_venda_recalcular_forma_pagamento(c.venda_id,p_empresa);
 UPDATE private.bar_reaberturas SET versao=versao+1 WHERE empresa_id=p_empresa AND comanda_id=c.id;
 RETURN c.venda_id;
END $$;
REVOKE ALL ON FUNCTION private.bar_reabertura_sincronizar(uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.bar_historico_mesa_editar(p_comanda_id uuid,p_acao text,p_dados jsonb DEFAULT '{}',p_motivo text DEFAULT '',p_idempotencia uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid:=private.exigir_empresa_ativa(); c public.bar_comandas; m public.bar_mesas; v public.vendas;
 r private.bar_reaberturas; a public.florest_auditoria_operacoes; i public.bar_pedidos_itens; pa public.bar_pagamentos;
 b record; s record; q numeric; delta numeric; anterior jsonb; resposta jsonb; pedido jsonb;
BEGIN
 IF NOT private.empresa_tem_modulo('bar') THEN RAISE EXCEPTION 'Módulo Bar indisponível.' USING ERRCODE='42501'; END IF;
 IF p_acao='contexto' THEN
  IF NOT private.perm_alguma(ARRAY['bar_visualizar','bar_mesas','bar_pedidos','bar_caixa']) THEN RAISE EXCEPTION 'Sem permissão.' USING ERRCODE='42501'; END IF;
  SELECT * INTO r FROM private.bar_reaberturas WHERE empresa_id=e AND comanda_id=p_comanda_id AND ativa;
  RETURN jsonb_build_object('ativa',r.comanda_id IS NOT NULL,'venda_id',r.venda_id,'versao',r.versao,'mesa_id',r.mesa_id);
 END IF;
 PERFORM private.bar_historico_exigir('bar_venda_editar');
 PERFORM private.bar_historico_exigir('bar_mesas');
 IF p_acao NOT IN ('reabrir','quantidade','estornar_pagamento','fechar') THEN RAISE EXCEPTION 'Ação inválida.'; END IF;
 IF p_idempotencia IS NULL OR coalesce(length(btrim(p_motivo)),0) NOT BETWEEN 3 AND 200 THEN RAISE EXCEPTION 'Informe identificador e motivo de 3 a 200 caracteres.'; END IF;
 pedido:=jsonb_build_object('acao',p_acao,'dados',p_dados);
 IF NOT pg_try_advisory_xact_lock(hashtextextended(e::text||':bar:reabrir:'||p_comanda_id::text,0)) THEN RAISE EXCEPTION 'Conta em edição em outro terminal. Atualize e tente novamente.' USING ERRCODE='40001'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotencia::text,182));
 SELECT * INTO a FROM public.florest_auditoria_operacoes WHERE id=p_idempotencia;
 IF FOUND THEN
  IF a.empresa_id IS DISTINCT FROM e OR a.solicitante_id IS DISTINCT FROM auth.uid() OR a.alvo_id IS DISTINCT FROM p_comanda_id OR a.operacao<>'bar_mesa_reedicao' OR a.motivo IS DISTINCT FROM p_motivo OR a.depois->'pedido' IS DISTINCT FROM pedido THEN RAISE EXCEPTION 'Identificador usado em outra operação.'; END IF;
  RETURN a.depois->'resposta';
 END IF;
 SELECT * INTO c FROM public.bar_comandas WHERE id=p_comanda_id AND empresa_id=e;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada.' USING ERRCODE='42501'; END IF;
 SELECT * INTO m FROM public.bar_mesas WHERE id=c.mesa_id AND empresa_id=e FOR UPDATE NOWAIT;
 SELECT * INTO c FROM public.bar_comandas WHERE id=p_comanda_id AND empresa_id=e FOR UPDATE NOWAIT;
 PERFORM private.bar_reabertura_validar(c.id,e);
 SELECT * INTO v FROM public.vendas WHERE id=c.venda_id AND empresa_id=e;
 anterior:=private.bar_reabertura_snapshot(c.id,e);
 IF p_acao='reabrir' THEN
  PERFORM private.bar_historico_exigir('bar_historico_detalhar');
  IF c.status<>'fechada' OR c.fechada_em IS NULL OR m.status<>'livre' OR m.comanda_atual_id IS NOT NULL THEN RAISE EXCEPTION 'Venda deve estar fechada e a mesa original livre.'; END IF;
  IF EXISTS(SELECT 1 FROM public.bar_comandas c2 WHERE c2.empresa_id=e AND c2.mesa_id=m.id AND c2.id<>c.id AND c2.criado_em>=c.criado_em)
  OR EXISTS(SELECT 1 FROM public.bar_pedidos pe WHERE pe.comanda_id=c.id AND pe.empresa_id=e AND pe.mesa_id<>m.id)
  OR EXISTS(SELECT 1 FROM public.bar_eventos be WHERE be.empresa_id=e AND be.comanda_id=c.id AND (be.tipo LIKE '%junt%' OR be.tipo LIKE '%transfer%'))
  THEN RAISE EXCEPTION 'Mesa reutilizada, transferida ou conta juntada: exige conferência específica.'; END IF;
  IF EXISTS(SELECT 1 FROM public.itens_venda iv WHERE iv.empresa_id=e AND iv.venda_id=v.id AND NOT EXISTS(SELECT 1 FROM public.bar_pedidos_itens pi WHERE pi.empresa_id=e AND pi.comanda_id=c.id AND NOT pi.estornado AND pi.item_venda_id=iv.id AND pi.produto_id=iv.produto_id AND pi.quantidade=iv.quantidade AND pi.preco_unitario=iv.preco_unitario))
  OR EXISTS(SELECT 1 FROM public.bar_pedidos_itens pi WHERE pi.empresa_id=e AND pi.comanda_id=c.id AND NOT pi.estornado AND (pi.item_venda_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.itens_venda iv WHERE iv.id=pi.item_venda_id AND iv.venda_id=v.id AND iv.empresa_id=e)))
  THEN RAISE EXCEPTION 'Itens operacionais e faturados não correspondem. Reabertura bloqueada.'; END IF;
  SELECT * INTO s FROM private.bar_comanda_saldo_calcular(c.id,e);
  IF abs(s.saldo)>0.01 OR abs(s.total_final-v.total)>0.01 THEN RAISE EXCEPTION 'Venda não está quitada ou total divergente.'; END IF;
  INSERT INTO private.bar_reaberturas(empresa_id,comanda_id,venda_id,mesa_id,caixa_id,aberto_por,motivo)
  VALUES(e,c.id,v.id,m.id,v.caixa_id,auth.uid(),btrim(p_motivo)) ON CONFLICT(empresa_id,comanda_id) DO UPDATE SET ativa=true,versao=private.bar_reaberturas.versao+1,aberto_por=auth.uid(),motivo=excluded.motivo,aberto_em=now();
  UPDATE public.bar_comandas SET status='aberta',fechada_em=NULL WHERE id=c.id AND empresa_id=e;
  UPDATE public.bar_mesas SET status='ocupada',comanda_atual_id=c.id,aberta_em=now(),pessoas_atual=0 WHERE id=m.id AND empresa_id=e;
 ELSE
  IF NOT private.bar_reabertura_guardar(c.id,e) THEN RAISE EXCEPTION 'Reabertura não está ativa.'; END IF;
  SELECT * INTO r FROM private.bar_reaberturas WHERE empresa_id=e AND comanda_id=c.id;
  IF (p_dados->>'versao')::bigint IS DISTINCT FROM r.versao THEN RAISE EXCEPTION 'Conta alterada por outro terminal. Atualize antes de continuar.' USING ERRCODE='40001'; END IF;
  IF p_acao='quantidade' THEN
   PERFORM private.bar_historico_exigir('bar_cancelar_pedido');
   SELECT * INTO i FROM public.bar_pedidos_itens WHERE id=(p_dados->>'item_id')::uuid AND comanda_id=c.id AND empresa_id=e FOR UPDATE;
   IF i.id IS NULL OR i.estornado THEN RAISE EXCEPTION 'Item inválido ou já cancelado.'; END IF;
   q:=(p_dados->>'quantidade')::numeric;
   IF q IS NULL OR q<0 OR q>100000 OR q<>round(q,4) OR q=i.quantidade THEN RAISE EXCEPTION 'Quantidade inválida ou sem alteração.'; END IF;
   IF q>i.quantidade THEN PERFORM private.bar_historico_exigir('bar_pedidos'); END IF;
   IF NOT EXISTS(SELECT 1 FROM public.bar_pedidos_itens_baixas WHERE pedido_item_id=i.id AND empresa_id=e AND NOT estornada)
   OR EXISTS(SELECT 1 FROM public.bar_pedidos_itens_baixas WHERE pedido_item_id=i.id AND empresa_id=e AND (estornada OR quantidade<=0))
   THEN RAISE EXCEPTION 'Item sem baixas efetivas completas: ajuste de estoque bloqueado.'; END IF;
   IF q>0 AND (EXISTS(SELECT 1 FROM public.bar_pedidos_itens_baixas WHERE pedido_item_id=i.id AND empresa_id=e AND NOT estornada AND quantidade*q/i.quantidade<>round(quantidade*q/i.quantidade,4))
   OR EXISTS(SELECT 1 FROM public.bar_pedidos_itens_escolhas WHERE pedido_item_id=i.id AND empresa_id=e AND quantidade*q/i.quantidade<>round(quantidade*q/i.quantidade,4)))
   THEN RAISE EXCEPTION 'Proporção de estoque não representável com quatro casas: ajuste bloqueado, sem arredondamento presumido.'; END IF;
   PERFORM 1 FROM public.produtos WHERE empresa_id=e AND id IN(SELECT produto_id FROM public.bar_pedidos_itens_baixas WHERE pedido_item_id=i.id AND empresa_id=e) ORDER BY id FOR UPDATE;
   FOR b IN SELECT produto_id,sum(quantidade) qtd FROM public.bar_pedidos_itens_baixas WHERE pedido_item_id=i.id AND empresa_id=e AND NOT estornada GROUP BY produto_id ORDER BY produto_id LOOP
    delta:=b.qtd*(q-i.quantidade)/i.quantidade;
    IF delta>0 THEN
     PERFORM private.produto_exigir_ativo(e,b.produto_id);
     IF NOT EXISTS(SELECT 1 FROM public.produtos WHERE empresa_id=e AND id=b.produto_id AND quantidade_estoque>=delta) THEN RAISE EXCEPTION 'Estoque insuficiente para aumentar a quantidade.'; END IF;
    END IF;
    UPDATE public.produtos SET quantidade_estoque=quantidade_estoque-delta WHERE id=b.produto_id AND empresa_id=e;
    IF NOT FOUND THEN RAISE EXCEPTION 'Produto da baixa não encontrado.'; END IF;
   END LOOP;
   IF q=0 THEN
    UPDATE public.bar_pedidos_itens_baixas SET estornada=true WHERE pedido_item_id=i.id AND empresa_id=e AND NOT estornada;
    UPDATE public.bar_pedidos_itens SET estornado=true,estornado_em=now(),estornado_por=auth.uid(),estorno_motivo=btrim(p_motivo) WHERE id=i.id AND empresa_id=e;
   ELSE
    UPDATE public.bar_pedidos_itens_baixas SET quantidade=quantidade*q/i.quantidade WHERE pedido_item_id=i.id AND empresa_id=e AND NOT estornada;
    UPDATE public.bar_pedidos_itens_escolhas SET quantidade=quantidade*q/i.quantidade WHERE pedido_item_id=i.id AND empresa_id=e;
    UPDATE public.bar_pedidos_itens SET quantidade=q WHERE id=i.id AND empresa_id=e;
   END IF;
   PERFORM private.bar_reabertura_sincronizar(c.id,e);
  ELSIF p_acao='estornar_pagamento' THEN
   PERFORM private.bar_historico_exigir('bar_estornar_pagamento');
   SELECT * INTO pa FROM public.bar_pagamentos WHERE id=(p_dados->>'pagamento_id')::uuid AND comanda_id=c.id AND empresa_id=e FOR UPDATE;
   IF pa.id IS NULL OR pa.estornado THEN RAISE EXCEPTION 'Recebimento inválido ou já estornado.'; END IF;
   IF (p_dados->>'valor_confirmado')::numeric IS DISTINCT FROM pa.total THEN RAISE EXCEPTION 'Confirme o valor integral do recebimento; suas formas não podem ser estornadas separadamente.'; END IF;
   UPDATE public.bar_pagamentos SET estornado=true,estornado_em=now(),estornado_por=auth.uid(),estorno_motivo=btrim(p_motivo) WHERE id=pa.id AND empresa_id=e;
   -- Trigger de taxas existente preservado. Nenhuma chamada a Pix/adquirente, nem estoque.
   PERFORM private.bar_reabertura_sincronizar(c.id,e);
  ELSIF p_acao='fechar' THEN
   PERFORM private.bar_historico_exigir('bar_caixa');
   SELECT * INTO s FROM private.bar_comanda_saldo_calcular(c.id,e);
   IF abs(s.saldo)>0.01 THEN RAISE EXCEPTION 'Quite o saldo ou estorne o excedente antes de fechar.'; END IF;
   PERFORM public.bar_mesa_fechar(m.id);
  END IF;
 END IF;
 SELECT * INTO r FROM private.bar_reaberturas WHERE empresa_id=e AND comanda_id=c.id;
 resposta:=jsonb_build_object('ok',true,'venda_id',v.id,'comanda_id',c.id,'mesa_id',m.id,'versao',r.versao,'ativa',r.ativa);
 INSERT INTO public.florest_auditoria_operacoes(id,empresa_id,solicitante_id,autorizador_id,operacao,alvo_id,motivo,antes,depois,resultado)
 VALUES(p_idempotencia,e,auth.uid(),auth.uid(),'bar_mesa_reedicao',c.id,p_motivo,anterior,jsonb_build_object('pedido',pedido,'resposta',resposta,'estado',private.bar_reabertura_snapshot(c.id,e)),'sucesso');
 INSERT INTO public.bar_eventos(empresa_id,tipo,mesa_id,comanda_id,referencia_id,detalhes,criado_por)
 VALUES(e,'mesa_reedicao',m.id,c.id,p_idempotencia,jsonb_build_object('acao',p_acao,'motivo',p_motivo),auth.uid());
 RETURN resposta;
END $$;
REVOKE ALL ON FUNCTION public.bar_historico_mesa_editar(uuid,text,jsonb,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bar_historico_mesa_editar(uuid,text,jsonb,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.bar_pedido_enviar(p_comanda_id uuid, p_itens jsonb, p_idempotencia uuid)
 RETURNS TABLE(pedido_id uuid, itens_criados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa     uuid := private.exigir_empresa_ativa();
  v_comanda     public.bar_comandas%rowtype;
  v_sem_estoque boolean;
  v_existente   uuid;
  v_pedido      uuid;
  v_item_id     uuid;
  v_invalido    boolean;
  v_qtd_itens   integer := 0;
  r             record;
  v_nome        text;
  v_estoque     numeric;
begin
 PERFORM private.bar_reabertura_guardar(p_comanda_id,v_empresa);
  if not private.empresa_tem_modulo('bar') then
    raise exception 'Este recurso exige o módulo Bar ativo para esta empresa.' using errcode = '42501';
  end if;
  if not private.perm('bar_pedidos') then
    raise exception 'Você não tem permissão para lançar pedidos no bar.' using errcode = '42501';
  end if;
  if p_idempotencia is null then
    raise exception 'Falha interna: identificador de envio (idempotência) é obrigatório.';
  end if;

  -- Reenvio idempotente (duplo clique / retry de rede): devolve o pedido já criado, sem tocar em
  -- estoque de novo — trava de BANCO (UNIQUE empresa_id,idempotencia_key), igual à Migration 016.
  select id into v_existente from public.bar_pedidos
   where empresa_id = v_empresa and idempotencia_key = p_idempotencia;
  if v_existente is not null then
    pedido_id := v_existente;
    select count(*) into v_qtd_itens from public.bar_pedidos_itens bpi where bpi.pedido_id = v_existente;
    itens_criados := v_qtd_itens;
    return next;
    return;
  end if;

  select * into v_comanda from public.bar_comandas
   where id = p_comanda_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Comanda não encontrada.';
  end if;
  if v_comanda.status <> 'aberta' then
    raise exception 'Esta comanda não está aberta para receber pedidos.';
  end if;

 PERFORM private.bar_reabertura_guardar(p_comanda_id,v_empresa);
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'O pedido precisa ter pelo menos um item.';
  end if;
  if jsonb_array_length(p_itens) > 200 then
    raise exception 'Itens demais em um único pedido (máximo 200).';
  end if;

  begin
    select exists (
      select 1 from jsonb_to_recordset(p_itens) as x(bar_produto_id uuid, quantidade numeric, observacao text, escolhas jsonb)
       where x.bar_produto_id is null or x.quantidade is null or x.quantidade <= 0
    ) into v_invalido;
  exception when others then
    v_invalido := true;
  end;
  if v_invalido then
    raise exception 'Item do pedido inválido (produto do cardápio e quantidade maior que zero são obrigatórios).';
  end if;

  select coalesce((select c.permitir_venda_sem_estoque from public.configuracoes_empresa c where c.empresa_id = v_empresa), false)
    into v_sem_estoque;

  -- Itens recebidos, na ordem enviada, já com o "instantâneo" do cardápio (preço/destino/produto
  -- núcleo) — e marcados se usam o modelo NOVO de grupos (usa_grupos = tem ao menos 1 grupo
  -- cadastrado para aquele bar_produto). Um composto sem nenhum grupo cadastrado continua sendo o
  -- modelo antigo (componentes), tratado exatamente como na Migration 016.
  create temporary table _bar_itens_pedido on commit drop as
  select x.ordem, x.bar_produto_id, round(x.quantidade, 4) as quantidade,
         nullif(btrim(coalesce(x.observacao, '')), '') as observacao, x.escolhas,
         bp.produto_id, bp.tipo, bp.destino_operacional, bp.ativo_cardapio,
         p.preco_venda, p.nome as produto_nome,
         exists (select 1 from public.bar_produto_grupos g where g.bar_produto_id = bp.id and g.empresa_id = v_empresa) as usa_grupos
    from rows from (jsonb_to_recordset(p_itens) as (bar_produto_id uuid, quantidade numeric, observacao text, escolhas jsonb))
         with ordinality as x(bar_produto_id, quantidade, observacao, escolhas, ordem)
    left join public.bar_produtos bp on bp.id = x.bar_produto_id and bp.empresa_id = v_empresa
    left join public.produtos p on p.id = bp.produto_id and p.empresa_id = v_empresa;

  if exists (select 1 from _bar_itens_pedido where produto_id is null) then
    raise exception 'Um ou mais itens do pedido não correspondem a produtos do cardápio do bar desta empresa.';
  end if;
  perform private.produtos_exigir_ativos(v_empresa, (select array_agg(ip.produto_id) from _bar_itens_pedido ip));   -- [046:bar_enviar_item]
  if exists (select 1 from _bar_itens_pedido where ativo_cardapio = false) then
    raise exception 'Um ou mais itens do pedido estão desativados no cardápio do bar.';
  end if;

  -- Valida e resolve as ESCOLHAS de cada item composto do modelo novo (requisitos #4/#5/#6):
  -- confere que a quantidade de escolhas bate com o configurado por grupo, que cada produto
  -- escolhido é opção válida daquele grupo, e BLOQUEIA o pedido inteiro se qualquer produto físico
  -- escolhido ainda estiver com destino "Não definido" (nunca lança "escondido" no destino errado).
  create temporary table _bar_escolhas_por_item (
    ordem integer, grupo_id uuid, grupo_nome text, produto_id uuid, produto_nome text,
    destino_operacional text, quantidade numeric(12,4)
  ) on commit drop;

  for r in select * from _bar_itens_pedido where tipo = 'composto' and usa_grupos loop
    if r.escolhas is null or jsonb_typeof(r.escolhas) <> 'array' or jsonb_array_length(r.escolhas) = 0 then
      raise exception 'O item "%" é um produto composto e precisa das escolhas obrigatórias (ex.: qual espeto, qual refrigerante).', r.produto_nome;
    end if;

    if exists (
      select 1
        from public.bar_produto_grupos g
       where g.bar_produto_id = r.bar_produto_id and g.empresa_id = v_empresa
         and g.quantidade_escolhas <> (
               select count(*) from jsonb_to_recordset(r.escolhas) as e(grupo_id uuid, produto_id uuid)
                where e.grupo_id = g.id
             )
    ) then
      raise exception 'O item "%" não tem a quantidade correta de escolhas em um ou mais grupos (grupos: %).', r.produto_nome,
        (select string_agg(g2.nome, ', ') from public.bar_produto_grupos g2 where g2.bar_produto_id = r.bar_produto_id and g2.empresa_id = v_empresa);
    end if;

    if exists (
      select 1 from jsonb_to_recordset(r.escolhas) as e(grupo_id uuid, produto_id uuid)
       where not exists (
               select 1 from public.bar_produto_grupos g where g.id = e.grupo_id and g.bar_produto_id = r.bar_produto_id and g.empresa_id = v_empresa
             )
          or not exists (
               select 1 from public.bar_produto_grupo_opcoes o
                where o.grupo_id = e.grupo_id and o.produto_id = e.produto_id and o.empresa_id = v_empresa
             )
    ) then
      raise exception 'O item "%" tem uma escolha inválida (grupo ou produto não configurado para este item).', r.produto_nome;
    end if;

    if exists (
      select 1
        from jsonb_to_recordset(r.escolhas) as e(grupo_id uuid, produto_id uuid)
        join public.bar_produtos bpe on bpe.produto_id = e.produto_id and bpe.empresa_id = v_empresa
       where bpe.destino_operacional = 'sem_destino'
    ) then
      raise exception 'O item "%" tem uma escolha cujo produto físico ainda está com destino "Não definido". Configure o destino (Bar ou Cozinha) desse produto em Destino dos Produtos antes de lançar o pedido.', r.produto_nome;
    end if;

    insert into _bar_escolhas_por_item (ordem, grupo_id, grupo_nome, produto_id, produto_nome, destino_operacional, quantidade)
    select r.ordem, e.grupo_id, g.nome, e.produto_id, pr.nome, bpe.destino_operacional,
           (r.quantidade * count(*))::numeric(12,4) as quantidade
      from jsonb_to_recordset(r.escolhas) as e(grupo_id uuid, produto_id uuid)
      join public.bar_produto_grupos g on g.id = e.grupo_id and g.empresa_id = v_empresa
      join public.produtos pr on pr.id = e.produto_id and pr.empresa_id = v_empresa
      join public.bar_produtos bpe on bpe.produto_id = e.produto_id and bpe.empresa_id = v_empresa
     group by r.ordem, e.grupo_id, e.produto_id, g.nome, pr.nome, bpe.destino_operacional;
  end loop;

  -- Baixa de estoque POR ITEM: simples (o próprio produto); composto modelo ANTIGO (componentes
  -- marcados baixar_estoque, idêntico à Migration 016); composto modelo NOVO (exatamente os
  -- produtos físicos escolhidos, já resolvidos acima em _bar_escolhas_por_item).
  create temporary table _bar_baixas_por_item on commit drop as
  select ip.ordem, ip.produto_id as produto_baixa_id, ip.quantidade as quantidade
    from _bar_itens_pedido ip
   where ip.tipo = 'simples'
  union all
  select ip.ordem, c.componente_produto_id as produto_baixa_id, (ip.quantidade * c.quantidade)::numeric as quantidade
    from _bar_itens_pedido ip
    join public.bar_produtos_componentes c on c.bar_produto_id = ip.bar_produto_id and c.empresa_id = v_empresa
   where ip.tipo = 'composto' and ip.usa_grupos = false and c.baixar_estoque = true
  union all
  select e.ordem, e.produto_id as produto_baixa_id, e.quantidade
    from _bar_escolhas_por_item e;

  -- Trava e baixa o estoque núcleo, um produto por vez, em ordem fixa (evita deadlock), pelo TOTAL
  -- agregado deste pedido — mesmo padrão de public.registrar_venda e da Migration 016.
  for r in
    select produto_baixa_id as produto_id, sum(quantidade) as qtd
      from _bar_baixas_por_item
     group by produto_baixa_id
     order by produto_baixa_id
  loop
    select p.nome, p.quantidade_estoque into v_nome, v_estoque
      from public.produtos p
     where p.id = r.produto_id and p.empresa_id = v_empresa
       for update;
    if not found then
      raise exception 'Produto do núcleo não encontrado para baixa de estoque.';
    end if;
    perform private.produto_exigir_ativo(v_empresa, r.produto_id);   -- [046:bar_enviar_baixa]
    if v_estoque < r.qtd and not v_sem_estoque then
      raise exception 'Estoque insuficiente para "%": disponível %, necessário %.', v_nome, v_estoque, r.qtd;
    end if;
    update public.produtos set quantidade_estoque = quantidade_estoque - r.qtd
     where id = r.produto_id and empresa_id = v_empresa;
  end loop;

  insert into public.bar_pedidos (empresa_id, comanda_id, mesa_id, idempotencia_key, criado_por)
  values (v_empresa, p_comanda_id, v_comanda.mesa_id, p_idempotencia, auth.uid())
  returning id into v_pedido;

  -- Insere cada item e, na sequência, sua baixa detalhada (para estorno exato depois) e, quando é
  -- um composto do modelo novo, o snapshot das escolhas (para o Bar/Cozinha e o Relatório B). O
  -- item comercial de um composto do modelo novo é gravado com destino_operacional='sem_destino'
  -- (ele mesmo nunca é roteado ao Bar/Cozinha — quem é roteado são as escolhas, uma por destino).
  for r in select * from _bar_itens_pedido order by ordem loop
    insert into public.bar_pedidos_itens
      (empresa_id, pedido_id, comanda_id, bar_produto_id, produto_id, quantidade, preco_unitario, destino_operacional, observacao)
    values
      (v_empresa, v_pedido, p_comanda_id, r.bar_produto_id, r.produto_id, r.quantidade,
       round(r.preco_venda, 2),
       case when r.tipo = 'composto' and r.usa_grupos then 'sem_destino' else r.destino_operacional end,
       r.observacao)
    returning id into v_item_id;

    insert into public.bar_pedidos_itens_baixas (empresa_id, pedido_item_id, produto_id, quantidade)
    select v_empresa, v_item_id, b.produto_baixa_id, b.quantidade
      from _bar_baixas_por_item b
     where b.ordem = r.ordem;

    if r.tipo = 'composto' and r.usa_grupos then
      insert into public.bar_pedidos_itens_escolhas
        (empresa_id, pedido_item_id, grupo_id, grupo_nome, produto_id, produto_nome, destino_operacional, quantidade)
      select v_empresa, v_item_id, e.grupo_id, e.grupo_nome, e.produto_id, e.produto_nome, e.destino_operacional, e.quantidade
        from _bar_escolhas_por_item e
       where e.ordem = r.ordem;
    end if;

    v_qtd_itens := v_qtd_itens + 1;
  end loop;

  insert into public.bar_eventos (empresa_id, tipo, mesa_id, comanda_id, referencia_id, detalhes, criado_por)
  values (v_empresa, 'pedido_enviado', v_comanda.mesa_id, p_comanda_id, v_pedido, jsonb_build_object('itens', v_qtd_itens), auth.uid());

  IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=p_comanda_id AND rr.ativa) THEN PERFORM private.bar_reabertura_sincronizar(p_comanda_id,v_empresa); END IF;
  pedido_id := v_pedido;
  itens_criados := v_qtd_itens;
  return next;
end;
$function$;
CREATE OR REPLACE FUNCTION public.bar_comanda_pagar_valor(p_comanda_id uuid, p_valor numeric, p_formas jsonb, p_idempotencia uuid, p_desconto numeric DEFAULT NULL::numeric, p_acrescimo numeric DEFAULT NULL::numeric, p_taxa_servico numeric DEFAULT NULL::numeric)
 RETURNS TABLE(comanda_id uuid, pagamento_id uuid, valor_recebido numeric, saldo_restante numeric, mesa_liberada boolean, venda_id uuid, numero_venda integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_taxa_forma jsonb; v_taxa_id uuid;
  v_empresa     uuid := private.exigir_empresa_ativa();
  v_comanda     public.bar_comandas%rowtype;
  v_mesa        public.bar_mesas%rowtype;
  v_existente   public.bar_pagamentos%rowtype;
  v_soma_formas numeric;
  v_invalido    boolean;
  v_pagamento   uuid;
  v_saldo_antes  record;
  v_saldo_depois record;
  v_venda       uuid;
  v_numero      integer;
  v_fechou      boolean := false;
  v_caixa       uuid;
begin
 PERFORM private.bar_reabertura_guardar(p_comanda_id,v_empresa);
  if not private.empresa_tem_modulo('bar') then
    raise exception 'Este recurso exige o módulo Bar ativo para esta empresa.' using errcode = '42501';
  end if;
  if not private.perm('bar_caixa') then
    raise exception 'Você não tem permissão para registrar pagamentos no bar.' using errcode = '42501';
  end if;

  if p_idempotencia is null then
    raise exception 'p_idempotencia é obrigatório.';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'Informe um valor a receber maior que zero.';
  end if;
  if p_formas is null or jsonb_typeof(p_formas) <> 'array' or jsonb_array_length(p_formas) = 0 then
    raise exception 'Informe ao menos uma forma de pagamento.';
  end if;
  if jsonb_array_length(p_formas) > 10 then
    raise exception 'Formas de pagamento demais em um único recebimento (máximo 10).';
  end if;
  if p_desconto is not null and p_desconto < 0 then
    raise exception 'Desconto não pode ser negativo.';
  end if;
  if p_acrescimo is not null and p_acrescimo < 0 then
    raise exception 'Acréscimo não pode ser negativo.';
  end if;
  if p_taxa_servico is not null and p_taxa_servico < 0 then
    raise exception 'Taxa de serviço não pode ser negativa.';
  end if;

  begin
    select exists (
      select 1 from jsonb_to_recordset(p_formas) as x(forma_pagamento text, valor numeric)
       where x.forma_pagamento is null or btrim(x.forma_pagamento) = '' or x.valor is null or x.valor <= 0
    ) into v_invalido;
  exception when others then
    v_invalido := true;
  end;
  if v_invalido then
    raise exception 'Forma de pagamento inválida (nome e valor maior que zero são obrigatórios).';
  end if;

  select coalesce(sum(x.valor), 0) into v_soma_formas
    from jsonb_to_recordset(p_formas) as x(forma_pagamento text, valor numeric);
  if abs(v_soma_formas - p_valor) > 0.01 then
    raise exception 'A soma das formas de pagamento (%) não confere com o valor a receber (%).', v_soma_formas, p_valor;
  end if;

  select * into v_comanda from public.bar_comandas
   where id = p_comanda_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Comanda não encontrada.';
  end if;

  select * into v_mesa from public.bar_mesas
   where id = v_comanda.mesa_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Mesa não encontrada.';
  end if;

  -- Idempotência: duplo clique / reenvio de rede com a MESMA chave nunca registra de novo — só
  -- devolve o resultado já efetivado da primeira chamada.
  select * into v_existente from public.bar_pagamentos
   where empresa_id = v_empresa and idempotencia_key = p_idempotencia;
  if found then
    IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=p_comanda_id AND rr.ativa) AND (v_existente.comanda_id IS DISTINCT FROM p_comanda_id OR v_existente.total IS DISTINCT FROM p_valor OR (SELECT jsonb_agg(jsonb_build_object('forma_pagamento',f.forma_pagamento,'valor',f.valor) ORDER BY f.forma_pagamento,f.valor) FROM public.bar_pagamentos_formas f WHERE f.pagamento_id=v_existente.id AND f.empresa_id=v_empresa) IS DISTINCT FROM (SELECT jsonb_agg(jsonb_build_object('forma_pagamento',x.forma_pagamento,'valor',x.valor) ORDER BY x.forma_pagamento,x.valor) FROM jsonb_to_recordset(p_formas) AS x(forma_pagamento text,valor numeric))) THEN RAISE EXCEPTION 'Chave de pagamento reutilizada com outro conteúdo.'; END IF;
    select * into v_saldo_depois from private.bar_comanda_saldo_calcular(p_comanda_id, v_empresa);
    comanda_id := p_comanda_id;
    pagamento_id := v_existente.id;
    valor_recebido := v_existente.total;
    saldo_restante := greatest(v_saldo_depois.saldo, 0);
    mesa_liberada := (v_comanda.status = 'fechada') or (v_mesa.status = 'livre');
    venda_id := v_existente.venda_id;
    if v_existente.venda_id is not null then
      select vd.numero_venda into numero_venda from public.vendas vd
       where vd.id = v_existente.venda_id and vd.empresa_id = v_empresa;
    end if;
    return next;
    return;
  end if;

  -- Migration 032: RECEBER pagamento exige Caixa BAR aberto (lançar/enviar pedido NÃO exige). Fica depois do
  -- replay idempotente acima: repetir um pagamento já registrado nunca falha por caixa fechado depois.
  v_caixa := private.caixa_exigir_aberto('BAR');

  if v_comanda.status <> 'aberta' then
    raise exception 'Esta comanda não está aberta.';
  end if;

 PERFORM private.bar_reabertura_guardar(p_comanda_id,v_empresa);
  -- Ajustes de nível de comanda: SUBSTITUEM (nunca somam) o que já estava persistido. Quando o
  -- parâmetro vem nulo, o valor já salvo é mantido sem alteração — um pagamento parcial seguinte
  -- nunca reaplica o desconto/taxa de novo.
  if p_desconto is not null or p_acrescimo is not null or p_taxa_servico is not null then
    update public.bar_comandas
       set desconto = coalesce(p_desconto, desconto),
           acrescimo = coalesce(p_acrescimo, acrescimo),
           taxa_servico = coalesce(p_taxa_servico, taxa_servico),
           atualizado_em = now()
     where id = v_comanda.id and empresa_id = v_empresa;

    select * into v_comanda from public.bar_comandas
     where id = p_comanda_id and empresa_id = v_empresa;
  end if;

  select * into v_saldo_antes from private.bar_comanda_saldo_calcular(p_comanda_id, v_empresa);

  if v_saldo_antes.saldo <= 0 then
    raise exception 'Esta comanda não tem saldo em aberto para pagamento.';
  end if;
  if p_valor > v_saldo_antes.saldo + 0.01 then
    raise exception 'O valor informado (R$ %) excede o saldo em aberto desta comanda (R$ %).', round(p_valor, 2), v_saldo_antes.saldo;
  end if;

  insert into public.bar_pagamentos
    (empresa_id, comanda_id, venda_id, subtotal, desconto, acrescimo, taxa_servico, total, pessoas_liberadas, idempotencia_key, criado_por, caixa_id)
  values
    (v_empresa, p_comanda_id, null, p_valor, 0, 0, 0, p_valor, 0, p_idempotencia, auth.uid(), v_caixa)
  returning id into v_pagamento;

  for v_taxa_forma in select value from jsonb_array_elements(p_formas) loop
    insert into public.bar_pagamentos_formas(empresa_id,pagamento_id,forma_pagamento,valor) values(v_empresa,v_pagamento,btrim(v_taxa_forma->>'forma_pagamento'),round((v_taxa_forma->>'valor')::numeric,2)) returning id into v_taxa_id;
    perform private.taxas_registrar('bar',v_taxa_id,v_taxa_forma);
  end loop;

  insert into public.bar_eventos (empresa_id, tipo, mesa_id, comanda_id, referencia_id, detalhes, criado_por)
  values (v_empresa, 'pagamento_registrado', v_mesa.id, p_comanda_id, v_pagamento,
          jsonb_build_object('total', p_valor, 'modelo', 'valor_monetario'), auth.uid());

  IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=p_comanda_id AND rr.ativa) THEN PERFORM private.bar_reabertura_sincronizar(p_comanda_id,v_empresa); END IF;
  select * into v_saldo_depois from private.bar_comanda_saldo_calcular(p_comanda_id, v_empresa);

  if v_saldo_depois.saldo <= 0.01 then
    v_venda := private.bar_comanda_finalizar_venda(p_comanda_id, v_empresa);
    perform public.bar_mesa_fechar(v_mesa.id);
    v_fechou := true;
    select vd.numero_venda into v_numero from public.vendas vd where vd.id = v_venda and vd.empresa_id = v_empresa;
  else
    v_venda := v_comanda.venda_id;
    if v_venda is not null then
      select vd.numero_venda into v_numero from public.vendas vd where vd.id = v_venda and vd.empresa_id = v_empresa;
    end if;
  end if;

  comanda_id := p_comanda_id;
  pagamento_id := v_pagamento;
  valor_recebido := p_valor;
  saldo_restante := greatest(v_saldo_depois.saldo, 0);
  mesa_liberada := v_fechou;
  venda_id := v_venda;
  numero_venda := v_numero;
  return next;
end;
$function$;
CREATE OR REPLACE FUNCTION private.bar_comanda_finalizar_venda(p_comanda_id uuid, p_empresa uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_comanda    public.bar_comandas%rowtype;
  v_venda      uuid;
  v_numero     integer;
  v_item       record;
  v_item_venda bigint;
  v_saldo      record;
begin
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas WHERE empresa_id=p_empresa AND comanda_id=p_comanda_id AND ativa) THEN
 PERFORM private.bar_reabertura_guardar(p_comanda_id,p_empresa); RETURN private.bar_reabertura_sincronizar(p_comanda_id,p_empresa); END IF;
  select * into v_comanda from public.bar_comandas
   where id = p_comanda_id and empresa_id = p_empresa
     for update;
  if not found then
    raise exception 'Comanda não encontrada.';
  end if;

  -- REVISÃO 3 (016) preservada: pega-ou-cria a ÚNICA venda desta comanda.
  if v_comanda.venda_id is null then
    insert into public.contadores_venda as c (empresa_id, ultimo_numero)
    values (p_empresa, 1)
    on conflict (empresa_id) do update set ultimo_numero = c.ultimo_numero + 1
    returning c.ultimo_numero into v_numero;

    insert into public.vendas (empresa_id, numero_venda, cliente_id, forma_pagamento, total, tipo, criado_por)
    values (p_empresa, v_numero, null, 'dividido', 0, 'bar', auth.uid())
    returning id into v_venda;

    update public.bar_comandas set venda_id = v_venda where id = v_comanda.id and empresa_id = p_empresa;
  else
    v_venda := v_comanda.venda_id;
  end if;

  -- Faturamento (snapshot em itens_venda) de todo item não estornado ainda sem item_venda_id —
  -- nunca duplica um item já faturado por um pagamento estilo antigo anterior, ou por uma
  -- finalização anterior desta mesma comanda (reabertura por estorno seguida de nova quitação).
  for v_item in
    select bpi.id, bpi.produto_id, bpi.quantidade, bpi.preco_unitario
      from public.bar_pedidos_itens bpi
     where bpi.comanda_id = p_comanda_id and bpi.empresa_id = p_empresa
       and bpi.estornado = false and bpi.item_venda_id is null
     order by bpi.id
  loop
    insert into public.itens_venda (empresa_id, venda_id, produto_id, quantidade, preco_unitario)
    values (p_empresa, v_venda, v_item.produto_id, v_item.quantidade, v_item.preco_unitario)
    returning id into v_item_venda;

    update public.bar_pedidos_itens set item_venda_id = v_item_venda
     where id = v_item.id and empresa_id = p_empresa;
  end loop;

  -- Religa à venda todo pagamento desta comanda que ainda estivesse sem venda_id (pagamentos
  -- estilo novo, inclusive os já estornados antes desta quitação — mantém o histórico completo).
  update public.bar_pagamentos set venda_id = v_venda
   where comanda_id = p_comanda_id and empresa_id = p_empresa and venda_id is null;

  -- vendas.total = TOTAL FINAL da comanda no instante da quitação — igual, por construção
  -- (saldo = 0), ao total efetivamente pago, mesmo com pagamentos estilo antigo e novo
  -- misturados na mesma comanda.
  select * into v_saldo from private.bar_comanda_saldo_calcular(p_comanda_id, p_empresa);
  update public.vendas set total = v_saldo.total_final where id = v_venda and empresa_id = p_empresa;

  perform private.bar_venda_recalcular_forma_pagamento(v_venda, p_empresa);

  return v_venda;
end;
$function$;
CREATE OR REPLACE FUNCTION public.bar_mesa_fechar(p_mesa_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa uuid := private.exigir_empresa_ativa();
  v_mesa    public.bar_mesas%rowtype;
  v_comanda public.bar_comandas%rowtype;
  v_saldo   record;
begin
 PERFORM private.bar_reabertura_guardar((SELECT comanda_atual_id FROM public.bar_mesas WHERE id=p_mesa_id AND empresa_id=v_empresa),v_empresa);
  if not private.empresa_tem_modulo('bar') then
    raise exception 'Este recurso exige o módulo Bar ativo para esta empresa.' using errcode = '42501';
  end if;
  if not private.perm_alguma(array['bar_mesas', 'bar_caixa']::text[]) then
    raise exception 'Você não tem permissão para fechar mesas do bar.' using errcode = '42501';
  end if;

  select * into v_mesa from public.bar_mesas
   where id = p_mesa_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Mesa não encontrada.';
  end if;
  if v_mesa.status <> 'ocupada' or v_mesa.comanda_atual_id is null then
    raise exception 'Esta mesa não está ocupada.';
  end if;

  select * into v_comanda from public.bar_comandas
   where id = v_mesa.comanda_atual_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Comanda da mesa não encontrada.';
  end if;

  IF private.bar_reabertura_guardar(v_comanda.id,v_empresa) THEN PERFORM private.bar_historico_exigir('bar_caixa'); END IF;
  select * into v_saldo from private.bar_comanda_saldo_calcular(v_comanda.id, v_empresa);
  if v_saldo.saldo > 0.01 then
    raise exception 'Existem itens ou saldo não pagos nesta comanda (saldo em aberto: R$ %). Registre o pagamento antes de fechar a mesa.', v_saldo.saldo;
  end if;

  -- Pagamento normal já finaliza a venda antes de chamar este fechamento.
  -- Sem consumo válido, liberar uma mesa vazia não deve fabricar uma venda de valor zero.
  if v_comanda.venda_id is null and exists (
    select 1 from public.bar_pedidos_itens i
     where i.comanda_id = v_comanda.id and i.empresa_id = v_empresa and not i.estornado
  ) then
    perform private.bar_comanda_finalizar_venda(v_comanda.id,v_empresa);
  end if;
  if v_mesa.pessoas_atual <> 0 then
    insert into public.bar_movimentos_pessoas (empresa_id, mesa_id, comanda_id, tipo, quantidade, motivo, criado_por)
    values (v_empresa, p_mesa_id, v_comanda.id, 'saida_liberacao', -v_mesa.pessoas_atual,
            'Liberação automática no fechamento simplificado (Migration 018).', auth.uid());
  end if;

  IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=v_comanda.id AND rr.ativa) THEN PERFORM private.bar_reabertura_sincronizar(v_comanda.id,v_empresa); END IF;
  update public.bar_comandas set status = 'fechada', fechada_em = now()
   where id = v_comanda.id and empresa_id = v_empresa;

  update public.bar_mesas
     set status = 'livre', comanda_atual_id = null, aberta_em = null, pessoas_atual = 0
   where id = p_mesa_id and empresa_id = v_empresa;

  UPDATE private.bar_reaberturas SET ativa=false WHERE empresa_id=v_empresa AND comanda_id=v_comanda.id AND ativa;
  insert into public.bar_eventos (empresa_id, tipo, mesa_id, comanda_id, criado_por)
  values (v_empresa, 'mesa_fechada', p_mesa_id, v_comanda.id, auth.uid());
end;
$function$;
CREATE OR REPLACE FUNCTION public.bar_comanda_pagar(p_comanda_id uuid, p_item_ids uuid[], p_formas jsonb, p_desconto numeric DEFAULT 0, p_acrescimo numeric DEFAULT 0, p_taxa_servico numeric DEFAULT 0, p_pessoas_liberadas integer DEFAULT 0)
 RETURNS TABLE(venda_id uuid, numero_venda integer, pagamento_id uuid, total numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_taxa_forma jsonb; v_taxa_id uuid;
  v_empresa     uuid := private.exigir_empresa_ativa();
  v_comanda     public.bar_comandas%rowtype;
  v_mesa        public.bar_mesas%rowtype;
  v_subtotal    numeric;
  v_total       numeric;
  v_soma_formas numeric;
  v_invalido    boolean;
  v_venda       uuid;
  v_numero      integer;
  v_pagamento   uuid;
  v_item        record;
  v_item_venda  bigint;
  v_saldo       record;
  v_caixa       uuid;
begin
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=p_comanda_id AND rr.ativa) THEN RAISE EXCEPTION 'Conta reaberta: utilize recebimentos monetários no caixa original, sem conversão em nota a prazo ou pagamento por itens.'; END IF;
  if not private.empresa_tem_modulo('bar') then
    raise exception 'Este recurso exige o módulo Bar ativo para esta empresa.' using errcode = '42501';
  end if;
  if not private.perm('bar_caixa') then
    raise exception 'Você não tem permissão para registrar pagamentos no bar.' using errcode = '42501';
  end if;

  -- Migration 032: RECEBER pagamento exige Caixa BAR aberto.
  v_caixa := private.caixa_exigir_aberto('BAR');

  if p_desconto is null or p_desconto < 0 or p_acrescimo is null or p_acrescimo < 0
     or p_taxa_servico is null or p_taxa_servico < 0 then
    raise exception 'Desconto, acréscimo e taxa de serviço não podem ser negativos.';
  end if;
  if p_pessoas_liberadas is null or p_pessoas_liberadas < 0 then
    raise exception 'Quantidade de pessoas liberadas inválida.';
  end if;
  if p_formas is null or jsonb_typeof(p_formas) <> 'array' or jsonb_array_length(p_formas) = 0 then
    raise exception 'Informe ao menos uma forma de pagamento.';
  end if;
  if jsonb_array_length(p_formas) > 10 then
    raise exception 'Formas de pagamento demais em um único fechamento (máximo 10).';
  end if;

  begin
    select exists (
      select 1 from jsonb_to_recordset(p_formas) as x(forma_pagamento text, valor numeric)
       where x.forma_pagamento is null or btrim(x.forma_pagamento) = '' or x.valor is null or x.valor <= 0
    ) into v_invalido;
  exception when others then
    v_invalido := true;
  end;
  if v_invalido then
    raise exception 'Forma de pagamento inválida (nome e valor maior que zero são obrigatórios).';
  end if;

  select * into v_comanda from public.bar_comandas
   where id = p_comanda_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Comanda não encontrada.';
  end if;
  if v_comanda.status <> 'aberta' then
    raise exception 'Esta comanda não está aberta.';
  end if;

  select * into v_mesa from public.bar_mesas
   where id = v_comanda.mesa_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Mesa não encontrada.';
  end if;
  if p_pessoas_liberadas > v_mesa.pessoas_atual then
    raise exception 'Não é possível liberar % pessoa(s): a mesa tem apenas % no momento.', p_pessoas_liberadas, v_mesa.pessoas_atual;
  end if;

 IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=p_comanda_id AND rr.ativa) THEN RAISE EXCEPTION 'Conta reaberta: pagamento por itens não permitido.'; END IF;
  -- Itens em aberto (não estornados, ainda não pagos) desta comanda — FOR UPDATE trava contra o
  -- mesmo item entrar em dois fechamentos simultâneos (divisão de conta concorrente).
  create temporary table _bar_itens_pagar on commit drop as
  select bpi.id, bpi.quantidade, bpi.preco_unitario, bpi.produto_id
    from public.bar_pedidos_itens bpi
   where bpi.comanda_id = p_comanda_id
     and bpi.empresa_id = v_empresa
     and bpi.estornado = false
     and bpi.pagamento_id is null
     and (p_item_ids is null or bpi.id = any (p_item_ids))
   order by bpi.id
     for update of bpi;

  if not exists (select 1 from _bar_itens_pagar) then
    raise exception 'Não há itens em aberto para pagamento nesta comanda.';
  end if;
  if p_item_ids is not null and (select count(*) from _bar_itens_pagar) <> array_length(p_item_ids, 1) then
    raise exception 'Um ou mais itens informados não estão disponíveis para pagamento (já pagos, cancelados ou de outra comanda).';
  end if;

  select coalesce(sum(quantidade * preco_unitario), 0) into v_subtotal from _bar_itens_pagar;
  v_total := round(v_subtotal - p_desconto + p_acrescimo + p_taxa_servico, 2);
  if v_total < 0 then
    raise exception 'O total do pagamento não pode ficar negativo (confira desconto/acréscimo).';
  end if;

  select coalesce(sum(x.valor), 0) into v_soma_formas
    from jsonb_to_recordset(p_formas) as x(forma_pagamento text, valor numeric);
  if abs(v_soma_formas - v_total) > 0.01 then
    raise exception 'A soma das formas de pagamento (%) não confere com o total a pagar (%).', v_soma_formas, v_total;
  end if;

  -- REVISÃO 3 — pega-ou-cria a venda central da comanda (1 comanda = 1 venda = N pagamentos).
  if v_comanda.venda_id is null then
    insert into public.contadores_venda as c (empresa_id, ultimo_numero)
    values (v_empresa, 1)
    on conflict (empresa_id) do update set ultimo_numero = c.ultimo_numero + 1
    returning c.ultimo_numero into v_numero;

    insert into public.vendas (empresa_id, numero_venda, cliente_id, forma_pagamento, total, tipo, criado_por)
    values (v_empresa, v_numero, null, 'dividido', 0, 'bar', auth.uid())
    returning id into v_venda;

    update public.bar_comandas set venda_id = v_venda
     where id = v_comanda.id and empresa_id = v_empresa;
    v_comanda.venda_id := v_venda;
  else
    v_venda := v_comanda.venda_id;
    select vd.numero_venda into v_numero from public.vendas vd where vd.id = v_venda and vd.empresa_id = v_empresa;
  end if;

  insert into public.bar_pagamentos
    (empresa_id, comanda_id, venda_id, subtotal, desconto, acrescimo, taxa_servico, total, pessoas_liberadas, criado_por, caixa_id)
  values
    (v_empresa, p_comanda_id, v_venda, v_subtotal, p_desconto, p_acrescimo, p_taxa_servico, v_total, p_pessoas_liberadas, auth.uid(), v_caixa)
  returning id into v_pagamento;

  for v_taxa_forma in select value from jsonb_array_elements(p_formas) loop
    insert into public.bar_pagamentos_formas(empresa_id,pagamento_id,forma_pagamento,valor) values(v_empresa,v_pagamento,btrim(v_taxa_forma->>'forma_pagamento'),round((v_taxa_forma->>'valor')::numeric,2)) returning id into v_taxa_id;
    perform private.taxas_registrar('bar',v_taxa_id,v_taxa_forma);
  end loop;

  for v_item in select id, produto_id, quantidade, preco_unitario from _bar_itens_pagar order by id loop
    insert into public.itens_venda (empresa_id, venda_id, produto_id, quantidade, preco_unitario)
    values (v_empresa, v_venda, v_item.produto_id, v_item.quantidade, v_item.preco_unitario)
    returning id into v_item_venda;

    update public.bar_pedidos_itens
       set pagamento_id = v_pagamento, item_venda_id = v_item_venda
     where id = v_item.id and empresa_id = v_empresa;
  end loop;

  update public.vendas vd set total = vd.total + v_total
   where vd.id = v_venda and vd.empresa_id = v_empresa;

  perform private.bar_venda_recalcular_forma_pagamento(v_venda, v_empresa);

  if p_pessoas_liberadas > 0 then
    update public.bar_mesas set pessoas_atual = pessoas_atual - p_pessoas_liberadas
     where id = v_mesa.id and empresa_id = v_empresa;
    insert into public.bar_movimentos_pessoas (empresa_id, mesa_id, comanda_id, pagamento_id, tipo, quantidade, criado_por)
    values (v_empresa, v_mesa.id, p_comanda_id, v_pagamento, 'saida_liberacao', -p_pessoas_liberadas, auth.uid());
  end if;

  insert into public.bar_eventos (empresa_id, tipo, mesa_id, comanda_id, referencia_id, detalhes, criado_por)
  values (v_empresa, 'pagamento_registrado', v_mesa.id, p_comanda_id, v_pagamento,
          jsonb_build_object('total', v_total, 'pessoas_liberadas', p_pessoas_liberadas), auth.uid());

  -- ---------------------------------------------------------------------------
  -- Migration 018 (Revisão 2) — LIBERAÇÃO AUTOMÁTICA DA MESA: usa a MESMA fonte única de verdade
  -- do novo modelo (private.bar_comanda_saldo_calcular) — nunca mais checa item por item. Um
  -- pagamento PARCIAL nunca satisfaz saldo <= 0, então nunca fecha a mesa por engano.
  -- ---------------------------------------------------------------------------
  select * into v_saldo from private.bar_comanda_saldo_calcular(p_comanda_id, v_empresa);
  if v_saldo.saldo <= 0.01 then
    perform public.bar_mesa_fechar(v_mesa.id);
  end if;

  venda_id := v_venda;
  numero_venda := v_numero;
  pagamento_id := v_pagamento;
  total := v_total;
  return next;
end;
$function$;
CREATE OR REPLACE FUNCTION public.bar_comanda_finalizar_nota_prazo(p_comanda_id uuid, p_cliente_id uuid, p_vencimento date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_empresa uuid := private.exigir_empresa_ativa();
  v_comanda public.bar_comandas%rowtype;
  v_mesa public.bar_mesas%rowtype;
  v_saldo record;
  v_caixa uuid;
  v_venda uuid;
  v_titulo uuid;
  v_numero integer;
  v_valor numeric(14,2);
BEGIN
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=p_comanda_id AND rr.ativa) THEN RAISE EXCEPTION 'Conta reaberta: utilize recebimentos monetários no caixa original, sem conversão em nota a prazo ou pagamento por itens.'; END IF;
  IF NOT private.empresa_tem_modulo('bar') OR NOT private.perm('bar_caixa') THEN
    RAISE EXCEPTION 'Sem permissão para Nota a Prazo no Módulo Bar.' USING errcode='42501';
  END IF;
  -- Sempre mesa -> comanda, inclusive ao recuperar uma resposta perdida.
  PERFORM 1 FROM public.bar_mesas m JOIN public.bar_comandas c ON c.mesa_id=m.id AND c.empresa_id=m.empresa_id
   WHERE c.id=p_comanda_id AND c.empresa_id=v_empresa FOR UPDATE OF m;
  SELECT * INTO v_comanda FROM public.bar_comandas WHERE id=p_comanda_id AND empresa_id=v_empresa FOR UPDATE;
  IF FOUND AND v_comanda.status='fechada' THEN
    SELECT cr.id,cr.venda_id,v.numero_venda,cr.valor_original INTO v_titulo,v_venda,v_numero,v_valor
      FROM public.contas_receber cr JOIN public.vendas v ON v.id=cr.venda_id AND v.empresa_id=cr.empresa_id
      WHERE cr.empresa_id=v_empresa AND cr.venda_id=v_comanda.venda_id AND cr.cliente_id=p_cliente_id
       AND cr.vencimento=p_vencimento AND cr.origem='nota_prazo' AND cr.status<>'cancelado' AND v.cancelada_em IS NULL;
    IF FOUND THEN RETURN jsonb_build_object('comanda_id',v_comanda.id,'mesa_id',v_comanda.mesa_id,'venda_id',v_venda,
     'numero_venda',v_numero,'titulo_id',v_titulo,'valor_a_receber',v_valor,'vencimento',p_vencimento,'repetida',true); END IF;
    RAISE EXCEPTION 'Comanda já finalizada. Confira o histórico antes de repetir com outros dados.';
  END IF;
  IF p_cliente_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.clientes WHERE id=p_cliente_id AND empresa_id=v_empresa
  ) THEN
    RAISE EXCEPTION 'Selecione um cliente cadastrado nesta empresa.';
  END IF;
  IF p_vencimento IS NULL OR p_vencimento < (now() AT TIME ZONE 'America/Sao_Paulo')::date THEN
    RAISE EXCEPTION 'Informe um vencimento válido (hoje ou uma data futura).';
  END IF;
  SELECT * INTO v_comanda FROM public.bar_comandas
   WHERE id=p_comanda_id AND empresa_id=v_empresa FOR UPDATE;
  IF NOT FOUND OR v_comanda.status <> 'aberta' THEN
    RAISE EXCEPTION 'Comanda inexistente ou já finalizada. Atualize a mesa.';
  END IF;
  SELECT * INTO v_mesa FROM public.bar_mesas
   WHERE id=v_comanda.mesa_id AND empresa_id=v_empresa FOR UPDATE;
  IF NOT FOUND OR v_mesa.status <> 'ocupada' OR v_mesa.comanda_atual_id IS DISTINCT FROM v_comanda.id THEN
    RAISE EXCEPTION 'Mesa não está ocupada por esta comanda.';
  END IF;
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=p_comanda_id AND rr.ativa) THEN RAISE EXCEPTION 'Conta reaberta: conversão em título não permitida.'; END IF;
  IF EXISTS(SELECT 1 FROM public.contas_receber WHERE empresa_id=v_empresa AND venda_id=v_comanda.venda_id) THEN
    RAISE EXCEPTION 'A venda já possui título financeiro. Confira o histórico antes de fechar novamente.';
  END IF;
  v_caixa := private.caixa_exigir_aberto('BAR');
  SELECT * INTO v_saldo FROM private.bar_comanda_saldo_calcular(v_comanda.id,v_empresa);
  v_valor := round(v_saldo.saldo,2);
  IF v_valor <= 0.01 THEN
    RAISE EXCEPTION 'Não existe saldo em aberto para Nota a Prazo.';
  END IF;
  IF v_saldo.total_itens_consumido <= 0 THEN
    RAISE EXCEPTION 'Comanda sem consumo válido.';
  END IF;
  -- Finaliza a venda com os itens reais e os pagamentos já recebidos. Nenhum crédito fictício
  -- é registrado em bar_pagamentos; assim o caixa não soma Nota a Prazo como dinheiro.
  v_venda := private.bar_comanda_finalizar_venda(v_comanda.id,v_empresa);
  UPDATE public.vendas SET cliente_id=p_cliente_id,
      forma_pagamento=CASE WHEN v_saldo.total_pago > 0 THEN 'dividido' ELSE 'Nota a Prazo' END,
      caixa_id=v_caixa
   WHERE id=v_venda AND empresa_id=v_empresa;
  SELECT numero_venda INTO v_numero FROM public.vendas WHERE id=v_venda AND empresa_id=v_empresa;
  INSERT INTO public.contas_receber
    (empresa_id,cliente_id,venda_id,origem,valor_original,saldo_aberto,vencimento,criado_por)
  VALUES (v_empresa,p_cliente_id,v_venda,'nota_prazo',v_valor,v_valor,p_vencimento,auth.uid())
  RETURNING id INTO v_titulo;
  IF v_mesa.pessoas_atual <> 0 THEN
    INSERT INTO public.bar_movimentos_pessoas
      (empresa_id,mesa_id,comanda_id,tipo,quantidade,motivo,criado_por)
    VALUES (v_empresa,v_mesa.id,v_comanda.id,'saida_liberacao',-v_mesa.pessoas_atual,
      'Liberação por Nota a Prazo.',auth.uid());
  END IF;
  UPDATE public.bar_comandas SET status='fechada',fechada_em=now(),atualizado_em=now()
    WHERE id=v_comanda.id AND empresa_id=v_empresa;
  UPDATE public.bar_mesas SET status='livre',comanda_atual_id=NULL,aberta_em=NULL,pessoas_atual=0
    WHERE id=v_mesa.id AND empresa_id=v_empresa;
  INSERT INTO public.bar_eventos (empresa_id,tipo,mesa_id,comanda_id,referencia_id,detalhes,criado_por)
    VALUES (v_empresa,'mesa_fechada',v_mesa.id,v_comanda.id,v_titulo,
      jsonb_build_object('modelo','nota_prazo','cliente_id',p_cliente_id,'caixa_id',v_caixa,
                         'valor_a_receber',v_valor,'vencimento',p_vencimento),auth.uid());
  RETURN jsonb_build_object('comanda_id',v_comanda.id,'mesa_id',v_mesa.id,'venda_id',v_venda,
    'numero_venda',v_numero,'titulo_id',v_titulo,'valor_a_receber',v_valor,'vencimento',p_vencimento);
END;
$function$;
CREATE OR REPLACE FUNCTION public.bar_pagamento_estornar(p_pagamento_id uuid, p_motivo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa       uuid := private.exigir_empresa_ativa();
  v_pagamento     public.bar_pagamentos%rowtype;
  v_venda         public.vendas%rowtype;
  v_comanda       public.bar_comandas%rowtype;
  v_mesa          public.bar_mesas%rowtype;
  v_doc           record;
  v_estilo_antigo boolean;
  v_mesa_ainda_e_desta_comanda boolean;
begin
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=(SELECT comanda_id FROM public.bar_pagamentos WHERE id=p_pagamento_id AND empresa_id=v_empresa) AND rr.ativa) THEN RAISE EXCEPTION 'Conta reaberta: use o estorno individual com confirmação integral na mesa.'; END IF;
  if not private.empresa_tem_modulo('bar') then
    raise exception 'Este recurso exige o módulo Bar ativo para esta empresa.' using errcode = '42501';
  end if;
  if not private.perm('bar_estornar_pagamento') then
    raise exception 'Você não tem permissão para estornar pagamentos do bar.' using errcode = '42501';
  end if;
  if p_motivo is null or length(btrim(p_motivo)) < 3 then
    raise exception 'Informe o motivo do estorno (mínimo 3 caracteres).';
  end if;

  select * into v_pagamento from public.bar_pagamentos
   where id = p_pagamento_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Pagamento não encontrado.';
  end if;
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=v_pagamento.comanda_id AND rr.ativa) THEN RAISE EXCEPTION 'Conta reaberta: use o estorno individual na mesa.'; END IF;
  if v_pagamento.estornado then
    raise exception 'Este pagamento já foi estornado.';
  end if;

  -- Migration 018 (Revisão 2): um pagamento estilo novo pode ainda não ter venda_id (a venda só
  -- é criada quando o saldo chega a zero) — nesse caso não existe documento fiscal nem
  -- itens_venda para checar/reverter, então os blocos abaixo são pulados com segurança.
  if v_pagamento.venda_id is not null then
    select tipo_documento, status, numero into v_doc
      from public.documentos_fiscais
     where venda_id = v_pagamento.venda_id and status in ('processando', 'autorizada')
     limit 1;
    if found then
      raise exception 'Existe um documento fiscal % (status: %, número: %) para a venda desta conta. Trate o cancelamento/substituição fiscal primeiro — o estorno do pagamento do bar foi bloqueado para não ficar inconsistente com o Fiscal.',
        v_doc.tipo_documento, v_doc.status, coalesce(v_doc.numero, '—');
    end if;

    select * into v_venda from public.vendas
     where id = v_pagamento.venda_id and empresa_id = v_empresa
       for update;
    if not found then
      raise exception 'A venda associada a este pagamento não foi encontrada.';
    end if;
    if v_venda.cancelada_em is not null then
      raise exception 'Esta venda já foi cancelada por completo — não é possível estornar pagamentos individuais dela.';
    end if;
  end if;

  v_estilo_antigo := exists (
    select 1 from public.bar_pedidos_itens
     where pagamento_id = p_pagamento_id and empresa_id = v_empresa
  );

  update public.bar_pagamentos
     set estornado = true, estornado_em = now(), estornado_por = auth.uid(), estorno_motivo = btrim(p_motivo)
   where id = p_pagamento_id and empresa_id = v_empresa;

  if v_estilo_antigo then
    -- Comportamento ORIGINAL da Migration 016 (Revisão 3), inalterado: decrementa a venda pelo
    -- valor exato deste pagamento e remove só os itens_venda que ELE gerou.
    update public.vendas set total = total - v_pagamento.total
     where id = v_pagamento.venda_id and empresa_id = v_empresa;

    delete from public.itens_venda iv
     using public.bar_pedidos_itens bpi
     where bpi.pagamento_id = p_pagamento_id
       and bpi.empresa_id = v_empresa
       and bpi.item_venda_id = iv.id
       and iv.empresa_id = v_empresa;
  end if;
  -- Pagamento estilo novo: NUNCA tocou item nem venda ao ser registrado, então estornar também
  -- não toca — só a flag `estornado` acima, que já faz o saldo (private.bar_comanda_saldo_calcular)
  -- recalcular sozinho, na hora, um saldo em aberto maior. vendas.total (quando já existe)
  -- permanece exatamente o mesmo, como pedido explicitamente pelo usuário.

  if v_pagamento.venda_id is not null then
    perform private.bar_venda_recalcular_forma_pagamento(v_pagamento.venda_id, v_empresa);
  end if;

  select * into v_comanda from public.bar_comandas
   where id = v_pagamento.comanda_id and empresa_id = v_empresa
     for update;
  select * into v_mesa from public.bar_mesas
   where id = v_comanda.mesa_id and empresa_id = v_empresa
     for update;

  -- Condição de reabertura — corrigida na primeira versão desta migration, preservada sem
  -- nenhuma mudança: reabre quando a mesa ainda está nesta comanda OU quando a mesa está livre e
  -- nenhuma OUTRA comanda foi criada para ela desde que esta fechou. Nunca reabre por cima de um
  -- atendimento novo já em andamento.
  v_mesa_ainda_e_desta_comanda := (
    v_mesa.comanda_atual_id = v_comanda.id
  ) or (
    v_mesa.status = 'livre' and v_mesa.comanda_atual_id is null
    and not exists (
      select 1 from public.bar_comandas c2
       where c2.mesa_id = v_comanda.mesa_id and c2.empresa_id = v_empresa
         and c2.id <> v_comanda.id
         and c2.criado_em > v_comanda.fechada_em
    )
  );

  if v_mesa_ainda_e_desta_comanda then
    if v_estilo_antigo then
      update public.bar_pedidos_itens
         set pagamento_id = null
       where pagamento_id = p_pagamento_id and empresa_id = v_empresa;
    end if;

    if v_pagamento.pessoas_liberadas > 0 then
      update public.bar_mesas set pessoas_atual = pessoas_atual + v_pagamento.pessoas_liberadas
       where id = v_mesa.id and empresa_id = v_empresa;
      insert into public.bar_movimentos_pessoas (empresa_id, mesa_id, comanda_id, pagamento_id, tipo, quantidade, motivo, criado_por)
      values (v_empresa, v_mesa.id, v_comanda.id, p_pagamento_id, 'correcao', v_pagamento.pessoas_liberadas,
              'Estorno do pagamento: ' || btrim(p_motivo), auth.uid());
    end if;

    if v_comanda.status = 'fechada' then
      update public.bar_comandas set status = 'aberta', fechada_em = null
       where id = v_comanda.id and empresa_id = v_empresa;
      update public.bar_mesas set status = 'ocupada', comanda_atual_id = v_comanda.id,
             aberta_em = coalesce(aberta_em, now())
       where id = v_mesa.id and empresa_id = v_empresa and status <> 'ocupada';
    end if;
  end if;

  insert into public.bar_eventos (empresa_id, tipo, mesa_id, comanda_id, referencia_id, detalhes, criado_por)
  values (v_empresa, 'pagamento_estornado', v_comanda.mesa_id, v_pagamento.comanda_id, p_pagamento_id,
          jsonb_build_object(
            'motivo', btrim(p_motivo),
            'venda_id', v_pagamento.venda_id,
            'valor_estornado', v_pagamento.total,
            'estilo', case when v_estilo_antigo then 'itens' else 'valor_monetario' end,
            'itens_reabertos', v_mesa_ainda_e_desta_comanda and v_estilo_antigo,
            'mesa_reaproveitada_por_outro_atendimento', not v_mesa_ainda_e_desta_comanda
          ), auth.uid());
end;
$function$;
CREATE OR REPLACE FUNCTION public.bar_pedido_item_cancelar(p_item_id uuid, p_motivo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa uuid := private.exigir_empresa_ativa();
  v_item    public.bar_pedidos_itens%rowtype;
  v_mesa_id uuid;
  v_comanda_id uuid;
  v_mesa public.bar_mesas%rowtype;
  v_comanda public.bar_comandas%rowtype;
  r         record;
  v_saldo   record;
begin
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=(SELECT comanda_id FROM public.bar_pedidos_itens WHERE id=p_item_id AND empresa_id=v_empresa) AND rr.ativa) THEN RAISE EXCEPTION 'Conta reaberta: use Editar quantidade / cancelar na mesa, com auditoria e idempotência.'; END IF;
perform private.florest_cancelamento_exigir('bar_item_cancelar',p_item_id);
if exists(select 1 from public.bar_pedidos_itens i join public.bar_comandas c on c.id=i.comanda_id and c.empresa_id=i.empresa_id join public.documentos_fiscais d on d.venda_id=c.venda_id and d.empresa_id=c.empresa_id where i.id=p_item_id and i.empresa_id=private.exigir_empresa_ativa() and d.status in ('processando','autorizada')) then raise exception 'Documento fiscal impede cancelamento operacional. Utilize o procedimento fiscal separado.'; end if;
if exists(select 1 from public.bar_pedidos_itens where id=p_item_id and empresa_id=private.exigir_empresa_ativa() and item_venda_id is not null) then raise exception 'Item já consolidado em venda. Requer procedimento administrativo separado.'; end if;
  if not private.empresa_tem_modulo('bar') then
    raise exception 'Este recurso exige o módulo Bar ativo para esta empresa.' using errcode = '42501';
  end if;

  if p_motivo is null or length(btrim(p_motivo)) < 3 then
    raise exception 'Informe o motivo do cancelamento (mínimo 3 caracteres).';
  end if;

  -- Travas na ordem mesa -> comanda -> item, igual ao fechamento e ao lançamento.
  -- A leitura inicial identifica a mesa, mas a validade é rechecada sob as travas.
  select i.comanda_id, c.mesa_id into v_comanda_id, v_mesa_id
    from public.bar_pedidos_itens i
    join public.bar_comandas c on c.id = i.comanda_id and c.empresa_id = i.empresa_id
   where i.id = p_item_id and i.empresa_id = v_empresa;
  if not found then
    raise exception 'Item de pedido não encontrado.';
  end if;

  select * into v_mesa from public.bar_mesas
   where id = v_mesa_id and empresa_id = v_empresa for update;
  if not found or v_mesa.status <> 'ocupada' or v_mesa.comanda_atual_id is distinct from v_comanda_id then
    raise exception 'Mesa não está ocupada com esta comanda.';
  end if;

  select * into v_comanda from public.bar_comandas
   where id = v_comanda_id and empresa_id = v_empresa for update;
  if not found or v_comanda.status <> 'aberta' then
    raise exception 'Esta comanda não está aberta.';
  end if;

  select * into v_item from public.bar_pedidos_itens
   where id = p_item_id and empresa_id = v_empresa and comanda_id = v_comanda_id
     for update;
  if not found then
    raise exception 'Item de pedido não encontrado.';
  end if;
  if v_item.estornado then
    raise exception 'Este item já foi cancelado.';
  end if;

  -- Migration 018 (Revisão 2): item vinculado a um pagamento ESTILO ANTIGO continua bloqueado
  -- aqui, exatamente como a Migration 016 sempre fez — desfazer isso exigiria reverter
  -- itens_venda/vendas.total já assentados; o caminho seguro continua sendo estornar o pagamento
  -- primeiro (public.bar_pagamento_estornar). Um item nunca vinculado a pagamento nenhum (o caso
  -- normal do novo modelo monetário) passa a poder ser cancelado mesmo após já ter havido
  -- pagamento parcial — protegido, em vez disso, pela trava financeira ao final desta função.
  if v_item.pagamento_id is not null then
    raise exception 'Este item já foi incluído em um pagamento e não pode mais ser cancelado. Estorne o pagamento primeiro.';
  end if;


  for r in
    select produto_id, quantidade from public.bar_pedidos_itens_baixas
     where pedido_item_id = p_item_id and empresa_id = v_empresa and estornada = false
     order by produto_id
  loop
    update public.produtos set quantidade_estoque = quantidade_estoque + r.quantidade
     where id = r.produto_id and empresa_id = v_empresa;
    if not found then
      raise exception 'Produto do núcleo não encontrado ao devolver estoque.';
    end if;
  end loop;

  update public.bar_pedidos_itens_baixas
     set estornada = true
   where pedido_item_id = p_item_id and empresa_id = v_empresa and estornada = false;

  update public.bar_pedidos_itens
     set estornado = true, estornado_em = now(), estornado_por = auth.uid(), estorno_motivo = btrim(p_motivo)
   where id = p_item_id and empresa_id = v_empresa;

  -- TRAVA FINANCEIRA (Migration 018, pedida explicitamente pelo usuário): recalcula o saldo já
  -- COM este item cancelado; se os pagamentos válidos ultrapassarem o novo total, desfaz tudo
  -- (o RAISE aborta a transação inteira desta chamada, revertendo também a devolução de estoque
  -- acima) e pede para estornar um pagamento antes.
  select * into v_saldo from private.bar_comanda_saldo_calcular(v_item.comanda_id, v_empresa);
  if v_saldo.saldo < -0.01 then
    raise exception 'Não é possível cancelar este item: os pagamentos já recebidos (R$ %) ficariam maiores que o novo total da conta (R$ %). Estorne um pagamento antes de cancelar.',
      round(v_saldo.total_pago, 2), round(v_saldo.total_final, 2);
  end if;


  insert into public.bar_eventos (empresa_id, tipo, mesa_id, comanda_id, referencia_id, detalhes, criado_por)
  values (v_empresa, 'item_cancelado', v_mesa_id, v_item.comanda_id, p_item_id, jsonb_build_object('motivo', btrim(p_motivo)), auth.uid());

  -- O cancelamento quitou exatamente o saldo: concluir a comanda na mesma transação.
  -- Mantém a validação de permissões, venda e liberação existentes em bar_mesa_fechar.
  if v_saldo.saldo <= 0.01 then
    perform public.bar_mesa_fechar(v_mesa_id);
  end if;
end;
$function$;
CREATE OR REPLACE FUNCTION public.bar_mesa_transferir(p_mesa_origem_id uuid, p_mesa_destino_numero integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_empresa uuid := private.exigir_empresa_ativa();
 v_origem public.bar_mesas%ROWTYPE;
 v_destino public.bar_mesas%ROWTYPE;
 v_comanda public.bar_comandas%ROWTYPE;
 v_destino_id uuid;
 v_lock record;
 v_pedidos integer;
BEGIN
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas WHERE empresa_id=v_empresa AND mesa_id=p_mesa_origem_id AND ativa) THEN RAISE EXCEPTION 'Conta reaberta deve permanecer na mesa original.'; END IF;
 IF NOT private.empresa_tem_modulo('bar') THEN
   RAISE EXCEPTION 'Módulo Bar indisponível.' USING ERRCODE='42501';
 END IF;
 IF NOT private.perm_alguma(ARRAY['bar_mesas','bar_caixa']::text[]) THEN
   RAISE EXCEPTION 'Sem permissão para transferir mesas.' USING ERRCODE='42501';
 END IF;
 IF p_mesa_origem_id IS NULL OR p_mesa_destino_numero IS NULL OR p_mesa_destino_numero <= 0 THEN
   RAISE EXCEPTION 'Informe uma mesa de destino válida.';
 END IF;
 SELECT id INTO v_destino_id FROM public.bar_mesas
 WHERE empresa_id=v_empresa AND numero=p_mesa_destino_numero;
 IF v_destino_id IS NULL THEN RAISE EXCEPTION 'Mesa de destino não encontrada.'; END IF;
 IF v_destino_id=p_mesa_origem_id THEN RAISE EXCEPTION 'Origem e destino são a mesma mesa.'; END IF;
 -- Trava as duas mesas em ordem estável para evitar concorrência e deadlock.
 FOR v_lock IN SELECT id FROM public.bar_mesas
    WHERE empresa_id=v_empresa AND id IN (p_mesa_origem_id,v_destino_id)
    ORDER BY id FOR UPDATE LOOP
   NULL;
 END LOOP;
 SELECT * INTO v_origem FROM public.bar_mesas WHERE id=p_mesa_origem_id AND empresa_id=v_empresa;
 SELECT * INTO v_destino FROM public.bar_mesas WHERE id=v_destino_id AND empresa_id=v_empresa;
 IF v_origem.status <> 'ocupada' OR v_origem.comanda_atual_id IS NULL THEN
   RAISE EXCEPTION 'A mesa de origem precisa estar ocupada com comanda aberta.';
 END IF;
 IF v_destino.status <> 'livre' OR v_destino.comanda_atual_id IS NOT NULL THEN
   RAISE EXCEPTION 'A mesa de destino está ocupada ou indisponível.';
 END IF;
 SELECT * INTO v_comanda FROM public.bar_comandas
 WHERE id=v_origem.comanda_atual_id AND empresa_id=v_empresa FOR UPDATE;
 IF NOT FOUND OR v_comanda.status <> 'aberta' OR v_comanda.mesa_id <> v_origem.id THEN
   RAISE EXCEPTION 'Comanda inconsistente ou já encerrada. Transferência bloqueada.';
 END IF;
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas rr WHERE rr.empresa_id=v_empresa AND rr.comanda_id=v_comanda.id AND rr.ativa) THEN RAISE EXCEPTION 'Conta reaberta deve permanecer na mesa original.'; END IF;
 -- O pedido mantém id/comanda/idempotência; muda apenas a mesa atual de atendimento.
 UPDATE public.bar_pedidos SET mesa_id=v_destino.id
 WHERE empresa_id=v_empresa AND comanda_id=v_comanda.id AND mesa_id=v_origem.id;
 GET DIAGNOSTICS v_pedidos = ROW_COUNT;
 UPDATE public.bar_comandas SET mesa_id=v_destino.id WHERE empresa_id=v_empresa AND id=v_comanda.id;
 UPDATE public.bar_mesas SET status='ocupada', comanda_atual_id=v_comanda.id,
   pessoas_atual=v_origem.pessoas_atual, aberta_em=COALESCE(v_origem.aberta_em,now())
 WHERE id=v_destino.id AND empresa_id=v_empresa;
 UPDATE public.bar_mesas SET status='livre', comanda_atual_id=NULL,
   pessoas_atual=0, aberta_em=NULL
 WHERE id=v_origem.id AND empresa_id=v_empresa;
 INSERT INTO public.bar_eventos (empresa_id,tipo,mesa_id,comanda_id,criado_por,detalhes)
 VALUES (v_empresa,'mesa_transferida',v_destino.id,v_comanda.id,auth.uid(),
 jsonb_build_object('origem_id',v_origem.id,'origem_numero',v_origem.numero,
                    'destino_id',v_destino.id,'destino_numero',v_destino.numero,
                    'pedidos_atualizados',v_pedidos));
 RETURN jsonb_build_object('sucesso',true,'mesa_origem',v_origem.numero,
     'mesa_destino',v_destino.numero,'comanda_id',v_comanda.id);
END;
$function$;
CREATE OR REPLACE FUNCTION public.florest_venda_corrigir(p_venda uuid, p_alteracoes jsonb, p_motivo text, p_idempotencia uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e uuid:=private.exigir_empresa_ativa(); v public.vendas; c public.bar_comandas; r record; x jsonb; f public.bar_pagamentos_formas; b public.bar_pedidos_itens; i public.itens_venda; anterior jsonb; q numeric; preco numeric; delta numeric; saldo record; auditoria public.florest_auditoria_operacoes; novo public.bar_produtos;
begin
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas WHERE empresa_id=e AND venda_id=p_venda AND ativa) THEN RAISE EXCEPTION 'Venda em reedição na mesa: finalize esse atendimento antes de outra ação administrativa.'; END IF;
 perform private.bar_historico_exigir('bar_venda_editar');
 perform private.bar_historico_exigir('bar_historico_detalhar');
 if p_idempotencia is null or length(btrim(p_motivo))<3 or p_motivo is null then raise exception 'Informe motivo e chave da operação.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_idempotencia::text,182));
 if p_alteracoes is null or jsonb_typeof(p_alteracoes)<>'object' then raise exception 'Alterações inválidas.'; end if;
 select * into auditoria from public.florest_auditoria_operacoes where id=p_idempotencia and empresa_id=e and operacao='venda_corrigida' and alvo_id=p_venda;
 if found then
  if auditoria.solicitante_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Operação pertence a outro usuário.'; END IF;
  if auditoria.depois->'_alteracoes' is distinct from p_alteracoes or auditoria.motivo is distinct from p_motivo then raise exception 'Chave de idempotência reutilizada com conteúdo diferente.'; end if;
  return jsonb_build_object('ok',true,'repetida',true);
 end if;
 select * into c from public.bar_comandas where venda_id=p_venda and empresa_id=e;
 if c.id is null then raise exception 'Esta ferramenta corrige vendas do Bar.'; end if;
 perform 1 from public.bar_mesas where id=c.mesa_id for update;
 select * into c from public.bar_comandas where id=c.id and empresa_id=e for update;
 select * into v from public.vendas where id=p_venda and empresa_id=e for update;
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas WHERE empresa_id=e AND venda_id=p_venda AND ativa) THEN RAISE EXCEPTION 'Venda em reedição na mesa.'; END IF;
 if v.cancelada_em is not null then raise exception 'Venda cancelada é imutável.'; end if;
 if private.bar_historico_fiscal_bloqueado(p_venda,e) then raise exception 'Documento fiscal impede correção operacional. Utilize o procedimento fiscal separado.'; end if;
 if exists(select 1 from jsonb_object_keys(p_alteracoes) k where k not in ('pagamentos','itens','desconto','cliente_id')) then raise exception 'Campo de alteração não permitido.'; end if;
 perform private.bar_historico_financeiro_travar(p_venda,e);
 anterior:=public.florest_venda_detalhar(p_venda);
 for x in select * from jsonb_array_elements(coalesce(p_alteracoes->'pagamentos','[]')) loop
  select fo.* into f from public.bar_pagamentos_formas fo join public.bar_pagamentos pa on pa.id=fo.pagamento_id and pa.empresa_id=fo.empresa_id where fo.id=(x->>'id')::uuid and pa.venda_id=p_venda and fo.empresa_id=e and not pa.estornado for update of fo;
  if not found then raise exception 'Pagamento não encontrado.'; end if;
  if exists(select 1 from public.bar_pagamentos pa join public.caixas cx on cx.id=pa.caixa_id and cx.empresa_id=pa.empresa_id where pa.id=f.pagamento_id and cx.status<>'aberto') then raise exception 'Caixa encerrado: pagamento não pode ser reclassificado.'; end if;
  if x ? 'valor' and (x->>'valor')::numeric<>f.valor then raise exception 'Valor recebido não pode ser alterado por reclassificação.'; end if;
  if x ? 'forma_pagamento' and x->>'forma_pagamento' is distinct from f.forma_pagamento and x->>'forma_pagamento' not in ('Dinheiro','Pix','Cartão de Débito','Cartão de Crédito') then raise exception 'Forma inválida.'; end if;
  update public.bar_pagamentos_formas set forma_pagamento=coalesce(x->>'forma_pagamento',forma_pagamento),comprovante_referencia=case when x ? 'comprovante_referencia' then left(x->>'comprovante_referencia',200) else comprovante_referencia end where id=f.id;
 end loop;
 if p_alteracoes ? 'itens' or p_alteracoes ? 'desconto' then
  if c.status NOT IN ('aberta','fechada') or exists(select 1 from public.bar_pagamentos where comanda_id=c.id and empresa_id=e and not estornado) then raise exception 'Itens e valores só podem mudar sem pagamentos liquidados. Estorne primeiro os recebimentos pelo fluxo próprio.'; end if;
  if exists(select 1 from public.bar_pagamentos pa join public.caixas cx on cx.id=pa.caixa_id and cx.empresa_id=pa.empresa_id where pa.comanda_id=c.id and pa.empresa_id=e and cx.status<>'aberto') then raise exception 'Há vínculo com caixa encerrado; a correção financeira exige tratamento próprio.'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_alteracoes->'itens','[]')) loop
   select * into i from public.itens_venda where id=(x->>'id')::bigint and venda_id=p_venda and empresa_id=e for update;
   if not found then raise exception 'Item não encontrado.'; end if;
   select * into b from public.bar_pedidos_itens where item_venda_id=i.id and empresa_id=e and not estornado for update;
   if not found then raise exception 'Item sem vínculo operacional seguro.'; end if;
   q:=coalesce((x->>'quantidade')::numeric,i.quantidade); preco:=coalesce((x->>'preco_unitario')::numeric,i.preco_unitario);
   if q<=0 or preco<0 or q::text in ('NaN','Infinity','-Infinity') or preco::text in ('NaN','Infinity','-Infinity') then raise exception 'Quantidade/preço inválidos. Para excluir, use cancelamento autorizado do item.'; end if;
   IF x ? 'bar_produto_id' AND (x->>'bar_produto_id')::uuid IS DISTINCT FROM b.bar_produto_id THEN
    SELECT * INTO novo FROM public.bar_produtos bp WHERE bp.id=(x->>'bar_produto_id')::uuid AND bp.empresa_id=e AND bp.tipo='simples' AND bp.ativo_cardapio;
    IF NOT FOUND OR EXISTS(SELECT 1 FROM public.bar_produto_grupos WHERE bar_produto_id=novo.id AND empresa_id=e)
     OR EXISTS(SELECT 1 FROM public.bar_produtos_componentes WHERE bar_produto_id=novo.id AND empresa_id=e)
    THEN RAISE EXCEPTION 'Substituição exige produto simples ativo; compostos mantêm sua receita original.'; END IF;
    PERFORM 1 FROM public.produtos WHERE empresa_id=e AND id IN
     (SELECT produto_id FROM public.bar_pedidos_itens_baixas WHERE pedido_item_id=b.id AND empresa_id=e AND NOT estornada UNION SELECT novo.produto_id) ORDER BY id FOR UPDATE;
    FOR r IN SELECT * FROM public.bar_pedidos_itens_baixas WHERE pedido_item_id=b.id AND empresa_id=e AND NOT estornada ORDER BY produto_id FOR UPDATE LOOP
     UPDATE public.produtos SET quantidade_estoque=quantidade_estoque+r.quantidade WHERE id=r.produto_id AND empresa_id=e;
    END LOOP;
    UPDATE public.bar_pedidos_itens_baixas SET estornada=true WHERE pedido_item_id=b.id AND empresa_id=e AND NOT estornada;
    IF (SELECT quantidade_estoque FROM public.produtos WHERE id=novo.produto_id AND empresa_id=e)<q
     AND NOT coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false)
    THEN RAISE EXCEPTION 'Estoque insuficiente para a substituição.'; END IF;
    PERFORM private.produto_exigir_ativo(e,novo.produto_id);
    UPDATE public.produtos SET quantidade_estoque=quantidade_estoque-q WHERE id=novo.produto_id AND empresa_id=e;
    INSERT INTO public.bar_pedidos_itens_baixas(empresa_id,pedido_item_id,produto_id,quantidade) VALUES(e,b.id,novo.produto_id,q);
    -- A substituição de um composto é bloqueada para não apagar suas escolhas históricas.
    IF EXISTS(SELECT 1 FROM public.bar_produtos WHERE id=b.bar_produto_id AND empresa_id=e AND tipo='composto')
     OR EXISTS(SELECT 1 FROM public.bar_pedidos_itens_escolhas WHERE pedido_item_id=b.id AND empresa_id=e) THEN RAISE EXCEPTION 'Composto: só quantidade e preço podem ser corrigidos; use Refazer para outra composição.'; END IF;
    UPDATE public.bar_pedidos_itens SET bar_produto_id=novo.id,produto_id=novo.produto_id,destino_operacional=novo.destino_operacional WHERE id=b.id AND empresa_id=e;
    UPDATE public.itens_venda SET produto_id=novo.produto_id WHERE id=i.id AND empresa_id=e;
   ELSE
   for r in select * from public.bar_pedidos_itens_baixas where pedido_item_id=b.id and empresa_id=e and not estornada order by produto_id for update loop
    delta:=round(r.quantidade*(q/b.quantidade-1),4);
    perform 1 from public.produtos where id=r.produto_id and empresa_id=e for update;
    if delta>0 and (select quantidade_estoque from public.produtos where id=r.produto_id)<delta and not coalesce((select permitir_venda_sem_estoque from public.configuracoes_empresa where empresa_id=e),false) then raise exception 'Estoque insuficiente.'; end if;
    IF delta>0 THEN PERFORM private.produto_exigir_ativo(e,r.produto_id); END IF;
    update public.produtos set quantidade_estoque=quantidade_estoque-delta where id=r.produto_id and empresa_id=e;
    update public.bar_pedidos_itens_baixas set quantidade=quantidade+delta where id=r.id;
   end loop;
   update public.bar_pedidos_itens_escolhas set quantidade=round(quantidade*q/b.quantidade,4) where pedido_item_id=b.id and empresa_id=e;
   END IF;
   update public.bar_pedidos_itens set quantidade=q,preco_unitario=preco where id=b.id;
   update public.itens_venda set quantidade=q,preco_unitario=preco where id=i.id;
  end loop;
  if p_alteracoes ? 'desconto' then
   if p_alteracoes->>'desconto' is null or (p_alteracoes->>'desconto')::numeric<0 or (p_alteracoes->>'desconto')::numeric::text in ('NaN','Infinity','-Infinity') then raise exception 'Desconto inválido.'; end if;
   update public.bar_comandas set desconto=(p_alteracoes->>'desconto')::numeric where id=c.id;
  end if;
  select * into saldo from private.bar_comanda_saldo_calcular(c.id,e);
  if saldo.total_final<0 then raise exception 'Total inválido.'; end if;
  update public.vendas set total=saldo.total_final where id=p_venda;
 end if;
 IF p_alteracoes ? 'cliente_id' THEN
  IF p_alteracoes->>'cliente_id' IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.clientes WHERE id=(p_alteracoes->>'cliente_id')::uuid AND empresa_id=e) THEN RAISE EXCEPTION 'Cliente inválido para esta empresa.'; END IF;
  IF p_alteracoes->>'cliente_id' IS NULL AND EXISTS(SELECT 1 FROM public.contas_receber WHERE venda_id=p_venda AND empresa_id=e AND status<>'cancelado') THEN RAISE EXCEPTION 'Nota a Prazo exige cliente.'; END IF;
  UPDATE public.vendas SET cliente_id=(p_alteracoes->>'cliente_id')::uuid WHERE id=p_venda AND empresa_id=e;
  UPDATE public.contas_receber SET cliente_id=(p_alteracoes->>'cliente_id')::uuid WHERE venda_id=p_venda AND empresa_id=e AND status='aberto';
 END IF;
 SELECT * INTO saldo FROM private.bar_comanda_saldo_calcular(c.id,e);
 IF EXISTS(SELECT 1 FROM public.contas_receber WHERE venda_id=p_venda AND empresa_id=e AND status='aberto') AND saldo.saldo<=0 THEN RAISE EXCEPTION 'Nota a Prazo deve manter saldo positivo.'; END IF;
 UPDATE public.contas_receber SET valor_original=saldo.saldo,saldo_aberto=saldo.saldo WHERE venda_id=p_venda AND empresa_id=e AND status='aberto';
 perform private.bar_venda_recalcular_forma_pagamento(p_venda,e);
 IF EXISTS(SELECT 1 FROM public.contas_receber WHERE venda_id=p_venda AND empresa_id=e AND status<>'cancelado') THEN
  UPDATE public.vendas SET forma_pagamento=CASE WHEN saldo.total_pago>0 THEN 'dividido' ELSE 'Nota a Prazo' END WHERE id=p_venda AND empresa_id=e;
 END IF;
 insert into public.florest_auditoria_operacoes(id,empresa_id,solicitante_id,autorizador_id,operacao,alvo_id,motivo,antes,depois,resultado)
 values(p_idempotencia,e,auth.uid(),auth.uid(),'venda_corrigida',p_venda,p_motivo,anterior,public.florest_venda_detalhar(p_venda)||jsonb_build_object('_alteracoes',p_alteracoes),'sucesso');
 return jsonb_build_object('ok',true);
end $function$;
CREATE OR REPLACE FUNCTION public.bar_historico_cancelar(p_venda uuid, p_motivo text, p_idempotencia uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE e uuid:=private.bar_historico_exigir('bar_venda_cancelar');v public.vendas;c public.bar_comandas;a public.florest_auditoria_operacoes;r record;antes jsonb;
BEGIN
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas WHERE empresa_id=e AND venda_id=p_venda AND ativa) THEN RAISE EXCEPTION 'Venda em reedição na mesa: finalize esse atendimento antes de outra ação administrativa.'; END IF;
 PERFORM private.bar_historico_exigir('bar_historico_detalhar');
 IF p_idempotencia IS NULL OR coalesce(length(btrim(p_motivo)),0) NOT BETWEEN 3 AND 200 THEN RAISE EXCEPTION 'Informe motivo (3 a 200 caracteres) e identificador da operação.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotencia::text,182));
 SELECT * INTO a FROM public.florest_auditoria_operacoes WHERE id=p_idempotencia;
 IF FOUND THEN
  IF a.empresa_id IS DISTINCT FROM e OR a.solicitante_id IS DISTINCT FROM auth.uid() OR a.alvo_id IS DISTINCT FROM p_venda OR a.operacao<>'bar_venda_cancelada' OR a.motivo IS DISTINCT FROM p_motivo THEN RAISE EXCEPTION 'Identificador já usado em outra operação.'; END IF;
  RETURN a.depois;
 END IF;
 SELECT * INTO c FROM public.bar_comandas WHERE venda_id=p_venda AND empresa_id=e;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Venda do Bar não encontrada.'; END IF;
 PERFORM 1 FROM public.bar_mesas WHERE id=c.mesa_id AND empresa_id=e FOR UPDATE;
 SELECT * INTO c FROM public.bar_comandas WHERE id=c.id AND empresa_id=e FOR UPDATE;
 SELECT * INTO v FROM public.vendas WHERE id=p_venda AND empresa_id=e AND tipo='bar' FOR UPDATE;
 IF v.id IS NULL OR v.cancelada_em IS NOT NULL THEN RAISE EXCEPTION 'Venda inexistente ou já cancelada. Atualize o histórico.'; END IF;
 IF c.status NOT IN ('aberta','fechada') THEN RAISE EXCEPTION 'Comanda não elegível para cancelamento administrativo.'; END IF;
 IF private.bar_historico_fiscal_bloqueado(p_venda,e) THEN RAISE EXCEPTION 'Documento fiscal impede cancelamento comum. Utilize o procedimento fiscal próprio.'; END IF;
 IF EXISTS(SELECT 1 FROM public.bar_pagamentos WHERE comanda_id=c.id AND empresa_id=e AND venda_id IS NOT NULL AND venda_id<>p_venda) THEN RAISE EXCEPTION 'Recebimento vinculado a outra venda: exige conciliação.'; END IF;
 IF c.status='aberta' THEN
  -- Refazer gera venda aberta; inclui eventual pedido posterior antes de preservar o snapshot.
  PERFORM private.bar_comanda_finalizar_venda(c.id,e);
 END IF;
 PERFORM private.bar_historico_financeiro_travar(p_venda,e);
 IF EXISTS(SELECT 1 FROM public.vendas_pagamentos WHERE venda_id=p_venda AND empresa_id=e) THEN RAISE EXCEPTION 'Movimento financeiro fora do padrão Bar: concilie antes.'; END IF;
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas WHERE empresa_id=e AND venda_id=p_venda AND ativa) THEN RAISE EXCEPTION 'Venda em reedição na mesa.'; END IF;
 antes:=public.florest_venda_detalhar(p_venda);
 PERFORM 1 FROM public.produtos WHERE empresa_id=e AND id IN
 (SELECT bx.produto_id FROM public.bar_pedidos_itens_baixas bx JOIN public.bar_pedidos_itens i ON i.id=bx.pedido_item_id AND i.empresa_id=bx.empresa_id WHERE i.comanda_id=c.id AND i.empresa_id=e AND NOT bx.estornada) ORDER BY id FOR UPDATE;
 FOR r IN SELECT bx.produto_id,sum(bx.quantidade) AS quantidade FROM public.bar_pedidos_itens_baixas bx JOIN public.bar_pedidos_itens i ON i.id=bx.pedido_item_id AND i.empresa_id=bx.empresa_id WHERE i.comanda_id=c.id AND i.empresa_id=e AND NOT bx.estornada GROUP BY bx.produto_id ORDER BY bx.produto_id LOOP
  UPDATE public.produtos SET quantidade_estoque=quantidade_estoque+r.quantidade WHERE id=r.produto_id AND empresa_id=e;
 END LOOP;
 UPDATE public.bar_pedidos_itens_baixas bx SET estornada=true FROM public.bar_pedidos_itens i WHERE i.id=bx.pedido_item_id AND i.empresa_id=bx.empresa_id AND i.comanda_id=c.id AND i.empresa_id=e AND NOT bx.estornada;
 UPDATE public.bar_pedidos_itens SET estornado=true,estornado_em=now(),estornado_por=auth.uid(),estorno_motivo=p_motivo WHERE comanda_id=c.id AND empresa_id=e AND NOT estornado;
 UPDATE public.bar_pagamentos SET estornado=true,estornado_em=now(),estornado_por=auth.uid(),estorno_motivo=p_motivo WHERE comanda_id=c.id AND empresa_id=e AND NOT estornado;
 UPDATE public.contas_receber SET status='cancelado',saldo_aberto=0,cancelado_em=now(),cancelado_por=auth.uid(),motivo_cancelamento=p_motivo WHERE venda_id=p_venda AND empresa_id=e AND status='aberto';
 UPDATE public.vendas SET cancelada_em=now(),cancelada_por=auth.uid(),motivo_cancelamento=p_motivo WHERE id=p_venda AND empresa_id=e;
 -- Comanda faturada permanece fechada com seu venda_id (constraint existente).
 -- O cancelamento administrativo fica em vendas e na auditoria; não apaga o vínculo.
 UPDATE public.bar_comandas SET status='fechada',fechada_em=coalesce(fechada_em,now()),atualizado_em=now() WHERE id=c.id AND empresa_id=e;
 IF EXISTS(SELECT 1 FROM public.bar_mesas WHERE id=c.mesa_id AND empresa_id=e AND comanda_atual_id=c.id AND status='ocupada') THEN
  INSERT INTO public.bar_movimentos_pessoas(empresa_id,mesa_id,comanda_id,tipo,quantidade,motivo,criado_por)
   SELECT e,id,c.id,'saida_liberacao',-pessoas_atual,p_motivo,auth.uid() FROM public.bar_mesas WHERE id=c.mesa_id AND empresa_id=e AND pessoas_atual>0;
  UPDATE public.bar_mesas SET status='livre',comanda_atual_id=NULL,aberta_em=NULL,pessoas_atual=0 WHERE id=c.mesa_id AND empresa_id=e AND comanda_atual_id=c.id;
 END IF;
 -- Não reabre nem libera uma mesa que já foi reutilizada.
 INSERT INTO public.florest_auditoria_operacoes(id,empresa_id,solicitante_id,autorizador_id,operacao,alvo_id,motivo,antes,depois,resultado)
 VALUES(p_idempotencia,e,auth.uid(),auth.uid(),'bar_venda_cancelada',p_venda,p_motivo,antes,jsonb_build_object('ok',true,'venda_id',p_venda),'sucesso');
 RETURN jsonb_build_object('ok',true,'venda_id',p_venda);
END $function$;
CREATE OR REPLACE FUNCTION public.bar_historico_refazer(p_venda uuid, p_mesa uuid, p_motivo text, p_idempotencia uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE e uuid:=private.bar_historico_exigir('bar_venda_refazer');v public.vendas;m public.bar_mesas;c public.bar_comandas;a public.florest_auditoria_operacoes;itens jsonb;pedido record;nova uuid;n bigint;r jsonb;
BEGIN
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas WHERE empresa_id=e AND venda_id=p_venda AND ativa) THEN RAISE EXCEPTION 'Venda em reedição na mesa: finalize esse atendimento antes de outra ação administrativa.'; END IF;
 PERFORM private.bar_historico_exigir('bar_historico_detalhar');
 IF NOT private.perm('bar_pedidos') THEN RAISE EXCEPTION 'Refazer exige também permissão para lançar pedidos.' USING errcode='42501'; END IF;
 IF p_idempotencia IS NULL OR coalesce(length(btrim(p_motivo)),0) NOT BETWEEN 3 AND 200 THEN RAISE EXCEPTION 'Informe motivo e identificador.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotencia::text,182));
 SELECT * INTO a FROM public.florest_auditoria_operacoes WHERE id=p_idempotencia;
 IF FOUND THEN
  IF a.empresa_id IS DISTINCT FROM e OR a.solicitante_id IS DISTINCT FROM auth.uid() OR a.operacao<>'bar_venda_refeita' OR a.alvo_id IS DISTINCT FROM p_venda OR a.depois->>'mesa_id' IS DISTINCT FROM p_mesa::text OR a.motivo IS DISTINCT FROM p_motivo THEN RAISE EXCEPTION 'Identificador usado em outra operação.'; END IF;
  RETURN a.depois;
 END IF;
 SELECT * INTO m FROM public.bar_mesas WHERE id=p_mesa AND empresa_id=e FOR UPDATE;
 IF NOT FOUND OR m.status<>'livre' THEN RAISE EXCEPTION 'Selecione uma mesa livre.'; END IF;
 SELECT * INTO v FROM public.vendas WHERE id=p_venda AND empresa_id=e AND tipo='bar' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Venda não encontrada.'; END IF;
 IF EXISTS(SELECT 1 FROM private.bar_reaberturas WHERE empresa_id=e AND venda_id=p_venda AND ativa) THEN RAISE EXCEPTION 'Venda em reedição na mesa.'; END IF;
 -- Copiar para nova venda nunca altera documento ou registro original, mesmo se autorizado.
 SELECT * INTO c FROM public.bar_comandas WHERE venda_id=p_venda AND empresa_id=e;
 SELECT jsonb_agg(jsonb_build_object('bar_produto_id',i.bar_produto_id,'quantidade',i.quantidade,'observacao',i.observacao,
 'escolhas',(SELECT coalesce(jsonb_agg(jsonb_build_object('grupo_id',x.grupo_id,'produto_id',x.produto_id)),'[]') FROM public.bar_pedidos_itens_escolhas x CROSS JOIN LATERAL generate_series(1,round(x.quantidade/nullif(i.quantidade,0))::integer) repeticao WHERE x.pedido_item_id=i.id AND x.empresa_id=e)))
 INTO itens FROM public.bar_pedidos_itens i WHERE i.comanda_id=c.id AND i.empresa_id=e
 AND (NOT i.estornado OR (v.cancelada_em IS NOT NULL AND i.estornado_em=v.cancelada_em));
 IF itens IS NULL THEN RAISE EXCEPTION 'Sem itens com vínculo operacional seguro para refazer.'; END IF;
 SELECT * INTO pedido FROM public.bar_pedido_lancar(p_mesa,itens,p_idempotencia);
 nova:=private.bar_comanda_finalizar_venda(pedido.comanda_id,e);
 UPDATE public.vendas SET cliente_id=v.cliente_id WHERE id=nova AND empresa_id=e;
 SELECT numero_venda INTO n FROM public.vendas WHERE id=nova AND empresa_id=e;
 r:=jsonb_build_object('ok',true,'venda_id',nova,'numero_venda',n,'mesa_id',p_mesa,'comanda_id',pedido.comanda_id);
 INSERT INTO public.florest_auditoria_operacoes(id,empresa_id,solicitante_id,autorizador_id,operacao,alvo_id,motivo,antes,depois,resultado)
 VALUES(p_idempotencia,e,auth.uid(),auth.uid(),'bar_venda_refeita',p_venda,p_motivo,jsonb_build_object('venda_id',p_venda),r,'sucesso');
 RETURN r;
END $function$;

COMMIT;

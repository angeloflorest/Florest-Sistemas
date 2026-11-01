SET LOCAL lock_timeout='5s';
DO $guard$ BEGIN
 IF md5(pg_get_functiondef('private.bar_reabertura_validar(uuid,uuid)'::regprocedure))<>'570c5be5f5279d1b765be9b9e57c938b' THEN RAISE EXCEPTION 'Função alterada: bar_reabertura_validar'; END IF;
 IF md5(pg_get_functiondef('bar_historico_mesa_editar(uuid,text,jsonb,text,uuid)'::regprocedure))<>'34ae2fabd3efa44ee2b96c2ca2a6d4f7' THEN RAISE EXCEPTION 'Função alterada: bar_historico_mesa_editar'; END IF;
 IF to_regprocedure('private.bar_reabertura_caixa_original(uuid,uuid)') IS NOT NULL THEN RAISE EXCEPTION 'Correção já instalada; conferir antes de reaplicar.'; END IF;
END $guard$;
CREATE FUNCTION private.bar_reabertura_caixa_original(p_comanda uuid,p_empresa uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = '' AS $fn$
DECLARE original uuid; quantidade bigint; ausentes bigint;
BEGIN
 SELECT v.caixa_id INTO original FROM public.bar_comandas c
 JOIN public.vendas v ON v.id=c.venda_id AND v.empresa_id=c.empresa_id
 WHERE c.id=p_comanda AND c.empresa_id=p_empresa AND v.tipo='bar';
 IF NOT FOUND THEN RAISE EXCEPTION 'Venda/comanda original não encontrada.' USING ERRCODE='42501'; END IF;
 -- Nunca trocar um caixa informado, mesmo fechado, por outro atualmente aberto.
 IF original IS NOT NULL THEN RETURN original; END IF;
 SELECT count(DISTINCT pa.caixa_id),count(*) FILTER(WHERE pa.caixa_id IS NULL),min(pa.caixa_id::text)::uuid
 INTO quantidade,ausentes,original FROM public.bar_pagamentos pa
 WHERE pa.empresa_id=p_empresa AND pa.comanda_id=p_comanda;
 -- Inclui recebimentos estornados: continuam parte da origem histórica.
 IF quantidade<>1 OR ausentes<>0 OR original IS NULL THEN
  RAISE EXCEPTION 'Não foi possível comprovar um único caixa original nos recebimentos. Conciliação necessária.' USING ERRCODE='CX001';
 END IF;
 RETURN original;
END $fn$;
REVOKE ALL ON FUNCTION private.bar_reabertura_caixa_original(uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.bar_reabertura_validar(p_comanda uuid, p_empresa uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE c public.bar_comandas; v public.vendas; cx public.caixas;
BEGIN
 SELECT * INTO c FROM public.bar_comandas WHERE id=p_comanda AND empresa_id=p_empresa;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada.'; END IF;
 SELECT * INTO v FROM public.vendas WHERE id=c.venda_id AND empresa_id=p_empresa FOR UPDATE;
 IF v.id IS NULL OR v.tipo IS DISTINCT FROM 'bar' OR v.cancelada_em IS NOT NULL THEN RAISE EXCEPTION 'Venda do Bar inconsistente ou cancelada.'; END IF;
 SELECT * INTO cx FROM public.caixas WHERE id=private.bar_reabertura_caixa_original(c.id,p_empresa) AND empresa_id=p_empresa FOR SHARE;
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
END $function$;
CREATE OR REPLACE FUNCTION public.bar_historico_mesa_editar(p_comanda_id uuid, p_acao text, p_dados jsonb DEFAULT '{}'::jsonb, p_motivo text DEFAULT ''::text, p_idempotencia uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  VALUES(e,c.id,v.id,m.id,private.bar_reabertura_caixa_original(c.id,e),auth.uid(),btrim(p_motivo)) ON CONFLICT(empresa_id,comanda_id) DO UPDATE SET ativa=true,versao=private.bar_reaberturas.versao+1,aberto_por=auth.uid(),motivo=excluded.motivo,aberto_em=now();
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
END $function$;

-- Ajustes autorizados no fechamento da reedição; sem alterar recebimentos.

BEGIN;

SET LOCAL lock_timeout='5s';

DO $guard$ BEGIN IF md5(pg_get_functiondef('private.bar_reabertura_validar(uuid,uuid)'::regprocedure))<>'b49f74878b59a762ed4ffc3e53ea42ab' THEN RAISE EXCEPTION 'Função atualizada durante a análise: private.bar_reabertura_validar(uuid,uuid)'; END IF; END $guard$;

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
 IF EXISTS(SELECT 1 FROM public.documentos_fiscais WHERE empresa_id=p_empresa AND venda_id=v.id AND NOT (tipo_documento='nfce' AND status='nao_emitida' AND numero IS NULL AND chave_acesso IS NULL AND protocolo IS NULL AND id_dfe IS NULL AND xml_conteudo IS NULL AND xml_url IS NULL AND pdf_conteudo IS NULL AND pdf_url IS NULL AND coalesce(retorno_provedor,'{}'::jsonb)='{}'::jsonb))
 OR EXISTS(SELECT 1 FROM public.fiscal_contingencia_documentos WHERE empresa_id=p_empresa AND venda_id=v.id)
 THEN RAISE EXCEPTION 'Documento fiscal emitido, enviado ou com identidade reservada impede esta edição.'; END IF;
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


DO $guard$ BEGIN IF md5(pg_get_functiondef('private.bar_reabertura_sincronizar(uuid,uuid)'::regprocedure))<>'6efb164fa7c94aa101e79bef8d24b730' THEN RAISE EXCEPTION 'Função atualizada durante a análise: private.bar_reabertura_sincronizar(uuid,uuid)'; END IF; END $guard$;

CREATE OR REPLACE FUNCTION private.bar_reabertura_sincronizar(p_comanda uuid, p_empresa uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
 -- Somente o rascunho nunca enviado acompanha o total comercial corrigido.
 UPDATE public.documentos_fiscais SET valor=s.total_final,atualizado_em=now() WHERE venda_id=c.venda_id AND empresa_id=p_empresa AND tipo_documento='nfce' AND status='nao_emitida' AND numero IS NULL AND chave_acesso IS NULL AND protocolo IS NULL AND id_dfe IS NULL AND xml_conteudo IS NULL AND xml_url IS NULL AND pdf_conteudo IS NULL AND pdf_url IS NULL AND coalesce(retorno_provedor,'{}'::jsonb)='{}'::jsonb;
 PERFORM private.bar_venda_recalcular_forma_pagamento(c.venda_id,p_empresa);
 UPDATE private.bar_reaberturas SET versao=versao+1 WHERE empresa_id=p_empresa AND comanda_id=c.id;
 RETURN c.venda_id;
END $function$;


DO $guard$ BEGIN IF md5(pg_get_functiondef('bar_historico_mesa_editar(uuid,text,jsonb,text,uuid)'::regprocedure))<>'edf6cd4bf28e4d0cc60950ead485cc37' THEN RAISE EXCEPTION 'Função atualizada durante a análise: bar_historico_mesa_editar(uuid,text,jsonb,text,uuid)'; END IF; END $guard$;

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
   -- Desconto/acréscimo/taxa pertencem à mesma transação do fechamento e à auditoria existente.
   FOR b IN SELECT key,value FROM jsonb_each(p_dados) WHERE key IN ('desconto','acrescimo','taxa_servico') LOOP
    IF jsonb_typeof(b.value)<>'number' THEN RAISE EXCEPTION 'Informe ajustes monetários válidos.'; END IF;
    q:=(b.value #>> '{}')::numeric;
    IF q::text IN ('NaN','Infinity','-Infinity') OR q<0 OR q>1000000000 OR q<>round(q,2) THEN RAISE EXCEPTION 'Informe ajustes não negativos com até duas casas decimais.'; END IF;
   END LOOP;
   UPDATE public.bar_comandas SET desconto=coalesce((p_dados->>'desconto')::numeric,desconto),
    acrescimo=coalesce((p_dados->>'acrescimo')::numeric,acrescimo),
    taxa_servico=coalesce((p_dados->>'taxa_servico')::numeric,taxa_servico),atualizado_em=now()
    WHERE id=c.id AND empresa_id=e;
   SELECT * INTO s FROM private.bar_comanda_saldo_calcular(c.id,e);
   IF s.saldo<>0 THEN RAISE EXCEPTION 'A conta deve ficar exatamente quitada após os ajustes (saldo: R$ %). Confira o desconto, receba o restante ou estorne o excedente.',s.saldo; END IF;
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


-- Leitura interna do saldo oficial para o emissor; não exposta ao operador.
CREATE FUNCTION public.bar_fiscal_saldo(p_venda_id uuid,p_empresa_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $fn$
DECLARE c public.bar_comandas; s record; v public.vendas; d numeric; o numeric;
BEGIN
 SELECT * INTO v FROM public.vendas WHERE id=p_venda_id AND empresa_id=p_empresa_id AND tipo='bar';
 IF v.id IS NULL OR v.cancelada_em IS NOT NULL THEN RAISE EXCEPTION 'Venda do Bar inexistente ou cancelada.'; END IF;
 SELECT * INTO c FROM public.bar_comandas WHERE venda_id=v.id AND empresa_id=p_empresa_id;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Comanda desta venda não encontrada.'; END IF;
 SELECT * INTO s FROM private.bar_comanda_saldo_calcular(c.id,p_empresa_id);
 SELECT coalesce(sum(desconto),0),coalesce(sum(acrescimo+taxa_servico),0) INTO d,o
 FROM public.bar_pagamentos WHERE comanda_id=c.id AND empresa_id=p_empresa_id AND NOT estornado;
 RETURN jsonb_build_object('comanda_id',c.id,'status',c.status,'saldo',s.saldo,'total_final',s.total_final,
 'total_pago',s.total_pago,'desconto',round(s.desconto+d,2),'outros',round(s.acrescimo+s.taxa_servico+o,2),
 'em_edicao',EXISTS(SELECT 1 FROM private.bar_reaberturas WHERE comanda_id=c.id AND empresa_id=p_empresa_id AND ativa));
END $fn$;
REVOKE ALL ON FUNCTION public.bar_fiscal_saldo(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.bar_fiscal_saldo(uuid,uuid) TO service_role;
-- A trava já existente da venda serializa reedição com a reserva fiscal.
DO $guard$ BEGIN
 IF md5(pg_get_functiondef('private.bar_historico_trava_fiscal()'::regprocedure))<>'f4d96436fe4a752a3ee23aad9cf89933' THEN RAISE EXCEPTION 'Trava fiscal alterada durante a análise.'; END IF;
END $guard$;
CREATE OR REPLACE FUNCTION private.bar_historico_trava_fiscal() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE v public.vendas; f jsonb;
BEGIN
 SELECT * INTO v FROM public.vendas WHERE id=new.venda_id AND empresa_id=new.empresa_id FOR UPDATE;
 IF v.tipo='bar' AND v.cancelada_em IS NOT NULL THEN
  RAISE EXCEPTION 'Venda do Bar cancelada: documento fiscal deve seguir o procedimento fiscal próprio.';
 END IF;
 IF v.tipo='bar' AND new.status='processando' THEN
  f:=public.bar_fiscal_saldo(new.venda_id,new.empresa_id);
  IF f->>'status'<>'fechada' OR (f->>'em_edicao')::boolean OR (f->>'saldo')::numeric<>0 THEN
   RAISE EXCEPTION 'Conclua os ajustes e quite a mesa antes de iniciar a emissão fiscal.';
  END IF;
 END IF;
 RETURN new;
END $fn$;
COMMIT;

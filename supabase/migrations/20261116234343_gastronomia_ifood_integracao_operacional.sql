-- Funções novas e ramificações exclusivas da origem iFood; demais canais preservados.
CREATE FUNCTION private.gastronomia_ifood_payload(p_e uuid,p_normal jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE i jsonb; o jsonb; bp record; op record; escolhas jsonb; itens jsonb:='[]'; extras jsonb; k int; q numeric;
BEGIN
 FOR i IN SELECT value FROM jsonb_array_elements(p_normal->'itens') LOOP
  SELECT * INTO bp FROM private.gastronomia_produtos_operacionais WHERE empresa_id=p_e AND produto_id=(i->>'produto_id')::uuid AND ativo_cardapio;
  IF bp.id IS NULL THEN RAISE EXCEPTION 'Vincule o produto % ao cardápio da Gastronomia.',i->>'nome'; END IF;
  escolhas:='[]'; extras:='[]';
  FOR o IN SELECT value FROM jsonb_array_elements(i->'adicionais') LOOP
   SELECT count(*) qtd,min(g.id::text)::uuid grupo INTO op FROM private.gastronomia_grupos_operacionais g JOIN private.gastronomia_opcoes_operacionais z ON z.grupo_id=g.id AND z.empresa_id=p_e WHERE g.empresa_id=p_e AND g.bar_produto_id=bp.id AND z.produto_id=(o->>'produto_id')::uuid;
   IF op.qtd=1 THEN
    q:=(o->>'quantidade')::numeric/(i->>'quantidade')::numeric;
    IF q<>trunc(q) OR q<0 OR q>100 THEN RAISE EXCEPTION 'Quantidade do adicional % exige revisão da composição.',o->>'nome'; END IF;
    FOR k IN 1..q::int LOOP escolhas:=escolhas||jsonb_build_array(jsonb_build_object('grupo_id',op.grupo,'produto_id',o->>'produto_id')); END LOOP;
   ELSIF op.qtd=0 THEN
    SELECT * INTO op FROM private.gastronomia_produtos_operacionais WHERE empresa_id=p_e AND produto_id=(o->>'produto_id')::uuid AND ativo_cardapio;
    IF op.id IS NULL THEN RAISE EXCEPTION 'Vincule o adicional % ao cardápio.',o->>'nome'; END IF;
    extras:=extras||jsonb_build_array(jsonb_build_object('bar_produto_id',op.id,'quantidade',(o->>'quantidade')::numeric,'observacao','Adicional iFood: '||(i->>'nome'),'escolhas','[]'::jsonb,'ifood_total',0));
   ELSE RAISE EXCEPTION 'Adicional % pertence a mais de um grupo; revise o vínculo.',o->>'nome'; END IF;
  END LOOP;
  IF round(round((i->>'total')::numeric/100/(i->>'quantidade')::numeric,2)*(i->>'quantidade')::numeric,2)<>(i->>'total')::numeric/100 THEN RAISE EXCEPTION 'Preço fracionado exige revisão para preservar o total iFood.'; END IF;
  itens:=itens||jsonb_build_array(jsonb_build_object('bar_produto_id',bp.id,'quantidade',(i->>'quantidade')::numeric,'observacao',i->>'observacao','escolhas',escolhas,'ifood_total',(i->>'total')::numeric/100))||extras;
 END LOOP;
 RETURN itens;
END $$;
CREATE FUNCTION private.gastronomia_ifood_validar_itens(p_e uuid,p_normal jsonb) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE itens jsonb;
BEGIN
 IF jsonb_array_length(coalesce(p_normal->'avisos','[]'))<>0 THEN RAISE EXCEPTION 'Pedido exige revisão de produtos ou valores.'; END IF;
 itens:=private.gastronomia_ifood_payload(p_e,p_normal);
 -- O resolver valida receita, escolhas e estoque. A subtransação sempre desfaz as baixas deste ensaio.
 BEGIN
  PERFORM private.gastronomia_resolver(itens,p_e);
  RAISE EXCEPTION USING ERRCODE='PIF01',MESSAGE='Validação concluída sem persistir baixas';
 EXCEPTION WHEN SQLSTATE 'PIF01' THEN NULL; END;
END $$;
CREATE FUNCTION private.gastronomia_ifood_importar(p_e uuid,p_pedido uuid) RETURNS uuid LANGUAGE plpgsql SET search_path='' AS $$
DECLARE p private.gastronomia_ifood_pedidos; a uuid; n bigint; i jsonb; x jsonb; dados jsonb; resolvido jsonb; iid uuid; ord int:=0; subtotal numeric:=0; diferenca numeric; dest text; cliente jsonb; addr jsonb;
BEGIN
 SELECT * INTO p FROM private.gastronomia_ifood_pedidos WHERE empresa_id=p_e AND pedido_id=p_pedido FOR UPDATE;
 IF p.atendimento_id IS NOT NULL THEN RETURN p.atendimento_id; END IF;
 IF p.estado_ifood NOT IN ('confirmado','em_preparo','pronto','despachado','concluido') THEN RAISE EXCEPTION 'Aguarde a confirmação do iFood.'; END IF;
 IF coalesce((p.normalizado->>'inicio_preparo')::timestamptz,now())>now() THEN RETURN NULL; END IF;
 PERFORM private.gastronomia_ifood_validar_itens(p_e,p.normalizado);
 dados:=private.gastronomia_ifood_payload(p_e,p.normalizado); resolvido:=private.gastronomia_resolver(dados,p_e);
 cliente:=p.detalhe->'customer';addr:=p.detalhe#>'{delivery,deliveryAddress}';
 UPDATE public.gastronomia_configuracoes SET ultimo_numero=ultimo_numero+1 WHERE empresa_id=p_e RETURNING ultimo_numero INTO n;
 IF n IS NULL THEN RAISE EXCEPTION 'Configure a Gastronomia desta empresa.'; END IF;
 INSERT INTO public.gastronomia_atendimentos(empresa_id,numero,tipo,origem,cliente_nome,telefone,endereco,referencia,servico_regra,servico_percentual)
 VALUES(p_e,n,CASE WHEN p.normalizado->>'tipo'='DELIVERY' THEN 'entrega' ELSE 'retirada' END,'ifood',coalesce(nullif(cliente->>'name',''),'Cliente iFood'),coalesce(nullif(cliente#>>'{phone,number}',''),'Contato pelo iFood'),
 coalesce(nullif(concat_ws(', ',addr->>'streetName',addr->>'streetNumber',addr->>'neighborhood',addr->>'city'),'') ,'Endereço no iFood'),left(addr->>'reference',300),'percentual_v1',0) RETURNING id INTO a;
 FOR x IN SELECT value FROM jsonb_array_elements(resolvido) LOOP
  i:=dados->ord;ord:=ord+1;
  x:=x||jsonb_build_object('lote',p.pedido_id,'autor_publico','iFood','ifood_pedido_id',p.pedido_id,'preco_venda',round((i->>'ifood_total')::numeric/(i->>'quantidade')::numeric,2));
  INSERT INTO public.gastronomia_itens(empresa_id,atendimento_id,produto_id,quantidade,preco_unitario,snapshot)
  VALUES(p_e,a,(x->>'produto_id')::uuid,(x->>'quantidade')::numeric,(x->>'preco_venda')::numeric,x) RETURNING id INTO iid;
  subtotal:=subtotal+round((x->>'quantidade')::numeric*(x->>'preco_venda')::numeric,2);
  FOR dest IN SELECT DISTINCT z FROM (SELECT x->>'destino_operacional' z UNION SELECT v->>'destino_operacional' FROM jsonb_array_elements(x->'escolhas_resolvidas') v) s WHERE z IN ('bar','cozinha') LOOP
   INSERT INTO public.gastronomia_preparo(empresa_id,item_id,setor) VALUES(p_e,iid,dest);
  END LOOP;
 END LOOP;
 diferenca:=p.total_centavos::numeric/100-subtotal;
 UPDATE public.gastronomia_atendimentos SET taxa_entrega=CASE WHEN tipo='entrega' THEN coalesce((p.detalhe#>>'{total,deliveryFee}')::numeric,0) ELSE 0 END WHERE id=a;
 SELECT p.total_centavos::numeric/100-subtotal-taxa_entrega INTO diferenca FROM public.gastronomia_atendimentos WHERE id=a;
 UPDATE public.gastronomia_atendimentos SET desconto=greatest(-diferenca,0),acrescimo=greatest(diferenca,0) WHERE id=a;
 UPDATE private.gastronomia_ifood_pedidos SET atendimento_id=a,importado_em=now(),revisao_motivo=NULL WHERE empresa_id=p_e AND pedido_id=p_pedido;
 FOR i IN SELECT value FROM jsonb_array_elements(p.normalizado->'pagamentos') LOOP
  IF (i->>'valor')::bigint>0 THEN
   INSERT INTO private.gastronomia_ifood_pagamentos(empresa_id,merchant_id,pedido_id,indice,tipo,forma,valor_centavos,bandeira)
   VALUES(p_e,p.merchant_id,p_pedido,ord,i->>'tipo',i->>'forma',(i->>'valor')::bigint,i->>'bandeira') ON CONFLICT DO NOTHING;
  END IF;ord:=ord+1;
 END LOOP;
 INSERT INTO public.gastronomia_eventos(empresa_id,atendimento_id,tipo,detalhes) VALUES(p_e,a,'ifood_importar',jsonb_build_object('pedido_id',p_pedido));
 PERFORM private.gastronomia_imprimir(a,p_e,p.pedido_id);
 UPDATE private.gastronomia_ifood_pedidos SET impresso_em=now() WHERE empresa_id=p_e AND pedido_id=p_pedido;
 INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(p_e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
 RETURN a;
END $$;
CREATE FUNCTION private.gastronomia_ifood_evento(p_e uuid,p_evento uuid) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE ev private.gastronomia_ifood_eventos; p private.gastronomia_ifood_pedidos; novo text; a uuid; r record;
BEGIN
 SELECT * INTO ev FROM private.gastronomia_ifood_eventos WHERE empresa_id=p_e AND evento_id=p_evento;
 IF ev.pedido_id IS NULL THEN RETURN; END IF;
 SELECT * INTO p FROM private.gastronomia_ifood_pedidos WHERE empresa_id=p_e AND merchant_id=ev.merchant_id AND pedido_id=ev.pedido_id FOR UPDATE;
 IF p.pedido_id IS NULL THEN RAISE EXCEPTION 'Detalhes do pedido ainda não recebidos.'; END IF;
 IF ev.codigo IN ('HANDSHAKE_DISPUTE','HSD') THEN
  UPDATE private.gastronomia_ifood_pedidos SET negociacao=ev.payload->'metadata',revisao_motivo='Negociação pendente: responda antes do prazo no iFood.' WHERE empresa_id=p_e AND pedido_id=ev.pedido_id;RETURN;
 ELSIF ev.codigo IN ('HANDSHAKE_SETTLEMENT','HSS') THEN
  UPDATE private.gastronomia_ifood_comandos SET estado='confirmado' WHERE empresa_id=p_e AND pedido_id=p.pedido_id AND acao IN ('aceitar_negociacao','recusar_negociacao') AND payload->>'disputeId'=ev.payload#>>'{metadata,disputeId}';
  UPDATE private.gastronomia_ifood_pedidos SET negociacao=ev.payload->'metadata',revisao_motivo='Confira o resultado da negociação no iFood.' WHERE empresa_id=p_e AND pedido_id=ev.pedido_id;RETURN;
 END IF;
 novo:=CASE ev.codigo WHEN 'PLACED' THEN 'recebido' WHEN 'PLC' THEN 'recebido' WHEN 'CONFIRMED' THEN 'confirmado' WHEN 'CFM' THEN 'confirmado' WHEN 'PREPARATION_STARTED' THEN 'em_preparo' WHEN 'SEPARATION_STARTED' THEN 'em_preparo' WHEN 'SPS' THEN 'em_preparo' WHEN 'READY_TO_PICKUP' THEN 'pronto' WHEN 'RTP' THEN 'pronto' WHEN 'SEPARATION_ENDED' THEN 'pronto' WHEN 'SPE' THEN 'pronto' WHEN 'DISPATCHED' THEN 'despachado' WHEN 'DSP' THEN 'despachado' WHEN 'CONCLUDED' THEN 'concluido' WHEN 'CON' THEN 'concluido' WHEN 'CANCELLED' THEN 'cancelado' WHEN 'CAN' THEN 'cancelado' END;
 IF novo IS NULL THEN
  UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo='Evento iFood requer conferência: '||ev.codigo WHERE empresa_id=p_e AND pedido_id=ev.pedido_id; RETURN;
 END IF;
 IF p.ultimo_evento_em>ev.ocorrido_em OR p.estado_ifood='cancelado' OR (p.estado_ifood='concluido' AND novo<>'cancelado') THEN RETURN; END IF;
 IF novo<>'cancelado' AND array_position(ARRAY['recebido','confirmado','em_preparo','pronto','despachado','concluido'],novo)<array_position(ARRAY['recebido','confirmado','em_preparo','pronto','despachado','concluido'],p.estado_ifood) THEN RETURN; END IF;
 UPDATE private.gastronomia_ifood_pedidos SET estado_ifood=novo,ultimo_evento_em=ev.ocorrido_em,atualizado_em=now() WHERE empresa_id=p_e AND pedido_id=ev.pedido_id;
 UPDATE private.gastronomia_ifood_comandos SET estado='confirmado' WHERE empresa_id=p_e AND pedido_id=p.pedido_id AND acao=CASE novo WHEN 'confirmado' THEN 'confirmar' WHEN 'em_preparo' THEN 'preparar' WHEN 'pronto' THEN 'pronto' WHEN 'despachado' THEN 'despachar' WHEN 'cancelado' THEN 'solicitar_cancelamento' END;
 IF novo IN ('confirmado','em_preparo','pronto','despachado','concluido') AND p.atendimento_id IS NULL THEN a:=private.gastronomia_ifood_importar(p_e,p.pedido_id); ELSE a:=p.atendimento_id; END IF;
 IF a IS NULL THEN RETURN; END IF;
 IF novo IN ('em_preparo','pronto','despachado','concluido') THEN
  UPDATE public.gastronomia_preparo z SET estado=CASE WHEN novo='em_preparo' THEN 'em_preparo' ELSE 'pronto' END,alterado_em=now() FROM public.gastronomia_itens i WHERE z.item_id=i.id AND z.empresa_id=p_e AND i.empresa_id=p_e AND i.atendimento_id=a AND NOT i.cancelado;
 END IF;
 IF novo IN ('pronto','despachado','concluido') THEN
  UPDATE public.gastronomia_atendimentos SET expedicao=CASE WHEN novo='pronto' THEN CASE WHEN tipo='entrega' THEN 'aguardando_despacho' ELSE 'aguardando_retirada' END WHEN novo='despachado' THEN 'saiu_entrega' ELSE CASE WHEN tipo='entrega' THEN 'entregue' ELSE 'retirado' END END,versao=versao+1 WHERE empresa_id=p_e AND id=a;
 END IF;
 IF novo='cancelado' THEN
  -- Dinheiro realmente recebido e documentos fiscais exigem conciliação explícita.
  IF EXISTS(SELECT 1 FROM public.gastronomia_pagamentos WHERE empresa_id=p_e AND atendimento_id=a AND NOT estornado) OR EXISTS(SELECT 1 FROM public.gastronomia_atendimentos WHERE id=a AND venda_id IS NOT NULL) THEN
   UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo='Cancelado no iFood: concilie recebimentos e eventual documento fiscal antes do encerramento local.' WHERE empresa_id=p_e AND pedido_id=p.pedido_id;
   RETURN;
  END IF;
  IF p.estado_ifood IN ('recebido','confirmado') THEN
   FOR r IN SELECT (b->>'produto_baixa_id')::uuid produto,sum((b->>'quantidade')::numeric) quantidade FROM public.gastronomia_itens i CROSS JOIN LATERAL jsonb_array_elements(i.snapshot->'baixas') b WHERE i.empresa_id=p_e AND i.atendimento_id=a AND NOT i.cancelado GROUP BY 1 ORDER BY 1 LOOP
    UPDATE public.produtos SET quantidade_estoque=quantidade_estoque+r.quantidade WHERE empresa_id=p_e AND id=r.produto;
   END LOOP;
  END IF;
  UPDATE public.gastronomia_itens SET cancelado=true WHERE empresa_id=p_e AND atendimento_id=a;
  UPDATE private.gastronomia_ifood_pagamentos SET ativo=false WHERE empresa_id=p_e AND pedido_id=p.pedido_id;
  UPDATE public.gastronomia_atendimentos SET estado='cancelado',finalizado_em=now(),versao=versao+1 WHERE empresa_id=p_e AND id=a;
 END IF;
 INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(p_e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
END $$;
-- Origem e autoria externas explícitas, sem funcionário fictício.
ALTER TABLE public.gastronomia_atendimentos DROP CONSTRAINT gastronomia_atendimentos_origem_check;
ALTER TABLE public.gastronomia_atendimentos ADD CONSTRAINT gastronomia_atendimentos_origem_check CHECK(origem IN ('manual','telefone','whatsapp','site','ifood'));
ALTER TABLE public.gastronomia_atendimentos DROP CONSTRAINT gastronomia_autor_publico_check;
ALTER TABLE public.gastronomia_atendimentos ADD CONSTRAINT gastronomia_autor_publico_check CHECK(criado_por IS NOT NULL OR origem IN ('site','ifood'));
ALTER TABLE public.gastronomia_eventos DROP CONSTRAINT gastronomia_evento_autor_publico_check;
ALTER TABLE public.gastronomia_eventos ADD CONSTRAINT gastronomia_evento_autor_publico_check CHECK(autor IS NOT NULL OR tipo IN ('cardapio_confirmar','ifood_importar','ifood_evento'));
-- Saldo pago no iFood é externo ao caixa físico. Não inserir recebimentos artificiais.
CREATE OR REPLACE FUNCTION private.gastronomia_pago(p_id uuid,p_e uuid) RETURNS numeric LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT coalesce((SELECT sum(valor) FROM public.gastronomia_pagamentos WHERE atendimento_id=p_id AND empresa_id=p_e AND NOT estornado),0)+
 coalesce((SELECT sum(ip.valor_centavos)::numeric/100 FROM private.gastronomia_ifood_pagamentos ip JOIN private.gastronomia_ifood_pedidos p ON p.empresa_id=ip.empresa_id AND p.pedido_id=ip.pedido_id WHERE p.empresa_id=p_e AND p.atendimento_id=p_id AND ip.tipo='ONLINE' AND ip.ativo AND p.estado_ifood<>'cancelado'),0)
$$;
-- O trigger somente impede alterações manuais de pedidos iFood; demais canais não entram neste ramo.
CREATE FUNCTION private.gastronomia_ifood_proteger() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF OLD.origem='ifood' AND auth.uid() IS NOT NULL AND (NEW.cliente_nome IS DISTINCT FROM OLD.cliente_nome OR NEW.tipo IS DISTINCT FROM OLD.tipo OR NEW.desconto IS DISTINCT FROM OLD.desconto OR NEW.acrescimo IS DISTINCT FROM OLD.acrescimo OR NEW.taxa_entrega IS DISTINCT FROM OLD.taxa_entrega OR NEW.expedicao IS DISTINCT FROM OLD.expedicao OR NEW.estado='cancelado') THEN
  RAISE EXCEPTION 'Use as ações do iFood para alterar este pedido.';
 END IF;RETURN NEW;
END $$;
CREATE TRIGGER gastronomia_ifood_proteger BEFORE UPDATE ON public.gastronomia_atendimentos FOR EACH ROW WHEN (OLD.origem='ifood') EXECUTE FUNCTION private.gastronomia_ifood_proteger();
-- Revogar helpers; somente os pontos de entrada autenticados/worker os executam.
REVOKE ALL ON FUNCTION private.gastronomia_ifood_payload(uuid,jsonb),private.gastronomia_ifood_validar_itens(uuid,jsonb),private.gastronomia_ifood_importar(uuid,uuid),private.gastronomia_ifood_evento(uuid,uuid),private.gastronomia_ifood_proteger() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.gastronomia_ifood_painel(p_e uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT jsonb_build_object('empresa_id',p_e,'conectado',coalesce((SELECT habilitada FROM private.gastronomia_ifood_config WHERE empresa_id=p_e),false),
 'pedidos',(SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.criado_em DESC),'[]') FROM (
 SELECT p.pedido_id,p.atendimento_id,p.estado_ifood,p.normalizado,p.revisao_motivo,p.negociacao,p.criado_em,
 (SELECT coalesce(jsonb_agg(jsonb_build_object('acao',acao,'estado',estado)),'[]') FROM private.gastronomia_ifood_comandos WHERE empresa_id=p_e AND pedido_id=p.pedido_id) comandos,
 (SELECT string_agg(erro,'; ') FROM private.gastronomia_ifood_eventos WHERE empresa_id=p_e AND pedido_id=p.pedido_id AND estado='falha') erro
 FROM private.gastronomia_ifood_pedidos p WHERE empresa_id=p_e ORDER BY criado_em DESC LIMIT 100) z))
$$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_painel(uuid) FROM PUBLIC,anon,authenticated;

DO $$ BEGIN IF md5(replace(pg_get_functiondef('private.gastronomia_venda(uuid,uuid)'::regprocedure),chr(13)||chr(10),chr(10)))<>'51043f27af169f13d28ad156aa009104' THEN RAISE EXCEPTION 'Base alterada: private.gastronomia_venda(uuid,uuid)'; END IF; END $$;
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
 SELECT p.id,p_e,v,p.forma,p.valor,row_number() OVER(ORDER BY p.criado_em,p.id),p.criado_por,p.criado_em FROM public.gastronomia_pagamentos p WHERE p.empresa_id=p_e AND p.atendimento_id=p_id AND NOT p.estornado ON CONFLICT(id) DO NOTHING;
 -- O motor existente de taxas lê os pagamentos do núcleo (ramo pdv); nenhum Caixa PDV é usado.
 FOR r IN SELECT p.id,p.metadados FROM public.gastronomia_pagamentos p WHERE p.empresa_id=p_e AND p.atendimento_id=p_id AND NOT p.estornado LOOP
  PERFORM private.taxas_registrar('pdv',r.id,r.metadados);
 END LOOP;
 IF a.origem='ifood' THEN
  INSERT INTO public.vendas_pagamentos(id,empresa_id,venda_id,forma_pagamento,valor,ordem,criado_por)
  SELECT ip.id,p_e,v,CASE ip.forma WHEN 'PIX' THEN 'Pix' WHEN 'CREDIT' THEN 'Cartão de Crédito' WHEN 'DEBIT' THEN 'Cartão de Débito' ELSE 'Outros' END,
   ip.valor_centavos::numeric/100,1000+ip.indice,NULL
  FROM private.gastronomia_ifood_pagamentos ip JOIN private.gastronomia_ifood_pedidos p ON p.empresa_id=ip.empresa_id AND p.pedido_id=ip.pedido_id
  WHERE ip.empresa_id=p_e AND p.atendimento_id=p_id AND ip.tipo='ONLINE' AND ip.ativo AND p.estado_ifood<>'cancelado'
  ON CONFLICT(id) DO NOTHING;
 END IF;
 RETURN v;
END $function$
;

DO $$ BEGIN IF md5(replace(pg_get_functiondef('private.gastronomia_duas_vias(uuid,uuid,uuid,boolean)'::regprocedure),chr(13)||chr(10),chr(10)))<>'536aa180bc44fd1bf01c3e5f913d2507' THEN RAISE EXCEPTION 'Base alterada: private.gastronomia_duas_vias(uuid,uuid,uuid,boolean)'; END IF; END $$;
CREATE OR REPLACE FUNCTION private.gastronomia_duas_vias(p_id uuid, p_e uuid, p_lote uuid, p_reimpressao boolean)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE a public.gastronomia_atendimentos; itens jsonb; emp text; via text; job uuid;
BEGIN
 SELECT * INTO a FROM public.gastronomia_atendimentos WHERE id=p_id AND empresa_id=p_e;
 IF a.origem='ifood' THEN PERFORM private.gastronomia_ifood_imprimir(p_id,p_e,p_lote,p_reimpressao);RETURN;END IF;
 SELECT nome INTO emp FROM public.empresas WHERE id=p_e;
 SELECT jsonb_agg(jsonb_build_object('nome',i.snapshot->>'produto_nome','quantidade',i.quantidade,'preco_unitario',i.preco_unitario,'subtotal',round(i.quantidade*i.preco_unitario,2),'observacao',i.snapshot->>'observacao','filhos',(SELECT coalesce(jsonb_agg(jsonb_build_object('nome',c->>'produto_nome','quantidade',c->'quantidade','grupo',c->>'grupo_nome')),'[]') FROM jsonb_array_elements(i.snapshot->'escolhas_resolvidas') c)) ORDER BY i.criado_em,i.id) INTO itens FROM public.gastronomia_itens i WHERE i.empresa_id=p_e AND i.atendimento_id=p_id AND NOT i.cancelado AND (p_reimpressao OR i.snapshot->>'lote'=p_lote::text);
 IF itens IS NULL THEN RETURN; END IF;
 FOREACH via IN ARRAY ARRAY['COZINHA','CONFERÊNCIA CAIXA'] LOOP
  job:=private.impressao_job_criar(p_e,'caixa','pedido_bar','gastronomia:duas:'||p_lote||':'||via,(CASE WHEN p_reimpressao THEN 'REIMPRESSÃO · ' ELSE '' END)||via||' #'||a.numero,
   jsonb_build_object('gastronomia_atendimento_id',p_id,'gastronomia_impressora_propria',true,'versao',1,'tipo','pedido_bar','empresa',emp||' — '||upper(a.tipo)||' #'||a.numero,'setor',(CASE WHEN p_reimpressao THEN 'REIMPRESSÃO · ' ELSE '' END)||via,'mesa',(SELECT numero FROM public.gastronomia_mesas WHERE empresa_id=p_e AND id=a.mesa_id),'data_hora',to_char(now() AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),'itens',itens||jsonb_build_array(jsonb_build_object('nome',concat_ws(' · ',a.cliente_nome,a.telefone,a.endereco,a.referencia)),jsonb_build_object('nome','PEDIDO NÃO FISCAL — pagamento somente após confirmação do caixa'))),auth.uid());
 END LOOP;
END $function$
;

DO $$ BEGIN IF md5(replace(pg_get_functiondef('public.gastronomia_rpc(text,jsonb,uuid)'::regprocedure),chr(13)||chr(10),chr(10)))<>'385d36647e30bce9c3ae4693d2a7c8a5' THEN RAISE EXCEPTION 'Base alterada: public.gastronomia_rpc(text,jsonb,uuid)'; END IF; END $$;
CREATE OR REPLACE FUNCTION public.gastronomia_rpc(p_acao text, p_dados jsonb DEFAULT '{}'::jsonb, p_chave uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_visualizar'); a public.gastronomia_atendimentos; item public.gastronomia_itens; pg public.gastronomia_pagamentos; req private.gastronomia_requisicoes; autorizacao private.florest_autorizacoes; alvo uuid; resultado jsonb; resolvido jsonb; x jsonb; y jsonb; setores text[]; setor text; iid uuid; cx uuid; n bigint; r record; total numeric; pago numeric; soma numeric; motivo text; permissao text; dados jsonb:=coalesce(p_dados,'{}'); cfg public.gastronomia_configuracoes; novo text;
BEGIN
 IF p_acao='produtos_buscar' THEN
  PERFORM private.gastronomia_exigir('gastronomia_pedidos');
  novo:=nullif(btrim(left(coalesce(dados->>'busca',''),80)),'');
  IF novo IS NULL THEN RETURN jsonb_build_object('itens','[]'::jsonb); END IF;
  -- Mesma semântica de pesquisa do PDV, sem exigir/licenciar o PDV a um operador Gastronomia.
  setor:=CASE WHEN length(novo)=1 THEN '' ELSE '%' END||replace(replace(replace(novo,'\','\\'),'%','\%'),'_','\_')||'%';
  RETURN jsonb_build_object('itens',(SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.exato DESC NULLS LAST,z.nome,z.id),'[]') FROM (SELECT p.id,p.nome,p.codigo,p.gtin,p.referencia,p.preco_venda,bp.id bar_produto_id,coalesce(p.codigo=novo OR p.gtin=novo OR p.referencia=novo,false) exato FROM public.produtos p JOIN private.gastronomia_produtos_operacionais bp ON bp.produto_id=p.id AND bp.empresa_id=e WHERE p.empresa_id=e AND p.ativo AND bp.ativo_cardapio AND (p.nome ILIKE setor OR (length(novo)>1 AND (p.codigo ILIKE setor OR p.gtin ILIKE setor OR p.referencia ILIKE setor)) OR p.codigo=novo OR p.gtin=novo OR p.referencia=novo) ORDER BY (p.codigo=novo OR p.gtin=novo OR p.referencia=novo) DESC NULLS LAST,p.nome,p.id LIMIT 30) z));
 END IF;
 IF p_acao='mesa_consultar' THEN
  SELECT * INTO r FROM public.gastronomia_mesas WHERE empresa_id=e AND id=(dados->>'mesa_id')::uuid AND ativa;
  IF NOT FOUND THEN RAISE EXCEPTION 'Mesa não encontrada.' USING ERRCODE='42501'; END IF;
  SELECT g.id INTO alvo FROM public.gastronomia_atendimentos g WHERE g.empresa_id=e AND g.mesa_id=r.id AND g.estado='aberto';
  RETURN jsonb_build_object('mesa',to_jsonb(r),'atendimento',CASE WHEN alvo IS NOT NULL THEN public.gastronomia_rpc('atendimento_detalhe',jsonb_build_object('id',alvo))#>'{atendimentos,0}' ELSE NULL END);
 END IF;


 IF p_acao='caixa_detalhe' THEN
  PERFORM private.gastronomia_exigir('gastronomia_caixa');
  SELECT id INTO cx FROM public.caixas WHERE id=(dados->>'id')::uuid AND empresa_id=e AND tipo_caixa='GASTRONOMIA';
  IF cx IS NULL THEN RAISE EXCEPTION 'Caixa não encontrado.' USING ERRCODE='42501'; END IF;
  RETURN jsonb_build_object('caixa',(SELECT private.caixa_json(c) FROM public.caixas c WHERE c.id=cx AND c.empresa_id=e),'resumo',(SELECT private.gastronomia_caixa_calcular(c) FROM public.caixas c WHERE c.id=cx AND c.empresa_id=e),'movimentos',(SELECT coalesce(jsonb_agg(to_jsonb(p)||jsonb_build_object('canal',atd.tipo,'numero',atd.numero,'origem',atd.origem,'cliente_nome',atd.cliente_nome,'situacao_atendimento',atd.estado,'total_atendimento',private.gastronomia_total(atd.id,e),'mesa_numero',(SELECT numero FROM public.gastronomia_mesas WHERE id=atd.mesa_id AND empresa_id=e),'numero_venda',(SELECT numero_venda FROM public.vendas WHERE id=atd.venda_id AND empresa_id=e)) ORDER BY p.criado_em),'[]') FROM public.gastronomia_pagamentos p JOIN public.gastronomia_atendimentos atd ON atd.id=p.atendimento_id AND atd.empresa_id=e WHERE p.empresa_id=e AND p.caixa_id=cx));
 END IF;
 IF p_acao IN ('contexto','atendimento_detalhe') THEN
  RETURN jsonb_build_object('mesa_operacao_versao','mesas_20261025_v1','cardapio_versao','cardapio_20261025_v1','interface_versao','gastronomia_20261024_percentual_v1','empresa_id',e,'taxas',CASE WHEN private.perm('gastronomia_caixa') THEN public.taxas_pagamento_obter() ELSE NULL END,'permissoes',(SELECT jsonb_agg(p) FROM unnest(ARRAY['gastronomia_visualizar','gastronomia_mesas','gastronomia_pedidos','gastronomia_producao','gastronomia_expedicao','gastronomia_caixa','gastronomia_configurar','gastronomia_cancelar','gastronomia_estornar']) p WHERE private.perm(p)),
   'configuracao',(SELECT to_jsonb(c) FROM public.gastronomia_configuracoes c WHERE c.empresa_id=e),
   'mesas',(SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.numero),'[]') FROM public.gastronomia_mesas m WHERE m.empresa_id=e AND m.ativa),
   'catalogo',CASE WHEN private.perm('gastronomia_pedidos') OR private.perm('gastronomia_configurar') THEN (SELECT coalesce(jsonb_agg((to_jsonb(p)-'quantidade_estoque'-'estoque_minimo'-'preco_custo')||jsonb_build_object('bar_produto_id',bp.id,'tipo',bp.tipo,'destino',bp.destino_operacional,'ativo_cardapio',bp.ativo_cardapio,'componentes',(SELECT coalesce(jsonb_agg(to_jsonb(c)),'[]') FROM private.gastronomia_componentes_operacionais c WHERE c.bar_produto_id=bp.id AND c.empresa_id=e),'grupos',(SELECT coalesce(jsonb_agg(to_jsonb(g)||jsonb_build_object('opcoes',(SELECT jsonb_agg(to_jsonb(o)||jsonb_build_object('nome',pr.nome,'disponivel',pr.ativo AND (pr.quantidade_estoque>0 OR coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false)))) FROM private.gastronomia_opcoes_operacionais o JOIN public.produtos pr ON pr.id=o.produto_id AND pr.empresa_id=e WHERE o.grupo_id=g.id AND o.empresa_id=e))),'[]') FROM private.gastronomia_grupos_operacionais g WHERE g.bar_produto_id=bp.id AND g.empresa_id=e)) ORDER BY p.nome),'[]') FROM public.produtos p LEFT JOIN private.gastronomia_produtos_operacionais bp ON bp.produto_id=p.id AND bp.empresa_id=e WHERE p.empresa_id=e AND p.ativo) ELSE '[]'::jsonb END,
   'atendimentos',(SELECT coalesce(jsonb_agg(z.doc ORDER BY z.criado_em DESC),'[]') FROM (SELECT a1.criado_em,to_jsonb(a1)||jsonb_build_object('financeiro',private.gastronomia_financeiro_detalhe(a1.id,e),'numero_venda',(SELECT numero_venda FROM public.vendas WHERE id=a1.venda_id AND empresa_id=e),'impressao',private.gastronomia_impressao_estado(a1.id,e),'mesa_numero',(SELECT numero FROM public.gastronomia_mesas WHERE id=a1.mesa_id AND empresa_id=e),'total',private.gastronomia_total(a1.id,e),'pago',private.gastronomia_pago(a1.id,e),'itens',(SELECT coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('autor_nome',(SELECT pf.nome FROM public.perfis pf WHERE pf.id=i.criado_por AND pf.empresa_id=e),'preparo',(SELECT coalesce(jsonb_agg(to_jsonb(pr)),'[]') FROM public.gastronomia_preparo pr WHERE pr.item_id=i.id AND pr.empresa_id=e)) ORDER BY i.criado_em),'[]') FROM public.gastronomia_itens i WHERE i.atendimento_id=a1.id AND i.empresa_id=e),'pagamentos',CASE WHEN private.perm('gastronomia_caixa') OR private.perm('gastronomia_estornar') THEN (SELECT coalesce(jsonb_agg(to_jsonb(p)),'[]') FROM public.gastronomia_pagamentos p WHERE p.atendimento_id=a1.id AND p.empresa_id=e) ELSE '[]'::jsonb END) doc FROM public.gastronomia_atendimentos a1 WHERE a1.empresa_id=e AND (p_acao='contexto' OR a1.id=(dados->>'id')::uuid) ORDER BY (a1.estado='aberto') DESC,a1.criado_em DESC LIMIT 500) z));
 END IF;
 permissao:=CASE p_acao WHEN 'mesa_lancar' THEN 'gastronomia_mesas' WHEN 'mesa_transferir' THEN CASE WHEN private.perm('gastronomia_mesas') THEN 'gastronomia_mesas' ELSE 'gastronomia_caixa' END WHEN 'mesa_relatorio' THEN CASE WHEN private.perm('gastronomia_mesas') THEN 'gastronomia_mesas' ELSE 'gastronomia_caixa' END WHEN 'configurar' THEN 'gastronomia_configurar' WHEN 'foto' THEN 'gastronomia_configurar' WHEN 'criar' THEN CASE WHEN dados->>'tipo'='mesa' THEN 'gastronomia_mesas' ELSE 'gastronomia_pedidos' END WHEN 'adicionar' THEN 'gastronomia_pedidos' WHEN 'preparo' THEN 'gastronomia_producao' WHEN 'expedicao' THEN 'gastronomia_expedicao' WHEN 'receber' THEN 'gastronomia_caixa' WHEN 'ajustar' THEN 'gastronomia_caixa' WHEN 'finalizar' THEN 'gastronomia_caixa' WHEN 'cancelar_item' THEN 'gastronomia_cancelar' WHEN 'cancelar' THEN 'gastronomia_cancelar' WHEN 'estornar' THEN 'gastronomia_estornar' WHEN 'reimprimir' THEN 'gastronomia_pedidos' WHEN 'editar' THEN 'gastronomia_pedidos' WHEN 'corrigir_item' THEN 'gastronomia_cancelar' WHEN 'pronto' THEN 'gastronomia_producao' ELSE NULL END;
 IF permissao IS NULL THEN RAISE EXCEPTION 'Ação inválida.'; END IF;
 PERFORM private.gastronomia_exigir(permissao);
 IF p_chave IS NULL THEN RAISE EXCEPTION 'Identificador da operação obrigatório.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':gastronomia:'||p_chave,0));
 SELECT * INTO req FROM private.gastronomia_requisicoes WHERE empresa_id=e AND chave=p_chave;
 IF FOUND THEN IF req.acao<>p_acao OR req.dados<>dados THEN RAISE EXCEPTION 'Identificador já usado com outro conteúdo.'; END IF; RETURN req.resultado; END IF;
 IF p_acao='mesa_lancar' THEN
  SELECT * INTO r FROM public.gastronomia_mesas WHERE empresa_id=e AND id=(dados->>'mesa_id')::uuid AND ativa FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Mesa não encontrada.' USING ERRCODE='42501'; END IF;
  IF NOT pg_try_advisory_xact_lock(hashtextextended(e::text||':gastronomia:mesa:'||r.id,0)) THEN RAISE EXCEPTION 'Mesa sendo alterada por outro terminal. Atualize e confira.' USING ERRCODE='40001'; END IF;
  IF EXISTS(SELECT 1 FROM public.gastronomia_atendimentos g WHERE g.empresa_id=e AND g.mesa_id=r.id AND g.estado='aberto') THEN RAISE EXCEPTION 'A mesa foi aberta em outro terminal. Reabra a conta existente antes de lançar.' USING ERRCODE='40001'; END IF;
  x:=public.gastronomia_rpc('criar',jsonb_build_object('tipo','mesa','mesa_id',r.id),md5(p_chave::text||':criar')::uuid);
  resultado:=public.gastronomia_rpc('adicionar',jsonb_build_object('id',x->>'id','versao',x->'versao','itens',dados->'itens'),md5(p_chave::text||':adicionar')::uuid);
  alvo:=(resultado->>'id')::uuid;
 ELSIF p_acao='foto' THEN
  IF NOT EXISTS(SELECT 1 FROM public.produtos WHERE id=(dados->>'produto_id')::uuid AND empresa_id=e AND ativo) THEN RAISE EXCEPTION 'Produto não encontrado.' USING ERRCODE='42501'; END IF;
  novo:=coalesce(dados->>'url','');
  IF length(novo)>2000 OR (novo<>'' AND novo !~ '^https://[^[:space:]]+$') THEN RAISE EXCEPTION 'Informe uma URL HTTPS válida para a foto.'; END IF;
  INSERT INTO public.gastronomia_configuracoes(empresa_id) VALUES(e) ON CONFLICT DO NOTHING;
  UPDATE public.gastronomia_configuracoes SET opcoes=jsonb_set(opcoes,'{fotos}',coalesce(opcoes->'fotos','{}')||jsonb_build_object(dados->>'produto_id',novo)) WHERE empresa_id=e;
  resultado:=jsonb_build_object('produto_id',dados->>'produto_id');
 ELSIF p_acao='configurar' THEN
  n:=(dados->>'mesas')::integer;
  IF n IS NULL OR n<0 OR n>500 OR coalesce((dados->>'taxa_entrega')::numeric,0)<0 THEN RAISE EXCEPTION 'Configuração inválida.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':gastronomia:config',0));
  IF EXISTS(SELECT 1 FROM public.gastronomia_atendimentos a1 JOIN public.gastronomia_mesas m ON m.id=a1.mesa_id AND m.empresa_id=e WHERE a1.empresa_id=e AND a1.estado='aberto' AND m.numero>n) THEN RAISE EXCEPTION 'Não é possível desativar mesa ocupada.'; END IF;
  INSERT INTO public.gastronomia_configuracoes(empresa_id,quantidade_mesas,taxa_entrega,imprimir) VALUES(e,n,coalesce((dados->>'taxa_entrega')::numeric,0),true) ON CONFLICT(empresa_id) DO UPDATE SET quantidade_mesas=excluded.quantidade_mesas,taxa_entrega=excluded.taxa_entrega,imprimir=excluded.imprimir;
  IF dados ? 'opcoes' THEN
   x:=dados->'opcoes';
   IF (x ? 'servico_percentual' AND ((x->>'servico_percentual')::numeric IS NULL OR (x->>'servico_percentual')::numeric<0 OR (x->>'servico_percentual')::numeric>100 OR (x->>'servico_percentual')::numeric<>round((x->>'servico_percentual')::numeric,4))) OR jsonb_typeof(x)<>'object' OR octet_length(x::text)>40000 OR coalesce((x->>'taxa_servico')::numeric,0)<0 OR coalesce((x->>'taxa_servico')::numeric,0)>=100000000000 THEN RAISE EXCEPTION 'Configuração complementar inválida.'; END IF;
   UPDATE public.gastronomia_configuracoes SET opcoes=opcoes||jsonb_build_object('servico_percentual',coalesce((x->>'servico_percentual')::numeric,(opcoes->>'servico_percentual')::numeric,0),'taxa_servico_legada',opcoes->'taxa_servico','horarios',left(x->>'horarios',2000),'entrega',coalesce((x->>'entrega')::boolean,true),'retirada',coalesce((x->>'retirada')::boolean,true),'fotos',coalesce(opcoes->'fotos','{}')) WHERE empresa_id=e;
  END IF;
  INSERT INTO public.gastronomia_mesas(empresa_id,numero) SELECT e,generate_series(1,n) ON CONFLICT(empresa_id,numero) DO UPDATE SET ativa=true;
  UPDATE public.gastronomia_mesas SET ativa=false WHERE empresa_id=e AND numero>n;
  resultado:=jsonb_build_object('mesas',n);
 ELSIF p_acao='criar' THEN
  IF dados->>'tipo' NOT IN ('mesa','entrega','retirada') OR dados->>'tipo' IS NULL THEN RAISE EXCEPTION 'Escolha o atendimento.'; END IF;
  IF dados->>'tipo'='mesa' THEN
   SELECT id INTO alvo FROM public.gastronomia_mesas WHERE id=(dados->>'mesa_id')::uuid AND empresa_id=e AND ativa FOR UPDATE;
   IF alvo IS NULL THEN RAISE EXCEPTION 'Mesa não encontrada.'; END IF;
   SELECT numero INTO n FROM public.gastronomia_mesas WHERE id=alvo AND empresa_id=e;
   PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':gastronomia:mesa:'||alvo,0));
   -- Mesas do Bar com o mesmo número pertencem a outra operação.
  ELSE IF length(btrim(coalesce(dados->>'cliente_nome','')))=0 OR length(btrim(coalesce(dados->>'telefone','')))=0 THEN RAISE EXCEPTION 'Informe cliente e telefone.'; END IF; END IF;
  IF dados->>'tipo'='entrega' AND length(btrim(coalesce(dados->>'endereco','')))=0 THEN RAISE EXCEPTION 'Informe o endereço da entrega.'; END IF;
  IF dados->>'cliente_id' IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.clientes WHERE id=(dados->>'cliente_id')::uuid AND empresa_id=e) THEN RAISE EXCEPTION 'Cliente de outra empresa.' USING ERRCODE='42501'; END IF;
  INSERT INTO public.gastronomia_configuracoes(empresa_id) VALUES(e) ON CONFLICT DO NOTHING;
  UPDATE public.gastronomia_configuracoes SET ultimo_numero=ultimo_numero+1 WHERE empresa_id=e RETURNING * INTO cfg;
  INSERT INTO public.gastronomia_atendimentos(empresa_id,numero,tipo,origem,mesa_id,cliente_id,cliente_nome,telefone,endereco,referencia,taxa_entrega,criado_por)
  VALUES(e,cfg.ultimo_numero,dados->>'tipo',coalesce(dados->>'origem','manual'),alvo,(dados->>'cliente_id')::uuid,nullif(btrim(dados->>'cliente_nome'),''),dados->>'telefone',dados->>'endereco',dados->>'referencia',CASE WHEN dados->>'tipo'='entrega' THEN coalesce((dados->>'taxa_entrega')::numeric,cfg.taxa_entrega) ELSE 0 END,auth.uid()) RETURNING * INTO a;
  
  UPDATE public.gastronomia_atendimentos SET servico_regra='percentual_v1',servico_percentual=coalesce((cfg.opcoes->>'servico_percentual')::numeric,0),servico_base=0 WHERE id=a.id AND empresa_id=e;
  PERFORM private.gastronomia_servico_atualizar(a.id,e);
  alvo:=a.id; resultado:=jsonb_build_object('id',a.id,'numero',a.numero,'versao',a.versao);
 ELSE
  alvo:=(dados->>'id')::uuid;
  SELECT * INTO a FROM public.gastronomia_atendimentos WHERE id=alvo AND empresa_id=e FOR UPDATE;
  IF a.origem='ifood' AND p_acao IN ('corrigir_item','cancelar_item','adicionar','corrigir_atendimento','ajustar','pronto','preparo','expedicao','cancelar') THEN RAISE EXCEPTION 'Use as ações do iFood na aba Pedidos para alterar este pedido.'; END IF;
  IF NOT FOUND THEN RAISE EXCEPTION 'Atendimento não encontrado.' USING ERRCODE='42501'; END IF;
  IF (dados->>'versao')::integer IS DISTINCT FROM a.versao THEN RAISE EXCEPTION 'Outro terminal alterou este atendimento. Atualize e confira.' USING ERRCODE='40001'; END IF;
  IF a.estado NOT IN ('aberto','em_ajuste') AND p_acao NOT IN ('estornar','reimprimir','mesa_relatorio') THEN RAISE EXCEPTION 'Atendimento já encerrado.'; END IF;
  IF p_acao IN ('cancelar_item','cancelar','estornar','corrigir_item') THEN
   motivo:=btrim(coalesce(dados->>'motivo','')); IF length(motivo)<3 THEN RAISE EXCEPTION 'Informe o motivo (mínimo 3 caracteres).'; END IF;
   autorizacao:=private.florest_autorizacao_consumir((dados->>'token')::uuid,auth.uid(),CASE WHEN p_acao='estornar' THEN 'gastronomia_estornar' ELSE 'gastronomia_cancelar' END,coalesce((dados->>'item_id')::uuid,(dados->>'pagamento_id')::uuid,alvo),jsonb_build_object('motivo',motivo));
   IF autorizacao.empresa_id IS DISTINCT FROM e OR autorizacao.transacao IS DISTINCT FROM txid_current() THEN RAISE EXCEPTION 'Autorização já utilizada.' USING ERRCODE='42501'; END IF;
   IF EXISTS(SELECT 1 FROM public.documentos_fiscais WHERE empresa_id=e AND venda_id=a.venda_id AND status IN ('processando','autorizada')) THEN RAISE EXCEPTION 'Trate o documento fiscal antes de cancelar ou estornar.'; END IF;
  END IF;
  IF p_acao='mesa_transferir' THEN
   IF a.tipo<>'mesa' OR a.estado<>'aberto' THEN RAISE EXCEPTION 'A transferência exige uma mesa com conta aberta.'; END IF;
   IF (dados->>'mesa_destino_id')::uuid IS NULL OR (dados->>'mesa_destino_id')::uuid=a.mesa_id THEN RAISE EXCEPTION 'Selecione outra mesa disponível.'; END IF;
   -- Mesas físicas em ordem estável; recusar disputa sem esperar por travas em ordem inversa.
   FOR r IN SELECT m.id,m.numero FROM public.gastronomia_mesas m WHERE m.empresa_id=e AND m.id IN (a.mesa_id,(dados->>'mesa_destino_id')::uuid) ORDER BY m.numero FOR UPDATE NOWAIT LOOP
    IF NOT pg_try_advisory_xact_lock(hashtextextended(e::text||':gastronomia:mesa:'||r.id,0)) THEN RAISE EXCEPTION 'Mesa sendo alterada em outro terminal. Atualize e confira.' USING ERRCODE='40001'; END IF;
   END LOOP;
   SELECT jsonb_build_object('id',m.id,'numero',m.numero) INTO x FROM public.gastronomia_mesas m WHERE m.empresa_id=e AND m.id=a.mesa_id;
   SELECT jsonb_build_object('id',m.id,'numero',m.numero) INTO y FROM public.gastronomia_mesas m WHERE m.empresa_id=e AND m.id=(dados->>'mesa_destino_id')::uuid AND m.ativa;
   IF y IS NULL THEN RAISE EXCEPTION 'Mesa de destino indisponível.'; END IF;
   IF EXISTS(SELECT 1 FROM public.gastronomia_atendimentos g WHERE g.empresa_id=e AND g.mesa_id=(y->>'id')::uuid AND g.estado='aberto') THEN RAISE EXCEPTION 'A mesa de destino está ocupada. Não é permitido unir contas.'; END IF;
   UPDATE public.gastronomia_atendimentos SET mesa_id=(y->>'id')::uuid WHERE id=alvo AND empresa_id=e;
  ELSIF p_acao='mesa_relatorio' THEN
   x:=private.gastronomia_mesa_relatorio(alvo,e,p_chave);
  ELSIF p_acao='editar' THEN
   IF a.venda_id IS NOT NULL OR private.gastronomia_pago(alvo,e)>0 OR a.expedicao IN ('saiu_entrega','entregue','retirado') THEN RAISE EXCEPTION 'Pedido pago ou em entrega: trate os recebimentos e as restrições fiscais antes da correção.'; END IF;
   IF a.tipo<>'mesa' AND (length(btrim(coalesce(dados->>'cliente_nome','')))=0 OR length(btrim(coalesce(dados->>'telefone','')))=0) THEN RAISE EXCEPTION 'Informe cliente e telefone.'; END IF;
   IF a.tipo='entrega' AND length(btrim(coalesce(dados->>'endereco','')))=0 THEN RAISE EXCEPTION 'Informe o endereço.'; END IF;
   UPDATE public.gastronomia_atendimentos SET cliente_nome=left(btrim(dados->>'cliente_nome'),160),telefone=left(dados->>'telefone',40),endereco=left(dados->>'endereco',500),referencia=left(dados->>'referencia',300) WHERE id=alvo AND empresa_id=e;
  ELSIF p_acao='corrigir_item' THEN
   IF a.venda_id IS NOT NULL OR private.gastronomia_pago(alvo,e)>0 OR a.expedicao IN ('saiu_entrega','entregue','retirado') THEN RAISE EXCEPTION 'Estorne os recebimentos e trate a venda/fiscal antes de corrigir itens.'; END IF;
   SELECT * INTO item FROM public.gastronomia_itens WHERE id=(dados->>'item_id')::uuid AND atendimento_id=alvo AND empresa_id=e AND NOT cancelado FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Item indisponível.'; END IF;
   total:=(dados->>'quantidade')::numeric;
   IF total IS NULL OR total<=0 OR total>=100000000 OR total<>round(total,4) THEN RAISE EXCEPTION 'Quantidade inválida.'; END IF;
   x:=item.snapshot;
   IF total<>item.quantidade THEN
    -- A base é imutável: nunca consultar a composição atual para devolver/repor o lançamento antigo.
    resolvido:=coalesce(item.snapshot->'correcao_base',jsonb_build_object('quantidade',item.quantidade,'baixas',item.snapshot->'baixas','escolhas_resolvidas',coalesce(item.snapshot->'escolhas_resolvidas','[]')));
    -- Um registro antigo com fração inferior à precisão do estoque não prova a baixa física.
    -- Não adivinhar essa quantidade nem recalcular a receita: exigir conciliação antes de corrigir.
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(resolvido->'baixas') b GROUP BY b->>'produto_baixa_id' HAVING sum((b->>'quantidade')::numeric)<>round(sum((b->>'quantidade')::numeric),4)) THEN RAISE EXCEPTION 'Baixa original com precisão superior ao estoque: concilie o registro físico antes de corrigir a quantidade.'; END IF;
    IF total>item.quantidade AND NOT EXISTS(SELECT 1 FROM public.produtos WHERE id=item.produto_id AND empresa_id=e AND ativo) THEN RAISE EXCEPTION 'Produto inativo: não é possível aumentar o consumo.'; END IF;
    y:='[]'::jsonb;
    FOR r IN
     SELECT b.produto,round(b.qtd*total/(resolvido->>'quantidade')::numeric,4) nova,round(coalesce(c.qtd,0),4) anterior
     FROM (SELECT (b->>'produto_baixa_id')::uuid produto,sum((b->>'quantidade')::numeric) qtd FROM jsonb_array_elements(resolvido->'baixas') b GROUP BY 1) b
     LEFT JOIN (SELECT (b->>'produto_baixa_id')::uuid produto,sum((b->>'quantidade')::numeric) qtd FROM jsonb_array_elements(item.snapshot->'baixas') b GROUP BY 1) c USING(produto)
     ORDER BY b.produto
    LOOP
     PERFORM 1 FROM public.produtos WHERE id=r.produto AND empresa_id=e FOR UPDATE;
     IF NOT FOUND THEN RAISE EXCEPTION 'Produto físico não encontrado.'; END IF;
     IF r.nova>r.anterior AND EXISTS(SELECT 1 FROM public.produtos WHERE id=r.produto AND empresa_id=e AND (NOT ativo OR (quantidade_estoque<r.nova-r.anterior AND NOT coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false)))) THEN RAISE EXCEPTION 'Componente indisponível para aumentar a quantidade.'; END IF;
     UPDATE public.produtos SET quantidade_estoque=quantidade_estoque-(r.nova-r.anterior) WHERE id=r.produto AND empresa_id=e;
     y:=y||jsonb_build_array(jsonb_build_object('produto_baixa_id',r.produto,'quantidade',r.nova));
    END LOOP;
    x:=x||jsonb_build_object('quantidade',total,'correcao_base',resolvido,'baixas',y,'escolhas_resolvidas',(SELECT coalesce(jsonb_agg(b||jsonb_build_object('quantidade',round((b->>'quantidade')::numeric*total/(resolvido->>'quantidade')::numeric,4))),'[]') FROM jsonb_array_elements(resolvido->'escolhas_resolvidas') b));
    UPDATE public.gastronomia_preparo SET estado='novo',autor=auth.uid(),alterado_em=now() WHERE empresa_id=e AND item_id=item.id;
    UPDATE public.gastronomia_atendimentos SET expedicao='pendente' WHERE id=alvo AND empresa_id=e;
   END IF;
   UPDATE public.gastronomia_itens SET quantidade=total,snapshot=jsonb_set(x,'{observacao}',to_jsonb(left(coalesce(dados->>'observacao',item.snapshot->>'observacao',''),150))) WHERE id=item.id AND empresa_id=e;
  ELSIF p_acao='pronto' THEN
   IF NOT EXISTS(SELECT 1 FROM public.gastronomia_itens WHERE atendimento_id=alvo AND empresa_id=e AND NOT cancelado) THEN RAISE EXCEPTION 'Não há itens para preparar.'; END IF;
   UPDATE public.gastronomia_preparo pr SET estado='pronto',autor=auth.uid(),alterado_em=now() FROM public.gastronomia_itens i WHERE pr.item_id=i.id AND pr.empresa_id=e AND i.empresa_id=e AND i.atendimento_id=alvo AND NOT i.cancelado;
   UPDATE public.gastronomia_atendimentos SET expedicao=CASE WHEN tipo='retirada' THEN 'aguardando_retirada' WHEN tipo='entrega' THEN 'aguardando_despacho' ELSE expedicao END WHERE id=alvo AND empresa_id=e AND expedicao='pendente';
  ELSIF p_acao='adicionar' THEN

   IF a.expedicao IN ('saiu_entrega','entregue','retirado') THEN RAISE EXCEPTION 'O pedido já saiu da operação.'; END IF;
   resolvido:=private.gastronomia_resolver(dados->'itens',e);
   FOR x IN SELECT value FROM jsonb_array_elements(resolvido) LOOP
    INSERT INTO public.gastronomia_itens(empresa_id,atendimento_id,produto_id,quantidade,preco_unitario,snapshot,criado_por) VALUES(e,alvo,(x->>'produto_id')::uuid,(x->>'quantidade')::numeric,(x->>'preco_venda')::numeric,x||jsonb_build_object('lote',p_chave),auth.uid()) RETURNING id INTO iid;
    SELECT array_agg(DISTINCT dest) INTO setores FROM (SELECT x->>'destino_operacional' dest UNION SELECT el->>'destino_operacional' FROM jsonb_array_elements(x->'escolhas_resolvidas') el) z WHERE dest IN ('bar','cozinha');
    IF coalesce(array_length(setores,1),0)=0 THEN RAISE EXCEPTION 'Defina o destino de preparo do produto %.',x->>'produto_nome'; END IF;
    FOREACH setor IN ARRAY setores LOOP INSERT INTO public.gastronomia_preparo(empresa_id,item_id,setor) VALUES(e,iid,setor); END LOOP;
   END LOOP;
   UPDATE public.gastronomia_atendimentos SET expedicao='pendente' WHERE id=alvo AND empresa_id=e;
   PERFORM private.gastronomia_imprimir(alvo,e,p_chave);
  ELSIF p_acao='preparo' THEN
   SELECT i.* INTO item FROM public.gastronomia_itens i JOIN public.gastronomia_preparo pr ON pr.item_id=i.id AND pr.empresa_id=e WHERE pr.id=(dados->>'preparo_id')::uuid AND i.atendimento_id=alvo AND i.empresa_id=e AND NOT i.cancelado;
   IF NOT FOUND THEN RAISE EXCEPTION 'Item não disponível para preparo.'; END IF;
   novo:=dados->>'estado';
   UPDATE public.gastronomia_preparo SET estado=novo,autor=auth.uid(),alterado_em=now() WHERE id=(dados->>'preparo_id')::uuid AND empresa_id=e AND ((estado='novo' AND novo='em_preparo') OR (estado='em_preparo' AND novo='pronto'));
   IF NOT FOUND THEN RAISE EXCEPTION 'Transição de preparo inválida.'; END IF;
   IF NOT EXISTS(SELECT 1 FROM public.gastronomia_preparo pr JOIN public.gastronomia_itens i ON i.id=pr.item_id AND i.empresa_id=e WHERE i.atendimento_id=alvo AND pr.empresa_id=e AND NOT i.cancelado AND pr.estado<>'pronto') THEN UPDATE public.gastronomia_atendimentos SET expedicao=CASE WHEN tipo='retirada' THEN 'aguardando_retirada' WHEN tipo='entrega' THEN 'aguardando_despacho' ELSE expedicao END WHERE id=alvo AND empresa_id=e AND expedicao='pendente'; END IF;
  ELSIF p_acao='expedicao' THEN
   IF NOT EXISTS(SELECT 1 FROM public.gastronomia_itens WHERE atendimento_id=alvo AND empresa_id=e AND NOT cancelado) OR EXISTS(SELECT 1 FROM public.gastronomia_preparo pr JOIN public.gastronomia_itens i ON i.id=pr.item_id AND i.empresa_id=e WHERE i.atendimento_id=alvo AND pr.empresa_id=e AND NOT i.cancelado AND pr.estado<>'pronto') THEN RAISE EXCEPTION 'Ainda há itens em preparo.'; END IF;
   novo:=dados->>'estado';
   IF NOT ((a.tipo='mesa' AND a.expedicao='pendente' AND novo='entregue_mesa') OR (a.tipo='retirada' AND ((a.expedicao='pendente' AND novo='aguardando_retirada') OR (a.expedicao='aguardando_retirada' AND novo='retirado'))) OR (a.tipo='entrega' AND ((a.expedicao='pendente' AND novo='aguardando_despacho') OR (a.expedicao='aguardando_despacho' AND novo='saiu_entrega') OR (a.expedicao='saiu_entrega' AND novo='entregue')))) THEN RAISE EXCEPTION 'Transição de expedição inválida.'; END IF;
   IF novo='saiu_entrega' AND length(btrim(coalesce(dados->>'entregador',a.entregador,'')))=0 THEN RAISE EXCEPTION 'Informe o responsável pela entrega.'; END IF;
   UPDATE public.gastronomia_atendimentos SET expedicao=novo,entregador=coalesce(nullif(btrim(dados->>'entregador'),''),entregador) WHERE id=alvo AND empresa_id=e;
  ELSIF p_acao='ajustar' THEN
   IF dados ? 'servico_percentual' THEN
    total:=(dados->>'servico_percentual')::numeric;
    IF total IS NULL OR total<0 OR total>100 OR total<>round(total,4) THEN RAISE EXCEPTION 'Informe a taxa de serviço entre 0 e 100 por cento.'; END IF;
    IF a.venda_id IS NOT NULL OR private.gastronomia_pago(alvo,e)>0 THEN RAISE EXCEPTION 'Atendimento recebido ou consolidado: não alterar a regra de serviço.'; END IF;
    IF dados ? 'taxa_servico' THEN RAISE EXCEPTION 'Informe percentual ou ajuste legado em reais, nunca ambos.'; END IF;
    UPDATE public.gastronomia_atendimentos SET servico_regra='percentual_v1',servico_percentual=total WHERE id=alvo AND empresa_id=e;
   ELSIF a.servico_regra='percentual_v1' AND dados ? 'taxa_servico' THEN RAISE EXCEPTION 'Este atendimento usa serviço percentual. Atualize a interface antes de ajustar.';
   END IF;
   IF a.venda_id IS NOT NULL THEN RAISE EXCEPTION 'Venda consolidada: ajustes exigem o procedimento financeiro/fiscal.'; END IF;
   UPDATE public.gastronomia_atendimentos SET desconto=coalesce((dados->>'desconto')::numeric,desconto),acrescimo=coalesce((dados->>'acrescimo')::numeric,acrescimo),taxa_servico=coalesce((dados->>'taxa_servico')::numeric,taxa_servico),taxa_entrega=CASE WHEN tipo='entrega' THEN coalesce((dados->>'taxa_entrega')::numeric,taxa_entrega) ELSE 0 END WHERE id=alvo AND empresa_id=e;
   IF private.gastronomia_total(alvo,e)<private.gastronomia_pago(alvo,e) OR private.gastronomia_total(alvo,e)<0 THEN RAISE EXCEPTION 'Ajuste deixaria o total menor que o recebido.'; END IF;
  ELSIF p_acao='receber' THEN
   total:=private.gastronomia_total(alvo,e); pago:=private.gastronomia_pago(alvo,e);
   IF jsonb_typeof(dados->'formas') IS DISTINCT FROM 'array' OR jsonb_array_length(dados->'formas') NOT BETWEEN 1 AND 10 THEN RAISE EXCEPTION 'Informe de 1 a 10 pagamentos.'; END IF;
   SELECT sum((v->>'valor')::numeric) INTO soma FROM jsonb_array_elements(dados->'formas') v;
   IF soma IS NULL OR soma<=0 OR soma>total-pago THEN RAISE EXCEPTION 'Valor superior ao saldo ou inválido.'; END IF;
   cx:=private.caixa_exigir_aberto('GASTRONOMIA');
   FOR x IN SELECT value FROM jsonb_array_elements(dados->'formas') LOOP
    IF (x->>'valor')::numeric<>round((x->>'valor')::numeric,2) OR coalesce((x->>'valor')::numeric,0)<=0 THEN RAISE EXCEPTION 'Valor de pagamento inválido.'; END IF;
    INSERT INTO public.gastronomia_pagamentos(empresa_id,atendimento_id,caixa_id,forma,valor,criado_por,metadados) VALUES(e,alvo,cx,x->>'forma_pagamento',(x->>'valor')::numeric,auth.uid(),jsonb_build_object('taxas',x->'taxas'));
   END LOOP;
   PERFORM private.gastronomia_venda(alvo,e);
   IF a.tipo='mesa' AND private.gastronomia_total(alvo,e)>0 AND private.gastronomia_total(alvo,e)=private.gastronomia_pago(alvo,e) THEN
    UPDATE public.gastronomia_atendimentos SET estado='finalizado',finalizado_em=now() WHERE id=alvo AND empresa_id=e;
   END IF;
  ELSIF p_acao='estornar' THEN
   SELECT * INTO pg FROM public.gastronomia_pagamentos WHERE id=(dados->>'pagamento_id')::uuid AND atendimento_id=alvo AND empresa_id=e FOR UPDATE;
   IF NOT FOUND OR pg.estornado THEN RAISE EXCEPTION 'Pagamento indisponível para estorno.'; END IF;
   PERFORM 1 FROM public.caixas WHERE id=pg.caixa_id AND empresa_id=e AND status='aberto' FOR SHARE;
   IF NOT FOUND THEN RAISE EXCEPTION 'O caixa original já foi fechado. Estorno administrativo deve ser tratado separadamente.'; END IF;
   UPDATE public.gastronomia_pagamentos SET estornado=true,estornado_por=auth.uid(),estornado_em=now(),motivo=dados->>'motivo' WHERE id=pg.id AND empresa_id=e;
   -- Registro canônico permanece integral no razão e no evento; a projeção de pagamentos ativos é sincronizada.
   DELETE FROM public.vendas_pagamentos WHERE id=pg.id AND empresa_id=e;
   UPDATE private.taxas_pagamentos SET ativo=false WHERE empresa_id=e AND origem='pdv' AND pagamento_id=pg.id;
   FOR r IN SELECT DISTINCT data FROM private.taxas_pagamentos WHERE empresa_id=e AND origem='pdv' AND pagamento_id=pg.id LOOP PERFORM private.taxas_consolidar(e,r.data); END LOOP;
   UPDATE public.gastronomia_atendimentos SET estado=CASE WHEN estado='finalizado' THEN 'em_ajuste' ELSE estado END,finalizado_em=CASE WHEN estado='finalizado' THEN finalizado_em ELSE NULL END WHERE id=alvo AND empresa_id=e;
  ELSIF p_acao='cancelar_item' THEN
   SELECT * INTO item FROM public.gastronomia_itens WHERE id=(dados->>'item_id')::uuid AND atendimento_id=alvo AND empresa_id=e FOR UPDATE;
   IF NOT FOUND OR item.cancelado THEN RAISE EXCEPTION 'Item não disponível para cancelamento.'; END IF;
   IF item.item_venda_id IS NOT NULL AND private.gastronomia_pago(alvo,e)<>0 THEN RAISE EXCEPTION 'Estorne todos os pagamentos antes de cancelar item de venda consolidada.'; END IF;
   IF private.gastronomia_pago(alvo,e)>private.gastronomia_total(alvo,e)-round(item.quantidade*item.preco_unitario,2) THEN RAISE EXCEPTION 'Estorne os pagamentos excedentes antes de cancelar este item.'; END IF;
   FOR r IN SELECT (b->>'produto_baixa_id')::uuid produto,sum((b->>'quantidade')::numeric) quantidade FROM jsonb_array_elements(item.snapshot->'baixas') b GROUP BY 1 ORDER BY 1 LOOP
    UPDATE public.produtos SET quantidade_estoque=quantidade_estoque+r.quantidade WHERE id=r.produto AND empresa_id=e; IF NOT FOUND THEN RAISE EXCEPTION 'Produto físico não encontrado.'; END IF;
   END LOOP;
   UPDATE public.gastronomia_itens SET cancelado=true WHERE id=item.id AND empresa_id=e;
   IF item.item_venda_id IS NOT NULL THEN DELETE FROM public.itens_venda WHERE id=item.item_venda_id AND empresa_id=e AND venda_id=a.venda_id; END IF;
  ELSIF p_acao='cancelar' THEN
   IF EXISTS(SELECT 1 FROM public.gastronomia_itens WHERE atendimento_id=alvo AND empresa_id=e AND NOT cancelado) OR private.gastronomia_pago(alvo,e)<>0 THEN RAISE EXCEPTION 'Cancele os itens e estorne os pagamentos antes de cancelar o atendimento.'; END IF;
   UPDATE public.gastronomia_atendimentos SET estado='cancelado',finalizado_em=now() WHERE id=alvo AND empresa_id=e;
   IF a.venda_id IS NOT NULL THEN UPDATE public.vendas SET cancelada_em=now(),cancelada_por=auth.uid(),motivo_cancelamento=motivo WHERE id=a.venda_id AND empresa_id=e; END IF;
  ELSIF p_acao='finalizar' THEN
   IF private.gastronomia_total(alvo,e)<=0 OR private.gastronomia_total(alvo,e)<>private.gastronomia_pago(alvo,e) THEN RAISE EXCEPTION 'Quite o saldo antes de encerrar.'; END IF;
   IF a.tipo<>'mesa' AND ((a.tipo='entrega' AND a.expedicao NOT IN ('saiu_entrega','entregue')) OR (a.tipo='retirada' AND a.expedicao<>'retirado')) THEN RAISE EXCEPTION 'Falta confirmar a saída com entregador (entrega) ou a retirada (retirada), após marcar pronto.'; END IF;
   PERFORM private.gastronomia_venda(alvo,e);
   UPDATE public.gastronomia_atendimentos SET estado='finalizado',finalizado_em=now() WHERE id=alvo AND empresa_id=e;
  ELSIF p_acao='reimprimir' THEN PERFORM private.gastronomia_reimprimir(alvo,e,p_chave);
  END IF;
  IF p_acao IN ('adicionar','corrigir_item','cancelar_item','ajustar') THEN
   PERFORM private.gastronomia_servico_atualizar(alvo,e);
   IF private.gastronomia_total(alvo,e)<private.gastronomia_pago(alvo,e) THEN RAISE EXCEPTION 'A alteração deixaria o total menor que o recebido. Regularize os pagamentos antes.'; END IF;
  END IF;
  UPDATE public.gastronomia_atendimentos SET versao=versao+1,atualizado_em=now() WHERE id=alvo AND empresa_id=e RETURNING * INTO a;
  resultado:=jsonb_build_object('id',alvo,'versao',a.versao,'total',private.gastronomia_total(alvo,e),'pago',private.gastronomia_pago(alvo,e),'venda_id',a.venda_id,'estado',a.estado)||CASE WHEN p_acao='mesa_transferir' THEN jsonb_build_object('mesa_origem',x,'mesa_destino',y) WHEN p_acao='mesa_relatorio' THEN jsonb_build_object('relatorio',x) ELSE '{}'::jsonb END;
 END IF;
 INSERT INTO public.gastronomia_eventos(empresa_id,atendimento_id,tipo,autor,autorizador,detalhes) VALUES(e,alvo,p_acao,auth.uid(),autorizacao.autorizador_id,(dados-'token')||jsonb_build_object('resultado',resultado,'item_antes',to_jsonb(item),'pagamento_antes',to_jsonb(pg)));
 INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
 INSERT INTO private.gastronomia_requisicoes(empresa_id,chave,acao,dados,resultado) VALUES(e,p_chave,p_acao,dados,resultado);
 RETURN resultado;
END $function$
;
CREATE FUNCTION private.gastronomia_ifood_imprimir(p_id uuid,p_e uuid,p_lote uuid,p_reimpressao boolean) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE a public.gastronomia_atendimentos; p private.gastronomia_ifood_pedidos; itens jsonb; via text; emp text;
BEGIN
 SELECT * INTO a FROM public.gastronomia_atendimentos WHERE empresa_id=p_e AND id=p_id AND origem='ifood';
 SELECT * INTO p FROM private.gastronomia_ifood_pedidos WHERE empresa_id=p_e AND atendimento_id=p_id;
 IF a.id IS NULL OR p.estado_ifood IN ('recebido','cancelado') THEN RETURN; END IF;
 SELECT nome INTO emp FROM public.empresas WHERE id=p_e;
 SELECT jsonb_agg(jsonb_build_object('nome',i.snapshot->>'produto_nome','quantidade',i.quantidade,'preco_unitario',i.preco_unitario,'subtotal',round(i.quantidade*i.preco_unitario,2),'observacao',i.snapshot->>'observacao','filhos',(SELECT coalesce(jsonb_agg(jsonb_build_object('nome',v->>'produto_nome','quantidade',v->'quantidade','grupo',v->>'grupo_nome')),'[]') FROM jsonb_array_elements(i.snapshot->'escolhas_resolvidas') v)) ORDER BY i.criado_em,i.id) INTO itens FROM public.gastronomia_itens i WHERE i.empresa_id=p_e AND i.atendimento_id=p_id AND NOT i.cancelado;
 IF itens IS NULL THEN RETURN; END IF;
 FOREACH via IN ARRAY ARRAY['COZINHA','CONFERÊNCIA CAIXA'] LOOP
  PERFORM private.impressao_job_criar(p_e,'caixa','pedido_bar','gastronomia:ifood:'||p_lote||':'||via,(CASE WHEN p_reimpressao THEN 'REIMPRESSÃO · ' ELSE '' END)||'IFOOD '||via||' #'||a.numero,
  jsonb_build_object('gastronomia_atendimento_id',p_id,'gastronomia_impressora_propria',true,'versao',1,'tipo','pedido_bar','empresa',emp||' — IFOOD #'||coalesce(p.normalizado->>'numero',a.numero::text),'setor',via,'data_hora',to_char(now() AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),'itens',itens||jsonb_build_array(
   jsonb_build_object('nome','Cliente: '||coalesce(a.cliente_nome,'Cliente iFood')),
   jsonb_build_object('nome','Pago no iFood: R$ '||to_char(p.pago_online_centavos::numeric/100,'FM999999990.00')),
   jsonb_build_object('nome','A cobrar na entrega/retirada: R$ '||to_char(p.a_cobrar_centavos::numeric/100,'FM999999990.00')),
   jsonb_build_object('nome','PEDIDO NÃO FISCAL — valores online não são dinheiro na gaveta'))),auth.uid());
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_imprimir(uuid,uuid,uuid,boolean) FROM PUBLIC,anon,authenticated;
-- Não disparar mensagens externas automáticas do cardápio para consumidores do iFood.
CREATE FUNCTION private.gastronomia_ifood_whatsapp_guard() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN IF EXISTS(SELECT 1 FROM public.gastronomia_atendimentos WHERE empresa_id=NEW.empresa_id AND id=NEW.atendimento_id AND origem='ifood') THEN RETURN NULL;END IF;RETURN NEW;END $$;
CREATE TRIGGER gastronomia_ifood_whatsapp_guard BEFORE INSERT ON private.gastronomia_whatsapp FOR EACH ROW EXECUTE FUNCTION private.gastronomia_ifood_whatsapp_guard();
REVOKE ALL ON FUNCTION private.gastronomia_ifood_whatsapp_guard() FROM PUBLIC,anon,authenticated;
NOTIFY pgrst,'reload schema';

-- PROPOSTA LOCAL. Não aplicada em produção. Não substitui nenhuma função existente.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $guard$ BEGIN
 IF to_regclass('private.mesas_pagamentos_produtos') IS NOT NULL OR to_regprocedure('public.mesas_pagamento_produtos(text,text,uuid,jsonb,uuid)') IS NOT NULL THEN RAISE EXCEPTION 'Discriminação já instalada. Não reinstalar.'; END IF;
 IF md5(pg_get_functiondef('public.bar_comanda_pagar_valor(uuid,numeric,jsonb,uuid,numeric,numeric,numeric)'::regprocedure))<>'e3701d39eedc890f8d732bcf9aef4285' THEN RAISE EXCEPTION 'Base alterada: bar_comanda_pagar_valor. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.bar_comanda_saldo_calcular(uuid,uuid)'::regprocedure))<>'4094ea7f3b253313c70b54f3a639a586' THEN RAISE EXCEPTION 'Base alterada: bar_comanda_saldo_calcular. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.bar_reabertura_guardar(uuid,uuid)'::regprocedure))<>'82d76103ef6541d22f03b92f91caa13c' THEN RAISE EXCEPTION 'Base alterada: bar_reabertura_guardar. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.bar_historico_mesa_editar(uuid,text,jsonb,text,uuid)'::regprocedure))<>'34ae2fabd3efa44ee2b96c2ca2a6d4f7' THEN RAISE EXCEPTION 'Base alterada: bar_historico_mesa_editar. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.bar_pagamento_estornar(uuid,text)'::regprocedure))<>'718a325f91fd4cf8e3390c6d31f7b718' THEN RAISE EXCEPTION 'Base alterada: bar_pagamento_estornar. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('public.gastronomia_rpc(text,jsonb,uuid)'::regprocedure))<>'7b65e1391ea24072c8adef7405497630' THEN RAISE EXCEPTION 'Base alterada: gastronomia_rpc. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.gastronomia_total(uuid,uuid)'::regprocedure))<>'4f732bd39dad446bf9e936c374e62696' THEN RAISE EXCEPTION 'Base alterada: gastronomia_total. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.gastronomia_pago(uuid,uuid)'::regprocedure))<>'1c520b6f641bf5538ddc606984bbd526' THEN RAISE EXCEPTION 'Base alterada: gastronomia_pago. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.gastronomia_venda(uuid,uuid)'::regprocedure))<>'57df757a5dcfb06c1606596e71c2512e' THEN RAISE EXCEPTION 'Base alterada: gastronomia_venda. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.gastronomia_exigir(text)'::regprocedure))<>'25085094e6f8ba6735d892f8aec4c5be' THEN RAISE EXCEPTION 'Base alterada: gastronomia_exigir. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.caixa_exigir_aberto(text)'::regprocedure))<>'c8b913b434d6ebc942c6cf0fbf12da12' THEN RAISE EXCEPTION 'Base alterada: caixa_exigir_aberto. Não remover esta proteção.'; END IF;
 IF md5(pg_get_functiondef('private.gastronomia_caixa_calcular(caixas)'::regprocedure))<>'a4df431635b66dcabb2f777f6f92c077' THEN RAISE EXCEPTION 'Base alterada: gastronomia_caixa_calcular. Não remover esta proteção.'; END IF;
END $guard$;
-- Proposta local: discriminação informativa de UM recebimento existente por operação.
CREATE TABLE private.mesas_pagamentos_produtos (
 empresa_id uuid NOT NULL REFERENCES public.empresas(id),
 modulo text NOT NULL CHECK(modulo IN ('bar','gastronomia')),
 atendimento_id uuid NOT NULL,
 bar_pagamento_id uuid, gastronomia_pagamento_id uuid,
 pagamento_id uuid GENERATED ALWAYS AS(coalesce(bar_pagamento_id,gastronomia_pagamento_id)) STORED,
 chave uuid NOT NULL, autor uuid NOT NULL, pedido jsonb NOT NULL, resultado jsonb NOT NULL,
 valor numeric(14,2) NOT NULL CHECK(valor>0), itens jsonb NOT NULL,
 criado_em timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(empresa_id,modulo,pagamento_id), UNIQUE(empresa_id,modulo,chave),
 CHECK((modulo='bar' AND bar_pagamento_id IS NOT NULL AND gastronomia_pagamento_id IS NULL) OR
       (modulo='gastronomia' AND gastronomia_pagamento_id IS NOT NULL AND bar_pagamento_id IS NULL)),
 CHECK(jsonb_typeof(itens)='array' AND jsonb_array_length(itens) BETWEEN 1 AND 200),
 FOREIGN KEY(empresa_id,bar_pagamento_id) REFERENCES public.bar_pagamentos(empresa_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(empresa_id,gastronomia_pagamento_id) REFERENCES public.gastronomia_pagamentos(empresa_id,id) ON DELETE RESTRICT
);
CREATE INDEX mesas_pagamentos_produtos_conta ON private.mesas_pagamentos_produtos(empresa_id,modulo,atendimento_id);
ALTER TABLE private.mesas_pagamentos_produtos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.mesas_pagamentos_produtos FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.mesas_produtos_recebimentos(p_modulo text,p_conta uuid,p_e uuid)
RETURNS TABLE(id uuid,valor numeric,forma text,estornado boolean,itens jsonb)
LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT d.pagamento_id,d.valor,
 CASE WHEN d.modulo='bar' THEN (SELECT string_agg(f.forma_pagamento,' + ' ORDER BY f.id) FROM public.bar_pagamentos_formas f WHERE f.empresa_id=p_e AND f.pagamento_id=d.pagamento_id) ELSE gp.forma END,
 CASE WHEN d.modulo='bar' THEN bp.estornado ELSE gp.estornado END,d.itens
 FROM private.mesas_pagamentos_produtos d
 LEFT JOIN public.bar_pagamentos bp ON d.modulo='bar' AND bp.empresa_id=d.empresa_id AND bp.id=d.bar_pagamento_id AND bp.comanda_id=d.atendimento_id
 LEFT JOIN public.gastronomia_pagamentos gp ON d.modulo='gastronomia' AND gp.empresa_id=d.empresa_id AND gp.id=d.gastronomia_pagamento_id AND gp.atendimento_id=d.atendimento_id
 WHERE d.empresa_id=p_e AND d.modulo=p_modulo AND d.atendimento_id=p_conta
 AND (bp.id IS NOT NULL OR gp.id IS NOT NULL)
$$;
REVOKE ALL ON FUNCTION private.mesas_produtos_recebimentos(text,uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.mesas_produtos_saldos(p_modulo text,p_conta uuid,p_e uuid)
RETURNS TABLE(item_id uuid,nome text,bruto numeric,limite numeric,pago numeric,pendente numeric,cancelado boolean,legado boolean)
LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE total numeric;
BEGIN
 IF p_modulo='bar' THEN SELECT s.total_final INTO total FROM private.bar_comanda_saldo_calcular(p_conta,p_e) s;
 ELSIF p_modulo='gastronomia' THEN total:=private.gastronomia_total(p_conta,p_e);
 ELSE RAISE EXCEPTION 'Módulo inválido.'; END IF;
 total:=greatest(0,round(total,2))*100;
 RETURN QUERY WITH originais AS (
  SELECT i.id,coalesce(p.nome,'Produto') nome,round(i.quantidade*i.preco_unitario,2) bruto,i.estornado cancelado,i.pagamento_id IS NOT NULL legado
  FROM public.bar_pedidos_itens i JOIN public.produtos p ON p.id=i.produto_id AND p.empresa_id=i.empresa_id
  WHERE p_modulo='bar' AND i.empresa_id=p_e AND i.comanda_id=p_conta
  UNION ALL
  SELECT i.id,coalesce(i.snapshot->>'produto_nome',p.nome,'Produto'),round(i.quantidade*i.preco_unitario,2),i.cancelado,false
  FROM public.gastronomia_itens i JOIN public.produtos p ON p.id=i.produto_id AND p.empresa_id=i.empresa_id
  WHERE p_modulo='gastronomia' AND i.empresa_id=p_e AND i.atendimento_id=p_conta
 ), pesos AS (
  SELECT o.*,CASE WHEN NOT o.cancelado AND o.bruto>0 THEN o.bruto ELSE 0 END peso FROM originais o
 ), exatos AS (
  SELECT p.*,coalesce(total*p.peso/nullif(sum(p.peso) OVER(),0),0) centavos_exatos FROM pesos p
 ), pisos AS (
  SELECT x.*,floor(x.centavos_exatos) piso,row_number() OVER(ORDER BY (x.centavos_exatos-floor(x.centavos_exatos)) DESC,x.id) pos FROM exatos x
 ), limites AS (
  SELECT x.*,CASE WHEN x.cancelado OR x.peso=0 THEN 0 ELSE (x.piso+CASE WHEN x.pos<=total-sum(x.piso) OVER() THEN 1 ELSE 0 END)/100 END teto FROM pisos x
 ), pagos AS (
  SELECT (j->>'item_id')::uuid item,sum((j->>'valor')::numeric) quantia
  FROM private.mesas_produtos_recebimentos(p_modulo,p_conta,p_e) r CROSS JOIN LATERAL jsonb_array_elements(r.itens) j
  WHERE NOT r.estornado GROUP BY (j->>'item_id')::uuid
 )
 SELECT x.id,x.nome,x.bruto,x.teto,coalesce(p.quantia,0),greatest(x.teto-coalesce(p.quantia,0),0),x.cancelado,x.legado
 FROM limites x LEFT JOIN pagos p ON p.item=x.id ORDER BY x.id;
END $$;
REVOKE ALL ON FUNCTION private.mesas_produtos_saldos(text,uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.mesas_pagamento_produtos(p_modulo text,p_acao text,p_atendimento_id uuid,p_dados jsonb DEFAULT '{}',p_chave uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='5s' AS $$
DECLARE e uuid:=private.exigir_empresa_ativa(); c public.bar_comandas; a public.gastronomia_atendimentos;
 d private.mesas_pagamentos_produtos; s record; soma numeric; saldo numeric; recebidos numeric; itens jsonb; selecionados jsonb; pedido jsonb:=coalesce(p_dados,'{}');
 resultado jsonb; pag uuid; antes uuid[]; novo uuid[]; formas jsonb; total numeric; r record;
BEGIN
 IF p_modulo IS NULL OR p_acao IS NULL OR p_modulo NOT IN ('bar','gastronomia') OR p_acao NOT IN ('consultar','receber') THEN RAISE EXCEPTION 'Operação inválida.'; END IF;
 IF p_modulo='bar' THEN
  IF NOT private.empresa_tem_modulo('bar') OR NOT private.perm_alguma(ARRAY['bar_visualizar','bar_mesas','bar_caixa','bar_estornar_pagamento','bar_historico_detalhar']) THEN RAISE EXCEPTION 'Sem permissão no Bar.' USING ERRCODE='42501'; END IF;
  SELECT * INTO c FROM public.bar_comandas WHERE id=p_atendimento_id AND empresa_id=e;
  IF c.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada.' USING ERRCODE='42501'; END IF;
 ELSE
  PERFORM private.gastronomia_exigir('gastronomia_visualizar');
  SELECT * INTO a FROM public.gastronomia_atendimentos WHERE id=p_atendimento_id AND empresa_id=e AND tipo='mesa';
  IF a.id IS NULL THEN RAISE EXCEPTION 'Somente atendimento de mesa desta empresa.' USING ERRCODE='42501'; END IF;
 END IF;
 IF p_acao='receber' THEN
  IF p_modulo='bar' AND NOT private.perm('bar_caixa') THEN RAISE EXCEPTION 'Sem permissão para receber no Bar.' USING ERRCODE='42501'; END IF;
  IF p_modulo='gastronomia' THEN PERFORM private.gastronomia_exigir('gastronomia_caixa'); END IF;
  IF p_chave IS NULL THEN RAISE EXCEPTION 'Chave da operação obrigatória.'; END IF;
  -- Serializa também o mesmo identificador em contas diferentes; sem movimentação parcial.
  PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':mesas-produtos:'||p_modulo||':'||p_chave::text,0));
  SELECT * INTO d FROM private.mesas_pagamentos_produtos WHERE empresa_id=e AND modulo=p_modulo AND chave=p_chave;
  IF FOUND THEN
   IF d.autor IS DISTINCT FROM auth.uid() OR d.atendimento_id IS DISTINCT FROM p_atendimento_id OR d.pedido IS DISTINCT FROM pedido THEN RAISE EXCEPTION 'Chave já usada com outro conteúdo ou operador.'; END IF;
   RETURN d.resultado;
  END IF;
  IF p_modulo='bar' THEN
   PERFORM 1 FROM public.bar_mesas WHERE id=c.mesa_id AND empresa_id=e FOR UPDATE NOWAIT;
   SELECT * INTO c FROM public.bar_comandas WHERE id=p_atendimento_id AND empresa_id=e FOR UPDATE NOWAIT;
   IF c.status<>'aberta' THEN RAISE EXCEPTION 'Comanda não está aberta.'; END IF;
   IF EXISTS(SELECT 1 FROM public.bar_pagamentos WHERE empresa_id=e AND idempotencia_key=p_chave) THEN RAISE EXCEPTION 'Chave já utilizada por outro recebimento.'; END IF;
  ELSE
   SELECT * INTO a FROM public.gastronomia_atendimentos WHERE id=p_atendimento_id AND empresa_id=e FOR UPDATE NOWAIT;
   IF a.tipo<>'mesa' OR a.estado NOT IN ('aberto','em_ajuste') THEN RAISE EXCEPTION 'Mesa indisponível para receber.'; END IF;
   IF pedido->>'id' IS DISTINCT FROM p_atendimento_id::text THEN RAISE EXCEPTION 'Atendimento da solicitação não corresponde à mesa.'; END IF;
   IF EXISTS(SELECT 1 FROM private.gastronomia_requisicoes WHERE empresa_id=e AND chave=p_chave) THEN RAISE EXCEPTION 'Chave já utilizada por outra operação.'; END IF;
  END IF;
 END IF;
 IF p_modulo='bar' THEN SELECT calc.total_final,calc.total_pago,calc.saldo INTO total,recebidos,saldo FROM private.bar_comanda_saldo_calcular(p_atendimento_id,e) calc;
 ELSE total:=private.gastronomia_total(p_atendimento_id,e);recebidos:=private.gastronomia_pago(p_atendimento_id,e);saldo:=total-recebidos; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.item_id),'[]') INTO itens FROM private.mesas_produtos_saldos(p_modulo,p_atendimento_id,e) x;
 IF p_acao='consultar' THEN
  RETURN jsonb_build_object('empresa_id',e,'modulo',p_modulo,'atendimento_id',p_atendimento_id,'saldo_financeiro',greatest(saldo,0),'total',total,
   'sem_discriminacao',recebidos-coalesce((SELECT sum(x.valor) FROM private.mesas_produtos_recebimentos(p_modulo,p_atendimento_id,e) x WHERE NOT x.estornado),0),
   'habilitado',NOT EXISTS(SELECT 1 FROM jsonb_array_elements(itens) x WHERE (x->>'legado')::boolean),
   'itens',itens,'recebimentos',(SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM private.mesas_produtos_recebimentos(p_modulo,p_atendimento_id,e) x));
 END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(itens) x WHERE (x->>'legado')::boolean) THEN RAISE EXCEPTION 'Conta com pagamento legado por itens: use o recebimento existente, sem conversão automática.'; END IF;
 selecionados:=pedido->'produtos_selecionados';
 IF jsonb_typeof(selecionados) IS DISTINCT FROM 'array' OR jsonb_array_length(selecionados) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'Selecione de 1 a 200 lançamentos.'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(selecionados) x(item_id uuid,valor numeric) WHERE x.item_id IS NULL OR x.valor IS NULL OR x.valor<=0 OR x.valor<>round(x.valor,2))
 OR (SELECT count(*) FROM jsonb_to_recordset(selecionados) x(item_id uuid,valor numeric))<>(SELECT count(DISTINCT x.item_id) FROM jsonb_to_recordset(selecionados) x(item_id uuid,valor numeric))
 THEN RAISE EXCEPTION 'Lançamentos repetidos ou valores inválidos.'; END IF;
 FOR r IN SELECT * FROM jsonb_to_recordset(selecionados) x(item_id uuid,valor numeric) LOOP
  SELECT x.* INTO s FROM jsonb_to_recordset(itens) x(item_id uuid,nome text,pendente numeric,cancelado boolean) WHERE x.item_id=r.item_id;
  IF NOT FOUND OR s.cancelado OR r.valor>s.pendente THEN RAISE EXCEPTION 'Lançamento indisponível ou valor superior ao saldo do produto. Atualize a mesa.' USING ERRCODE='40001'; END IF;
 END LOOP;
 SELECT sum(x.valor) INTO soma FROM jsonb_to_recordset(selecionados) x(item_id uuid,valor numeric);
 IF soma>saldo OR soma<=0 THEN RAISE EXCEPTION 'Valor superior ao saldo financeiro da mesa.'; END IF;
 formas:=pedido->'formas';
 IF jsonb_typeof(formas) IS DISTINCT FROM 'array' OR jsonb_array_length(formas) NOT BETWEEN 1 AND 10 THEN RAISE EXCEPTION 'Forma de pagamento inválida.'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(formas) x(valor numeric) WHERE x.valor IS NULL OR x.valor<=0 OR x.valor<>round(x.valor,2))
 OR (SELECT sum(x.valor) FROM jsonb_to_recordset(formas) x(valor numeric)) IS DISTINCT FROM soma THEN RAISE EXCEPTION 'A soma dos produtos deve ser exatamente igual ao recebimento.'; END IF;
 -- Uma linha informativa por lançamento; nenhum preço/quantidade original é alterado.
 SELECT jsonb_agg(jsonb_build_object('item_id',x.item_id,'nome',y->>'nome','valor',x.valor) ORDER BY x.item_id) INTO selecionados
 FROM jsonb_to_recordset(selecionados) x(item_id uuid,valor numeric) JOIN jsonb_array_elements(itens) y ON (y->>'item_id')::uuid=x.item_id;
 IF p_modulo='bar' THEN
  IF pedido->>'valor' IS NOT NULL AND (pedido->>'valor')::numeric IS DISTINCT FROM soma THEN RAISE EXCEPTION 'Valor recebido diverge da seleção.'; END IF;
  SELECT * INTO r FROM public.bar_comanda_pagar_valor(p_atendimento_id,soma,formas,p_chave,(pedido->>'desconto')::numeric,(pedido->>'acrescimo')::numeric,(pedido->>'taxa_servico')::numeric);
  pag:=r.pagamento_id;resultado:=jsonb_build_array(to_jsonb(r));
 ELSE
  IF jsonb_array_length(formas)<>1 THEN RAISE EXCEPTION 'Seleção de produtos utiliza uma forma por recebimento; o fluxo existente de outras operações permanece disponível.'; END IF;
  SELECT coalesce(array_agg(p.id),'{}') INTO antes FROM public.gastronomia_pagamentos p WHERE p.empresa_id=e AND p.atendimento_id=p_atendimento_id;
  resultado:=public.gastronomia_rpc('receber',pedido-'produtos_selecionados',p_chave);
  SELECT array_agg(p.id) INTO novo FROM public.gastronomia_pagamentos p WHERE p.empresa_id=e AND p.atendimento_id=p_atendimento_id AND NOT(p.id=ANY(antes));
  IF coalesce(array_length(novo,1),0)<>1 THEN RAISE EXCEPTION 'Não foi identificado um único recebimento; operação revertida.'; END IF;
  pag:=novo[1];
 END IF;
 IF (p_modulo='bar' AND NOT EXISTS(SELECT 1 FROM public.bar_pagamentos p WHERE p.id=pag AND p.empresa_id=e AND p.comanda_id=p_atendimento_id AND NOT p.estornado AND p.total=soma))
 OR (p_modulo='gastronomia' AND NOT EXISTS(SELECT 1 FROM public.gastronomia_pagamentos p WHERE p.id=pag AND p.empresa_id=e AND p.atendimento_id=p_atendimento_id AND NOT p.estornado AND p.valor=soma))
 THEN RAISE EXCEPTION 'Recebimento não corresponde à conta ou ao valor; discriminação recusada.'; END IF;
 -- Revalida também depois de ajustes do recebimento: erro desfaz o motor financeiro e seus efeitos.
 FOR r IN SELECT * FROM jsonb_to_recordset(selecionados) x(item_id uuid,valor numeric) LOOP
  SELECT x.* INTO s FROM private.mesas_produtos_saldos(p_modulo,p_atendimento_id,e) x WHERE x.item_id=r.item_id;
  IF NOT FOUND OR s.cancelado OR r.valor>s.pendente THEN RAISE EXCEPTION 'Ajustes da conta mudaram o saldo dos produtos; operação integralmente revertida.'; END IF;
 END LOOP;
 INSERT INTO private.mesas_pagamentos_produtos(empresa_id,modulo,atendimento_id,bar_pagamento_id,gastronomia_pagamento_id,chave,autor,pedido,resultado,valor,itens)
 VALUES(e,p_modulo,p_atendimento_id,CASE WHEN p_modulo='bar' THEN pag END,CASE WHEN p_modulo='gastronomia' THEN pag END,p_chave,auth.uid(),pedido,resultado,soma,selecionados);
 RETURN resultado;
END $$;
REVOKE ALL ON FUNCTION public.mesas_pagamento_produtos(text,text,uuid,jsonb,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mesas_pagamento_produtos(text,text,uuid,jsonb,uuid) TO authenticated;

COMMIT;

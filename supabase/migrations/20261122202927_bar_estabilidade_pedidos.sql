SET LOCAL lock_timeout='2s';
DO $guard$ BEGIN
 IF md5(pg_get_functiondef('public.bar_comanda_pagar(uuid,uuid[],jsonb,numeric,numeric,numeric,integer)'::regprocedure))<>'9e05c406fcf57914d1d5e532abf5b88b' THEN RAISE EXCEPTION 'Base alterada: bar_comanda_pagar'; END IF;
 IF md5(pg_get_functiondef('public.bar_comanda_pagar_valor(uuid,numeric,jsonb,uuid,numeric,numeric,numeric)'::regprocedure))<>'e3701d39eedc890f8d732bcf9aef4285' THEN RAISE EXCEPTION 'Base alterada: bar_comanda_pagar_valor'; END IF;
 IF md5(pg_get_functiondef('public.bar_pagamento_estornar(uuid,text)'::regprocedure))<>'718a325f91fd4cf8e3390c6d31f7b718' THEN RAISE EXCEPTION 'Base alterada: bar_pagamento_estornar'; END IF;
 IF md5(pg_get_functiondef('public.bar_pedido_enviar(uuid,jsonb,uuid)'::regprocedure))<>'17b6223851911ff2d4ff11c7a564aa81' THEN RAISE EXCEPTION 'Base alterada: bar_pedido_enviar'; END IF;
 IF md5(pg_get_functiondef('public.bar_pedido_lancar(uuid,jsonb,uuid)'::regprocedure))<>'2c373dd8fdb16b62d800966696ec31fc' THEN RAISE EXCEPTION 'Base alterada: bar_pedido_lancar'; END IF;
END $guard$;
-- Um snapshot tipado em memória substitui DDL temporário a cada pedido.
CREATE TYPE private.bar_itens_pedido_linha AS (
 ordem bigint,bar_produto_id uuid,quantidade numeric,observacao text,escolhas jsonb,
 produto_id uuid,tipo text,destino_operacional text,ativo_cardapio boolean,
 preco_venda numeric,produto_nome text,usa_grupos boolean);
CREATE TYPE private.bar_escolha_pedido_linha AS (
 ordem integer,grupo_id uuid,grupo_nome text,produto_id uuid,produto_nome text,
 destino_operacional text,quantidade numeric(12,4));
CREATE TYPE private.bar_baixa_pedido_linha AS (
 ordem bigint,produto_baixa_id uuid,quantidade numeric);

CREATE TABLE private.bar_envios (
 empresa_id uuid NOT NULL REFERENCES public.empresas(id) ON DELETE CASCADE,
 chave uuid NOT NULL,mesa_id uuid NOT NULL,itens jsonb NOT NULL,resultado jsonb NOT NULL,
 criado_em timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(empresa_id,chave));
ALTER TABLE private.bar_envios ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.bar_envios FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.bar_travar_mesa_da_comanda(p_comanda uuid,p_empresa uuid)
RETURNS void LANGUAGE plpgsql SET search_path TO '' AS $function$
DECLARE alvo uuid; atual uuid;
BEGIN
 SELECT mesa_id INTO alvo FROM public.bar_comandas WHERE id=p_comanda AND empresa_id=p_empresa;
 IF NOT FOUND OR alvo IS NULL THEN RETURN; END IF;
 PERFORM 1 FROM public.bar_mesas WHERE id=alvo AND empresa_id=p_empresa FOR UPDATE;
 SELECT mesa_id INTO atual FROM public.bar_comandas WHERE id=p_comanda AND empresa_id=p_empresa;
 IF atual IS DISTINCT FROM alvo THEN
  RAISE EXCEPTION 'A mesa mudou durante a operação. Atualize e tente novamente.' USING ERRCODE='40001';
 END IF;
END $function$;
REVOKE ALL ON FUNCTION private.bar_travar_mesa_da_comanda(uuid,uuid) FROM PUBLIC,anon,authenticated;

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
  v_itens private.bar_itens_pedido_linha[];
  v_escolhas private.bar_escolha_pedido_linha[] := ARRAY[]::private.bar_escolha_pedido_linha[];
  v_baixas private.bar_baixa_pedido_linha[];
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

  PERFORM private.bar_travar_mesa_da_comanda(p_comanda_id,v_empresa);
  select * into v_comanda from public.bar_comandas
   where id = p_comanda_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Comanda não encontrada.';
  end if;
  SELECT id INTO v_existente FROM public.bar_pedidos WHERE empresa_id=v_empresa AND idempotencia_key=p_idempotencia;
  IF v_existente IS NOT NULL THEN
    pedido_id:=v_existente;
    SELECT count(*) INTO itens_criados FROM public.bar_pedidos_itens i WHERE i.pedido_id=v_existente AND i.empresa_id=v_empresa;
    RETURN NEXT; RETURN;
  END IF;
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
  SELECT coalesce(array_agg(ROW(t.*)::private.bar_itens_pedido_linha),ARRAY[]::private.bar_itens_pedido_linha[])
  INTO v_itens FROM (
  select x.ordem, x.bar_produto_id, round(x.quantidade, 4) as quantidade,
         nullif(btrim(coalesce(x.observacao, '')), '') as observacao, x.escolhas,
         bp.produto_id, bp.tipo, bp.destino_operacional, bp.ativo_cardapio,
         p.preco_venda, p.nome as produto_nome,
         exists (select 1 from public.bar_produto_grupos g where g.bar_produto_id = bp.id and g.empresa_id = v_empresa) as usa_grupos
    from rows from (jsonb_to_recordset(p_itens) as (bar_produto_id uuid, quantidade numeric, observacao text, escolhas jsonb))
         with ordinality as x(bar_produto_id, quantidade, observacao, escolhas, ordem)
    left join public.bar_produtos bp on bp.id = x.bar_produto_id and bp.empresa_id = v_empresa
    left join public.produtos p on p.id = bp.produto_id and p.empresa_id = v_empresa) t;

  if exists (select 1 from unnest(v_itens) where produto_id is null) then
    raise exception 'Um ou mais itens do pedido não correspondem a produtos do cardápio do bar desta empresa.';
  end if;
  perform private.produtos_exigir_ativos(v_empresa, (select array_agg(ip.produto_id) from unnest(v_itens) ip));   -- [046:bar_enviar_item]
  if exists (select 1 from unnest(v_itens) where ativo_cardapio = false) then
    raise exception 'Um ou mais itens do pedido estão desativados no cardápio do bar.';
  end if;

  -- Valida e resolve as ESCOLHAS de cada item composto do modelo novo (requisitos #4/#5/#6):
  -- confere que a quantidade de escolhas bate com o configurado por grupo, que cada produto
  -- escolhido é opção válida daquele grupo, e BLOQUEIA o pedido inteiro se qualquer produto físico
  -- escolhido ainda estiver com destino "Não definido" (nunca lança "escondido" no destino errado).


  for r in select * from unnest(v_itens) where tipo = 'composto' and usa_grupos loop
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

    SELECT v_escolhas || coalesce(array_agg(ROW(t.*)::private.bar_escolha_pedido_linha),ARRAY[]::private.bar_escolha_pedido_linha[])
    INTO v_escolhas FROM (SELECT r.ordem, e.grupo_id, g.nome, e.produto_id, pr.nome, bpe.destino_operacional,
           (r.quantidade * count(*))::numeric(12,4) as quantidade
      from jsonb_to_recordset(r.escolhas) as e(grupo_id uuid, produto_id uuid)
      join public.bar_produto_grupos g on g.id = e.grupo_id and g.empresa_id = v_empresa
      join public.produtos pr on pr.id = e.produto_id and pr.empresa_id = v_empresa
      join public.bar_produtos bpe on bpe.produto_id = e.produto_id and bpe.empresa_id = v_empresa
     group by r.ordem, e.grupo_id, e.produto_id, g.nome, pr.nome, bpe.destino_operacional) t;
  end loop;

  -- Baixa de estoque POR ITEM: simples (o próprio produto); composto modelo ANTIGO (componentes
  -- marcados baixar_estoque, idêntico à Migration 016); composto modelo NOVO (exatamente os
  -- produtos físicos escolhidos, já resolvidos acima em unnest(v_escolhas)).
  SELECT coalesce(array_agg(ROW(t.*)::private.bar_baixa_pedido_linha),ARRAY[]::private.bar_baixa_pedido_linha[])
  INTO v_baixas FROM (
  select ip.ordem, ip.produto_id as produto_baixa_id, ip.quantidade as quantidade
    from unnest(v_itens) ip
   where ip.tipo = 'simples'
  union all
  select ip.ordem, c.componente_produto_id as produto_baixa_id, (ip.quantidade * c.quantidade)::numeric as quantidade
    from unnest(v_itens) ip
    join public.bar_produtos_componentes c on c.bar_produto_id = ip.bar_produto_id and c.empresa_id = v_empresa
   where ip.tipo = 'composto' and ip.usa_grupos = false and c.baixar_estoque = true
  union all
  select e.ordem, e.produto_id as produto_baixa_id, e.quantidade
    from unnest(v_escolhas) e) t;

  -- Trava e baixa o estoque núcleo, um produto por vez, em ordem fixa (evita deadlock), pelo TOTAL
  -- agregado deste pedido — mesmo padrão de public.registrar_venda e da Migration 016.
  for r in
    select produto_baixa_id as produto_id, sum(quantidade) as qtd
      from unnest(v_baixas)
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
  for r in select * from unnest(v_itens) order by ordem loop
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
      from unnest(v_baixas) b
     where b.ordem = r.ordem;

    if r.tipo = 'composto' and r.usa_grupos then
      insert into public.bar_pedidos_itens_escolhas
        (empresa_id, pedido_item_id, grupo_id, grupo_nome, produto_id, produto_nome, destino_operacional, quantidade)
      select v_empresa, v_item_id, e.grupo_id, e.grupo_nome, e.produto_id, e.produto_nome, e.destino_operacional, e.quantidade
        from unnest(v_escolhas) e
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
CREATE OR REPLACE FUNCTION public.bar_pedido_lancar(p_mesa_id uuid, p_itens jsonb, p_idempotencia uuid)
 RETURNS TABLE(comanda_id uuid, pedido_id uuid, itens_criados integer, mesa_aberta_agora boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa   uuid := private.exigir_empresa_ativa();
  v_mesa      public.bar_mesas%rowtype;
  v_comanda   uuid;
  v_abriu     boolean := false;
  v_pedido    uuid;
  v_itens_qtd integer;
  v_envio private.bar_envios;
begin
  if not private.empresa_tem_modulo('bar') then
    raise exception 'Este recurso exige o módulo Bar ativo para esta empresa.' using errcode = '42501';
  end if;
  if not private.perm('bar_pedidos') then
    raise exception 'Você não tem permissão para lançar pedidos no bar.' using errcode = '42501';
  end if;

  IF p_idempotencia IS NULL THEN RAISE EXCEPTION 'Identificador do pedido é obrigatório.' USING ERRCODE='22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_empresa::text||':bar:pedido:'||p_idempotencia::text,0));
  SELECT * INTO v_envio FROM private.bar_envios WHERE empresa_id=v_empresa AND chave=p_idempotencia;
  IF FOUND THEN
    IF v_envio.mesa_id IS DISTINCT FROM p_mesa_id OR v_envio.itens IS DISTINCT FROM p_itens THEN
      RAISE EXCEPTION 'Chave de pedido reutilizada com outro conteúdo.' USING ERRCODE='22023';
    END IF;
    comanda_id:=(v_envio.resultado->>'comanda_id')::uuid;pedido_id:=(v_envio.resultado->>'pedido_id')::uuid;
    itens_criados:=(v_envio.resultado->>'itens_criados')::integer;mesa_aberta_agora:=false;
    RETURN NEXT; RETURN;
  END IF;
  -- Pedidos antigos também são recuperados sem abrir outra comanda ou baixar estoque.
  SELECT p.id,p.comanda_id INTO v_pedido,v_comanda FROM public.bar_pedidos p WHERE p.empresa_id=v_empresa AND p.idempotencia_key=p_idempotencia;
  IF FOUND THEN
    comanda_id:=v_comanda;pedido_id:=v_pedido;mesa_aberta_agora:=false;
    SELECT count(*) INTO itens_criados FROM public.bar_pedidos_itens i WHERE i.empresa_id=v_empresa AND i.pedido_id=v_pedido;
    RETURN NEXT; RETURN;
  END IF;
  select * into v_mesa from public.bar_mesas
   where id = p_mesa_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Mesa não encontrada.';
  end if;
  IF jsonb_typeof(p_itens)='array' AND (p_itens->0) ? '_comanda_esperada' AND v_mesa.comanda_atual_id IS DISTINCT FROM ((p_itens->0)->>'_comanda_esperada')::uuid THEN
    RAISE EXCEPTION 'A mesa mudou em outro terminal. Atualize antes de lançar.' USING ERRCODE='40001';
  END IF;
  if v_mesa.status = 'fechada' then
    raise exception 'Esta mesa está fora de serviço.';
  end if;

  if v_mesa.status = 'livre' then
    v_comanda := private.bar_mesa_abrir_interna(p_mesa_id, 0);
    v_abriu := true;
  else
    v_comanda := v_mesa.comanda_atual_id;
    if v_comanda is null then
      raise exception 'Mesa ocupada sem comanda associada (inconsistência) — contate o suporte.';
    end if;
  end if;

  select pe.pedido_id, pe.itens_criados into v_pedido, v_itens_qtd
    from public.bar_pedido_enviar(v_comanda, p_itens, p_idempotencia) pe;

  comanda_id := v_comanda;
  pedido_id := v_pedido;
  itens_criados := v_itens_qtd;
  mesa_aberta_agora := v_abriu;
  INSERT INTO private.bar_envios(empresa_id,chave,mesa_id,itens,resultado)
  VALUES(v_empresa,p_idempotencia,p_mesa_id,p_itens,jsonb_build_object('comanda_id',comanda_id,'pedido_id',pedido_id,'itens_criados',itens_criados,'mesa_aberta_agora',mesa_aberta_agora));
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

  PERFORM private.bar_travar_mesa_da_comanda(p_comanda_id,v_empresa);
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

  PERFORM private.bar_travar_mesa_da_comanda(p_comanda_id,v_empresa);
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

  PERFORM private.bar_travar_mesa_da_comanda((SELECT comanda_id FROM public.bar_pagamentos WHERE id=p_pagamento_id AND empresa_id=v_empresa),v_empresa);
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

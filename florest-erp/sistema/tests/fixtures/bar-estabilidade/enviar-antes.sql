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
$function$


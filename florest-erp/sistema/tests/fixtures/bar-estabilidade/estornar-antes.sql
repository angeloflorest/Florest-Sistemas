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
$function$


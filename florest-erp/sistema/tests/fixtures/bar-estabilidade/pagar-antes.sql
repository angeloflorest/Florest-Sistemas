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
$function$


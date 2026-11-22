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
$function$


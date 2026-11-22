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
begin
  if not private.empresa_tem_modulo('bar') then
    raise exception 'Este recurso exige o módulo Bar ativo para esta empresa.' using errcode = '42501';
  end if;
  if not private.perm('bar_pedidos') then
    raise exception 'Você não tem permissão para lançar pedidos no bar.' using errcode = '42501';
  end if;

  select * into v_mesa from public.bar_mesas
   where id = p_mesa_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Mesa não encontrada.';
  end if;
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
  return next;
end;
$function$

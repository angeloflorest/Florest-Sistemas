create or replace function public.pdv_desktop_sincronizar(p_id_local uuid,p_caixa_id uuid,p_pedido jsonb,p_criada_em timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e uuid := private.exigir_empresa_ativa(); anterior private.pdv_desktop_recebimentos%rowtype;
  v uuid; num bigint; atual uuid;
begin
  if not private.perm('pdv') then raise exception 'Você não tem permissão para registrar vendas.' using errcode='42501'; end if;
  if p_id_local is null or p_caixa_id is null or p_criada_em is null or jsonb_typeof(p_pedido) is distinct from 'object' then
    raise exception 'Venda offline incompleta'; end if;
  perform pg_advisory_xact_lock(hashtextextended('pdv_desktop:'||e::text||':'||p_id_local::text,0));
  select * into anterior from private.pdv_desktop_recebimentos where empresa_id=e and id_local=p_id_local;
  if found then
    if anterior.usuario_id<>auth.uid() or anterior.pedido is distinct from p_pedido then
      raise exception 'Identificador pertence a outra venda ou operador.' using errcode='42501'; end if;
    return jsonb_build_object('empresaId',e,'idLocal',p_id_local,'idRemoto',anterior.venda_id,'numeroVenda',anterior.numero_venda,'repetida',true);
  end if;
  -- Não transfere silenciosamente vendas de um caixa fechado para outro caixa.
  atual := private.caixa_exigir_aberto('PDV');
  if atual<>p_caixa_id then raise exception 'O caixa desta venda foi fechado ou substituído. A venda permanece pendente para conferência.' using errcode='CX003'; end if;
  if coalesce((p_pedido->>'prazo')::boolean,false) then
    select r.venda_id,r.numero_venda into v,num from public.registrar_venda_prazo(
      (p_pedido->>'clienteId')::uuid,p_pedido->'itens',p_id_local,p_pedido->>'cpf') r;
  else
    select r.venda_id,r.numero_venda into v,num from public.registrar_venda_mista(
      (p_pedido->>'clienteId')::uuid,p_pedido->'itens',p_pedido->'pagamentos',p_pedido->>'cpf') r;
  end if;
  if v is null then raise exception 'Servidor não confirmou a venda'; end if;
  insert into private.pdv_desktop_recebimentos(empresa_id,id_local,usuario_id,pedido,venda_id,numero_venda,criada_local_em)
    values(e,p_id_local,auth.uid(),p_pedido,v,num,p_criada_em);
  return jsonb_build_object('empresaId',e,'idLocal',p_id_local,'idRemoto',v,'numeroVenda',num,'repetida',false);
end $$;
-- APIs exclusivas do Florest PDV Windows. Não altera as RPCs do PDV navegador.
create table if not exists private.pdv_desktop_recebimentos (
  empresa_id uuid not null references public.empresas(id),
  id_local uuid not null,
  usuario_id uuid not null,
  pedido jsonb not null,
  venda_id uuid not null,
  numero_venda bigint not null,
  criada_local_em timestamptz not null,
  recebido_em timestamptz not null default now(),
  primary key (empresa_id,id_local)
);
alter table private.pdv_desktop_recebimentos enable row level security;
revoke all on private.pdv_desktop_recebimentos from public, anon, authenticated;

create or replace function public.pdv_desktop_contexto()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e uuid := private.exigir_empresa_ativa(); r jsonb;
begin
  if not private.perm('pdv') then raise exception 'Você não tem permissão para usar o PDV.' using errcode='42501'; end if;
  select jsonb_build_object('empresaId',e,'userId',p.id,'operador',p.nome,'papel',p.papel,
    'empresa',em.nome,'cnpj',em.cnpj,'telefone',em.telefone,
    'permitirSemEstoque',coalesce(c.permitir_venda_sem_estoque,false)) into r
    from public.perfis p join public.empresas em on em.id=e
    left join public.configuracoes_empresa c on c.empresa_id=e where p.id=auth.uid();
  return r;
end $$;

create or replace function public.pdv_desktop_catalogo(p_recurso text, p_apos uuid default null, p_limite integer default 500)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e uuid := private.exigir_empresa_ativa(); r jsonb; lim integer := least(greatest(coalesce(p_limite,500),1),500);
begin
  if not private.perm('pdv') then raise exception 'Você não tem permissão para usar o PDV.' using errcode='42501'; end if;
  if p_recurso='produtos' then
    select coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]'::jsonb) into r from
      (select p.id,p.nome,p.codigo,p.gtin,p.preco_venda,p.quantidade_estoque,p.unidade_comercial,p.venda_granel,
        p.vendavel_pacote,p.pacote_qtd,p.pacote_preco,p.tipo_fiscal
       from public.produtos p where p.empresa_id=e and p.ativo and (p_apos is null or p.id>p_apos) order by p.id limit lim) t;
  elsif p_recurso='clientes' then
    select coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]'::jsonb) into r from
      (select c.id,c.nome,c.cpf,c.telefone from public.clientes c where c.empresa_id=e
       and (p_apos is null or c.id>p_apos) order by c.id limit lim) t;
  else raise exception 'Recurso inválido'; end if;
  return jsonb_build_object('empresaId',e,'itens',r);
end $$;

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
revoke all on function public.pdv_desktop_contexto() from public,anon;
revoke all on function public.pdv_desktop_catalogo(text,uuid,integer) from public,anon;
revoke all on function public.pdv_desktop_sincronizar(uuid,uuid,jsonb,timestamptz) from public,anon;
grant execute on function public.pdv_desktop_contexto(), public.pdv_desktop_catalogo(text,uuid,integer),
  public.pdv_desktop_sincronizar(uuid,uuid,jsonb,timestamptz) to authenticated;

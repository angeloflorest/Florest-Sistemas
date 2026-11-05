-- Additive integration; leaves public.caixas and existing sale/fiscal RPCs intact.
-- Apply in a single transaction after catalog/preflight and isolated tests.
begin;
set local lock_timeout='5s';
do $guard$ begin
if md5(pg_get_functiondef('public.pdv_historico_detalhar(uuid)'::regprocedure))<>'a5393a9dd6ac0ff094547918ec82bc8d' then raise exception 'Contrato mudou: public.pdv_historico_detalhar. Reinspecione antes de aplicar.'; end if;
if md5(pg_get_functiondef('public.pdv_historico_listar(text, integer, integer)'::regprocedure))<>'e29b2d895bd8d86032835c42dc7f1858' then raise exception 'Contrato mudou: public.pdv_historico_listar. Reinspecione antes de aplicar.'; end if;
if md5(pg_get_functiondef('public.registrar_venda(uuid, text, jsonb, text)'::regprocedure))<>'800ee142b19c43a0e904b4095a4ec93b' then raise exception 'Contrato mudou: public.registrar_venda. Reinspecione antes de aplicar.'; end if;
if md5(pg_get_functiondef('private.taxas_registrar(text, uuid, jsonb)'::regprocedure))<>'159a4a84912f986004f4207c80323918' then raise exception 'Contrato mudou: private.taxas_registrar. Reinspecione antes de aplicar.'; end if;
if md5(pg_get_functiondef('private.caixa_vinculo_validar()'::regprocedure))<>'bf81f490235ed9a17e0f3a8bcbe0ed5d' then raise exception 'Contrato mudou: private.caixa_vinculo_validar. Reinspecione antes de aplicar.'; end if;
if md5(pg_get_functiondef('private.venda_mista_validar_pagamentos(jsonb)'::regprocedure))<>'1f5ac778e57c8f40ca399dce871e6e73' then raise exception 'Contrato mudou: private.venda_mista_validar_pagamentos. Reinspecione antes de aplicar.'; end if;
if to_regclass('public.pdv_movel_caixas') is not null or to_regclass('private.pdv_movel_operacoes') is not null then raise exception 'Objetos móveis já existem; verificar estado antes de reaplicar.'; end if;
end $guard$;

create table public.pdv_movel_caixas (
 id uuid primary key default gen_random_uuid(), empresa_id uuid not null references public.empresas(id),
 dispositivo_id uuid not null, dispositivo_nome text not null check(length(dispositivo_nome) between 2 and 60),
 numero bigint not null check(numero>0), status text not null default 'aberto' check(status in ('aberto','fechado')),
 aberto_em timestamptz not null default now(), aberto_por uuid not null, aberto_por_nome text not null,
 valor_inicial numeric(14,2) not null check(valor_inicial>=0), fechado_em timestamptz, fechado_por uuid,
 fechado_por_nome text, fechamento_resumo jsonb,
 unique(empresa_id,id), unique(empresa_id,numero),
 check((status='aberto' and fechado_em is null and fechamento_resumo is null) or (status='fechado' and fechado_em is not null and fechado_por is not null and fechamento_resumo is not null))
);
create unique index pdv_movel_um_caixa_dispositivo on public.pdv_movel_caixas(empresa_id,dispositivo_id) where status='aberto';
alter table public.vendas add column pdv_movel_caixa_id uuid, add column pdv_movel_ajustes jsonb;
alter table public.vendas add constraint vendas_pdv_movel_caixa_fk foreign key(empresa_id,pdv_movel_caixa_id) references public.pdv_movel_caixas(empresa_id,id);
alter table public.vendas add constraint vendas_caixas_independentes_ck check(pdv_movel_caixa_id is null or (caixa_id is null and tipo is null));
create index vendas_pdv_movel_caixa_idx on public.vendas(empresa_id,pdv_movel_caixa_id) where pdv_movel_caixa_id is not null;
create table private.pdv_movel_operacoes (
 empresa_id uuid not null references public.empresas(id), chave uuid not null, dispositivo_id uuid not null,
 usuario_id uuid not null, tipo text not null check(tipo in ('sale','open-cash','close-cash')),
 pedido jsonb not null, resposta jsonb, criado_em timestamptz not null default now(), primary key(empresa_id,chave)
);
alter table public.pdv_movel_caixas enable row level security;
create policy pdv_movel_caixas_ler on public.pdv_movel_caixas for select to authenticated
 using(empresa_id=private.exigir_empresa_ativa() and (private.perm('pdv') or private.perm('financeiro') or private.perm('relatorios')) and (aberto_por=auth.uid() or private.perm('financeiro') or private.perm('relatorios')));
alter table private.pdv_movel_operacoes enable row level security;
revoke all on public.pdv_movel_caixas, private.pdv_movel_operacoes from public,anon,authenticated;
grant select on public.pdv_movel_caixas to authenticated;

create function private.pdv_movel_resumo(p_caixa uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa(); c public.pdv_movel_caixas; r jsonb;
begin
 select * into c from public.pdv_movel_caixas where id=p_caixa and empresa_id=e;
 if not found or not private.perm('pdv') or (c.aberto_por<>auth.uid() and not private.perm('financeiro')) then raise exception 'Caixa móvel não autorizado' using errcode='42501'; end if;
 select jsonb_build_object('quantidade_vendas',count(*),'total_vendido',coalesce(sum(total),0),'nota_prazo',coalesce(sum(total) filter(where forma_pagamento='Nota a Prazo'),0)) into r from public.vendas where empresa_id=e and pdv_movel_caixa_id=c.id and cancelada_em is null;
 return r||jsonb_build_object('por_forma',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from (select p.forma_pagamento,sum(p.valor) total from public.vendas_pagamentos p join public.vendas v on v.empresa_id=e and v.id=p.venda_id where p.empresa_id=e and v.pdv_movel_caixa_id=c.id and v.cancelada_em is null group by p.forma_pagamento) t),
 'dinheiro_esperado',c.valor_inicial+(select coalesce(sum(p.valor),0) from public.vendas_pagamentos p join public.vendas v on v.empresa_id=e and v.id=p.venda_id where p.empresa_id=e and v.pdv_movel_caixa_id=c.id and v.cancelada_em is null and p.forma_pagamento='Dinheiro'));
end $$;

create function public.pdv_movel_contexto(p_dispositivo uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa(); c public.pdv_movel_caixas; fiscal boolean; taxas jsonb;
begin
 if not private.perm('pdv') or p_dispositivo is null then raise exception 'Sem permissão para o PDV Móvel' using errcode='42501'; end if;
 select * into c from public.pdv_movel_caixas where empresa_id=e and dispositivo_id=p_dispositivo and status='aberto';
 if found and c.aberto_por<>auth.uid() and not private.perm('financeiro') then raise exception 'O caixa deste celular pertence a outro operador.' using errcode='42501'; end if;
 select emite_nota_fiscal into fiscal from public.configuracoes_fiscais where empresa_id=e;
 taxas:=public.taxas_pagamento_obter();
 return jsonb_build_object('contract',1,'empresa_id',e,'usuario_id',auth.uid(),'dispositivo_id',p_dispositivo,'caixa',case when c.id is null then null else to_jsonb(c) end,'resumo',case when c.id is null then null else private.pdv_movel_resumo(c.id) end,
 'venda_habilitada',fiscal is false,'motivo',case when fiscal is false then null else 'A empresa utiliza emissão fiscal. A venda móvel aguarda integração com o fluxo fiscal existente; a configuração fiscal não será alterada.' end,'taxas',taxas);
end $$;

create function public.pdv_movel_operacao_consultar(p_dispositivo uuid,p_tipo text,p_chave uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa(); o private.pdv_movel_operacoes;
begin
 if not private.perm('pdv') then raise exception 'Sem permissão' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended('pdv_movel:'||e::text||':'||p_chave::text,0));
 select * into o from private.pdv_movel_operacoes where empresa_id=e and chave=p_chave;
 if found then
  if o.usuario_id<>auth.uid() or o.dispositivo_id<>p_dispositivo or o.tipo<>p_tipo then raise exception 'Operação de outro usuário ou dispositivo' using errcode='42501'; end if;
  return o.resposta;
 end if;
 return jsonb_build_object('state','absent','operationKey',p_chave,'companyId',e,'deviceId',p_dispositivo);
end $$;

create function public.pdv_movel_operar(p_dispositivo uuid,p_tipo text,p_chave uuid,p_pedido jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 e uuid:=private.exigir_empresa_ativa(); uid uuid:=auth.uid(); o private.pdv_movel_operacoes; c public.pdv_movel_caixas;
 result jsonb; response jsonb; item jsonb; pay jsonb; items jsonb:='[]'; payments jsonb; cfg jsonb; fiscal boolean;
 produto public.produtos; quantidade numeric; desconto numeric; acrescimo numeric; preco numeric; total numeric; soma numeric;
 venda uuid; numero bigint; titulo uuid; prazo boolean; cliente uuid; valor numeric; forma text; resumo text; cfgid text; bandeira text;
begin
 if not private.perm('pdv') or p_dispositivo is null or p_chave is null or p_tipo not in ('sale','open-cash','close-cash') or p_pedido is null or jsonb_typeof(p_pedido)<>'object' then raise exception 'Operação não autorizada ou inválida' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended('pdv_movel:'||e::text||':'||p_chave::text,0));
 select * into o from private.pdv_movel_operacoes where empresa_id=e and chave=p_chave;
 if found then
  if o.usuario_id<>uid or o.dispositivo_id<>p_dispositivo or o.tipo<>p_tipo or o.pedido<>p_pedido then raise exception 'Chave já usada com outros dados, usuário ou dispositivo' using errcode='42501'; end if;
  return o.resposta;
 end if;
 insert into private.pdv_movel_operacoes(empresa_id,chave,dispositivo_id,usuario_id,tipo,pedido) values(e,p_chave,p_dispositivo,uid,p_tipo,p_pedido);
 -- Financial work in a subtransaction: rejected requests persist only a rejection receipt.
 begin
  if p_tipo='open-cash' then
   perform pg_advisory_xact_lock(hashtextextended('pdv_movel_abertura:'||e::text,0));
   if exists(select 1 from public.pdv_movel_caixas where empresa_id=e and dispositivo_id=p_dispositivo and status='aberto') then raise exception 'Este celular já possui caixa aberto'; end if;
   valor:=(p_pedido->>'valor_inicial')::numeric;
   if valor is null or valor<0 or valor>99999999999.99 or valor<>round(valor,2) then raise exception 'Valor inicial inválido'; end if;
   insert into public.pdv_movel_caixas(empresa_id,dispositivo_id,dispositivo_nome,numero,aberto_por,aberto_por_nome,valor_inicial)
   select e,p_dispositivo,p_pedido->>'nome',coalesce(max(cx.numero),0)+1,uid,private.caixa_nome_usuario(),valor from public.pdv_movel_caixas cx where cx.empresa_id=e returning * into c;
   result:=jsonb_build_object('caixa',to_jsonb(c),'resumo',private.pdv_movel_resumo(c.id));
  else
   -- Exclusive lock serializes each sale/close in this device, without locking other cash sessions.
   select * into c from public.pdv_movel_caixas where empresa_id=e and id=(p_pedido->>'caixa_id')::uuid and dispositivo_id=p_dispositivo for update;
   if not found or (c.aberto_por<>uid and not private.perm('financeiro')) then raise exception 'Caixa de outro dispositivo ou operador' using errcode='42501'; end if;
   if c.status<>'aberto' then raise exception 'O caixa móvel já está fechado'; end if;
   if p_tipo='close-cash' then
    result:=private.pdv_movel_resumo(c.id);
    update public.pdv_movel_caixas set status='fechado',fechado_em=now(),fechado_por=uid,fechado_por_nome=private.caixa_nome_usuario(),fechamento_resumo=result where id=c.id returning * into c;
    result:=jsonb_build_object('caixa',to_jsonb(c),'resumo',result);
   else
    select emite_nota_fiscal into fiscal from public.configuracoes_fiscais where empresa_id=e;
    if fiscal is distinct from false then raise exception 'Venda móvel indisponível para empresa com emissão fiscal ativa ou configuração não confirmada; use o fluxo fiscal existente no ERP.'; end if;
    prazo:=coalesce((p_pedido->>'prazo')::boolean,false); cliente:=nullif(p_pedido->>'cliente_id','')::uuid;
    if jsonb_typeof(p_pedido->'itens')<>'array' or jsonb_array_length(p_pedido->'itens') not between 1 and 500 then raise exception 'Informe de 1 a 500 itens'; end if;
    -- Fixed product lock ordering, also shared with registrar_venda: price checks and stock are one transaction.
    perform p.id from public.produtos p where p.empresa_id=e and p.id in(select (x->>'produto_id')::uuid from jsonb_array_elements(p_pedido->'itens') x) order by p.id for update;
    for item in select * from jsonb_array_elements(p_pedido->'itens') loop
     select * into produto from public.produtos where empresa_id=e and id=(item->>'produto_id')::uuid;
     if not found or produto.ativo is distinct from true or not (produto.preco_venda between 0 and 99999999.99) then raise exception 'Produto não encontrado ou inativo'; end if;
     quantidade:=(item->>'quantidade')::numeric; desconto:=coalesce((item->>'desconto')::numeric,0); acrescimo:=coalesce((item->>'acrescimo')::numeric,0);
     if quantidade is null or not (quantidade between 0.001 and 9999999.999) or quantidade<>round(quantidade,3) or not (desconto between 0 and 99999999.99) or not (acrescimo between 0 and 99999999.99) or desconto<>round(desconto,2) or acrescimo<>round(acrescimo,2) or desconto>produto.preco_venda then raise exception 'Quantidade ou ajuste inválido'; end if;
     if (item->>'preco_base')::numeric is distinct from produto.preco_venda then raise exception 'Preço do produto mudou. Atualize o item antes de vender.'; end if;
     preco:=round(produto.preco_venda-desconto+acrescimo,2);
     items:=items||jsonb_build_array(jsonb_build_object('produto_id',produto.id,'quantidade',quantidade,'preco_unitario',preco));
    end loop;
    select coalesce(sum(round((x->>'quantidade')::numeric*(x->>'preco_unitario')::numeric,2)),0) into total from jsonb_array_elements(items) x;
    if total<=0 then raise exception 'Total deve ser positivo'; end if;
    payments:=p_pedido->'pagamentos';
    if prazo then
     if cliente is null or payments is null or payments<>'[]'::jsonb then raise exception 'Nota a prazo exige cliente cadastrado e nenhum recebimento'; end if;
     resumo:='Nota a Prazo';
    else
     select sum(x.valor),case when count(distinct x.forma_pagamento)=1 then min(x.forma_pagamento) else 'dividido' end into soma,resumo from private.venda_mista_validar_pagamentos(payments) x;
     if soma is null or round(soma,2)<>total then raise exception 'Soma dos pagamentos deve corresponder ao total'; end if;
    end if;
    select r.venda_id,r.numero_venda into venda,numero from public.registrar_venda(cliente,resumo,items,null) r;
    if venda is null then raise exception 'Venda não confirmada'; end if;
    update public.vendas set pdv_movel_caixa_id=c.id,pdv_movel_ajustes=p_pedido->'itens' where id=venda and empresa_id=e;
    select v.total into valor from public.vendas v where v.id=venda and v.empresa_id=e;
    if valor<>total then raise exception 'Total do servidor divergiu'; end if;
    if prazo then
     insert into public.contas_receber(empresa_id,cliente_id,venda_id,origem,valor_original,saldo_aberto,vencimento,criado_por)
     values(e,cliente,venda,'nota_prazo',total,total,private.ultimo_dia_do_mes(private.pdv_hoje()),uid) returning id into titulo;
    else
     insert into public.vendas_pagamentos(empresa_id,venda_id,forma_pagamento,valor,ordem,criado_por,caixa_id)
     select e,venda,x.forma_pagamento,x.valor,x.ordem,uid,null from private.venda_mista_validar_pagamentos(payments) x order by x.ordem;
     cfg:=public.taxas_pagamento_obter();
     for pay in select * from jsonb_array_elements(payments) loop
      -- Require current fee configuration/band where applicable; never silently omit merchant fees.
      if cfg->>'id' is not null and (pay->'taxas'->>'config_id') is distinct from cfg->>'id' then raise exception 'Atualize a configuração de taxas antes de confirmar o pagamento'; end if;
     end loop;
     perform private.taxas_registrar('pdv',p.id,payments->(p.ordem-1)) from public.vendas_pagamentos p where p.empresa_id=e and p.venda_id=venda;
    end if;
    result:=jsonb_build_object('venda_id',venda,'numero_venda',numero,'total',total,'titulo_id',titulo,'caixa_id',c.id,'origem','PDV Móvel');
   end if;
  end if;
  response:=jsonb_build_object('state','confirmed','operationKey',p_chave,'companyId',e,'deviceId',p_dispositivo,'result',result);
 exception
  when serialization_failure or deadlock_detected then raise;
  when others then response:=jsonb_build_object('state','rejected','operationKey',p_chave,'companyId',e,'deviceId',p_dispositivo,'error',sqlerrm,'result',jsonb_build_object('message',sqlerrm));
 end;
 update private.pdv_movel_operacoes set resposta=response where empresa_id=e and chave=p_chave;
 return response;
end $$;

create function public.pdv_movel_caixas_listar(p_dispositivo uuid,p_caixa uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa(); result jsonb;
begin
 if not private.perm('pdv') then raise exception 'Sem permissão' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('resumo',case when t.status='fechado' then t.fechamento_resumo else private.pdv_movel_resumo(t.id) end) order by t.aberto_em desc),'[]') into result from (
 select * from public.pdv_movel_caixas where empresa_id=e and dispositivo_id=p_dispositivo and (p_caixa is null or id=p_caixa) and (aberto_por=auth.uid() or private.perm('financeiro')) order by aberto_em desc limit 100) t;
 return result;
end $$;

create function public.pdv_movel_vendas_listar(p_filtros jsonb default '{}',p_limite integer default 100,p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa(); result jsonb; de date:=nullif(p_filtros->>'inicio','')::date; ate date:=nullif(p_filtros->>'fim','')::date;
begin
 if not private.perm('pdv') then raise exception 'Sem permissão' using errcode='42501'; end if;
 if de>ate then raise exception 'Período inválido'; end if;
 select coalesce(jsonb_agg(to_jsonb(t) order by t.criado_em desc,t.numero_venda desc),'[]') into result from (
 select v.id,v.numero_venda,v.criado_em,v.total,v.cliente_id,coalesce(cl.nome,'Consumidor Padrão') cliente_nome,v.forma_pagamento,v.cancelada_em,
 case when v.pdv_movel_caixa_id is null then 'PDV Principal' else 'PDV Móvel' end origem,coalesce(v.pdv_movel_caixa_id,v.caixa_id) caixa_id,coalesce(mc.numero,pc.numero) caixa_numero,pr.nome operador_nome,v.criado_por operador_id
 from public.vendas v left join public.clientes cl on cl.empresa_id=e and cl.id=v.cliente_id
 left join public.pdv_movel_caixas mc on mc.empresa_id=e and mc.id=v.pdv_movel_caixa_id left join public.caixas pc on pc.empresa_id=e and pc.id=v.caixa_id left join public.perfis pr on pr.id=v.criado_por and pr.empresa_id=e
 where v.empresa_id=e and v.tipo is null and (private.perm('financeiro') or (v.pdv_movel_caixa_id is not null and v.criado_por=auth.uid()))
 and (de is null or v.criado_em>=(de::timestamp at time zone 'America/Sao_Paulo')) and (ate is null or v.criado_em<((ate+1)::timestamp at time zone 'America/Sao_Paulo'))
 and (nullif(p_filtros->>'numero','') is null or v.numero_venda::text=p_filtros->>'numero')
 and (nullif(p_filtros->>'caixa','') is null or coalesce(v.pdv_movel_caixa_id,v.caixa_id)::text=p_filtros->>'caixa' or coalesce(mc.numero,pc.numero)::text=p_filtros->>'caixa')
 and (nullif(p_filtros->>'operador','') is null or pr.nome ilike '%'||(p_filtros->>'operador')||'%')
 and (nullif(p_filtros->>'cliente','') is null or cl.nome ilike '%'||(p_filtros->>'cliente')||'%')
 order by v.criado_em desc,v.numero_venda desc limit least(greatest(p_limite,1),200) offset greatest(p_offset,0)) t;
 return result;
end $$;

create function public.pdv_movel_venda_detalhar(p_venda uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa(); v public.vendas; result jsonb;
begin
 if not private.perm('pdv') then raise exception 'Sem permissão' using errcode='42501'; end if;
 select * into v from public.vendas where empresa_id=e and id=p_venda and tipo is null and (private.perm('financeiro') or (pdv_movel_caixa_id is not null and criado_por=auth.uid()));
 if not found then raise exception 'Venda não autorizada' using errcode='42501'; end if;
 result:=public.pdv_historico_detalhar(p_venda);
 return result||jsonb_build_object('editavel',false,'venda',(result->'venda')||jsonb_build_object('origem',case when v.pdv_movel_caixa_id is null then 'PDV Principal' else 'PDV Móvel' end,'caixa_id',coalesce(v.pdv_movel_caixa_id,v.caixa_id),'operador_nome',(select nome from public.perfis where id=v.criado_por and empresa_id=e)),
 'caixa_movel',(select to_jsonb(c) from public.pdv_movel_caixas c where c.id=v.pdv_movel_caixa_id and c.empresa_id=e),'titulo',(select jsonb_build_object('id',id,'vencimento',vencimento,'saldo_aberto',saldo_aberto) from public.contas_receber where empresa_id=e and venda_id=v.id));
end $$;

revoke all on function private.pdv_movel_resumo(uuid) from public,anon,authenticated;
revoke all on function public.pdv_movel_contexto(uuid), public.pdv_movel_operacao_consultar(uuid,text,uuid),public.pdv_movel_operar(uuid,text,uuid,jsonb),public.pdv_movel_caixas_listar(uuid,uuid),public.pdv_movel_vendas_listar(jsonb,integer,integer),public.pdv_movel_venda_detalhar(uuid) from public,anon;
grant execute on function public.pdv_movel_contexto(uuid), public.pdv_movel_operacao_consultar(uuid,text,uuid),public.pdv_movel_operar(uuid,text,uuid,jsonb),public.pdv_movel_caixas_listar(uuid,uuid),public.pdv_movel_vendas_listar(jsonb,integer,integer),public.pdv_movel_venda_detalhar(uuid) to authenticated;

-- Existing histories gain metadata only; authorization/editability remain unchanged.
CREATE OR REPLACE FUNCTION public.pdv_historico_detalhar(p_venda uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e uuid:=private.exigir_empresa_ativa(); v public.vendas; c public.caixas; editavel boolean;
begin
 if not private.perm('pdv') then raise exception 'Sem permissão' using errcode='42501'; end if;
 select * into v from public.vendas where id=p_venda and empresa_id=e and tipo is null;
 if not found then raise exception 'Venda não encontrada'; end if;
 select * into c from public.caixas where id=v.caixa_id and empresa_id=e and tipo_caixa='PDV';
 editavel:=v.cancelada_em is null and c.status='aberto'
 and not exists(select 1 from public.documentos_fiscais d where d.empresa_id=e and d.venda_id=v.id and (d.status is distinct from 'cancelado' or d.chave_acesso is not null))
 and not exists(select 1 from public.contas_receber cr where cr.empresa_id=e and cr.venda_id=v.id)
 and not exists(select 1 from public.itens_venda i where i.empresa_id=e and i.venda_id=v.id and i.pacote_cliente_id is not null)
 and not exists(select 1 from private.taxas_pagamentos tp where tp.empresa_id=e and tp.venda_id=v.id);
 return jsonb_build_object('venda',to_jsonb(v)||jsonb_build_object('origem',case when v.pdv_movel_caixa_id is null then 'PDV Principal' else 'PDV Móvel' end,'caixa_numero',(select numero from public.pdv_movel_caixas where id=v.pdv_movel_caixa_id and empresa_id=e),'operador_nome',(select nome from public.perfis where id=v.criado_por and empresa_id=e)),'editavel',editavel,
 'cliente_nome',(select nome from public.clientes where id=v.cliente_id and empresa_id=e),
 'itens',(select coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('nome',p.nome) order by i.id),'[]'::jsonb) from public.itens_venda i join public.produtos p on p.id=i.produto_id and p.empresa_id=e where i.empresa_id=e and i.venda_id=v.id),
 'pagamentos',(select coalesce(jsonb_agg(to_jsonb(pa) order by pa.ordem),'[]'::jsonb) from public.vendas_pagamentos pa where pa.empresa_id=e and pa.venda_id=v.id));
end $function$
;
CREATE OR REPLACE FUNCTION public.pdv_historico_listar(p_busca text DEFAULT NULL::text, p_limite integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e uuid:=private.exigir_empresa_ativa(); r jsonb;
begin
 if not private.perm('pdv') then raise exception 'Sem permissão para o PDV' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.criado_em desc,x.numero_venda desc),'[]'::jsonb) into r from (
 select v.id,v.numero_venda,v.criado_em,v.total,v.forma_pagamento,v.cancelada_em,v.cliente_id,
 coalesce(cl.nome,'Consumidor') cliente_nome,c.status caixa_status,
 case when v.pdv_movel_caixa_id is null then 'PDV Principal' else 'PDV Móvel' end origem,
 coalesce(v.pdv_movel_caixa_id,v.caixa_id) caixa_id,coalesce(mc.numero,c.numero) caixa_numero,op.nome operador_nome,
 (v.cancelada_em is null and c.status='aberto' and c.tipo_caixa='PDV'
 and not exists(select 1 from public.documentos_fiscais d where d.empresa_id=e and d.venda_id=v.id and (d.status is distinct from 'cancelado' or d.chave_acesso is not null))
 and not exists(select 1 from public.contas_receber cr where cr.empresa_id=e and cr.venda_id=v.id)
 and not exists(select 1 from public.itens_venda i where i.empresa_id=e and i.venda_id=v.id and i.pacote_cliente_id is not null)
 and not exists(select 1 from private.taxas_pagamentos tp where tp.empresa_id=e and tp.venda_id=v.id)
 ) editavel
 from public.vendas v left join public.caixas c on c.id=v.caixa_id and c.empresa_id=e
 left join public.clientes cl on cl.id=v.cliente_id and cl.empresa_id=e
 left join public.pdv_movel_caixas mc on mc.id=v.pdv_movel_caixa_id and mc.empresa_id=e
 left join public.perfis op on op.id=v.criado_por and op.empresa_id=e
 where v.empresa_id=e and v.tipo is null and (p_busca is null or btrim(p_busca)='' or
 v.numero_venda::text ilike '%'||btrim(p_busca)||'%' or cl.nome ilike '%'||btrim(p_busca)||'%' or
 v.forma_pagamento ilike '%'||btrim(p_busca)||'%' or v.total::text ilike '%'||btrim(p_busca)||'%' or
 v.criado_em::date::text ilike '%'||btrim(p_busca)||'%')
 order by v.criado_em desc,v.numero_venda desc limit least(greatest(coalesce(p_limite,100),1),200) offset greatest(coalesce(p_offset,0),0)
 ) x;
 return r;
end $function$
;
notify pgrst,'reload schema';
commit;

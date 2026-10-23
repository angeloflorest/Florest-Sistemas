
create table private.taxas_versoes(id uuid primary key default gen_random_uuid(),empresa_id uuid not null references public.empresas(id),ativo boolean not null,regras jsonb not null,criado_em timestamptz not null default now(),criado_por uuid not null);
create table private.taxas_config(empresa_id uuid primary key references public.empresas(id),versao_id uuid not null references private.taxas_versoes(id));
create table private.taxas_pagamentos(origem text not null check(origem in ('pdv','bar')),pagamento_id uuid not null,empresa_id uuid not null references public.empresas(id),config_id uuid not null references private.taxas_versoes(id),venda_id uuid,bar_pagamento_id uuid,data date not null,forma text not null,bandeira text,valor_bruto numeric(14,2) not null,percentual numeric(8,4) not null,valor_taxa numeric(14,2) not null,ativo boolean not null default true,primary key(origem,pagamento_id));
create index on private.taxas_pagamentos(empresa_id,data) where ativo;
create index on private.taxas_pagamentos(venda_id) where origem='pdv';
create index on private.taxas_pagamentos(bar_pagamento_id) where origem='bar';
alter table private.taxas_versoes enable row level security;
alter table private.taxas_config enable row level security;
alter table private.taxas_pagamentos enable row level security;
revoke all on private.taxas_versoes,private.taxas_config,private.taxas_pagamentos from public,anon,authenticated;
alter table public.despesas add column taxas_automaticas boolean not null default false;
create unique index despesas_taxas_dia on public.despesas(empresa_id,data) where taxas_automaticas;
create function public.taxas_pagamento_obter() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa(); r jsonb;
begin
 if not (private.perm('pdv') or private.perm('bar_caixa') or private.perm('financeiro')) then raise exception 'Sem permissão para consultar formas de pagamento.' using errcode='42501'; end if;
 select jsonb_build_object('id',v.id,'ativo',v.ativo,'regras',v.regras) into r from private.taxas_config c join private.taxas_versoes v on v.id=c.versao_id and v.empresa_id=c.empresa_id where c.empresa_id=e;
 return coalesce(r,'{"id":null,"ativo":false,"regras":[]}'::jsonb);
end $$;
create function public.taxas_pagamento_salvar(p_ativo boolean,p_regras jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa(); v uuid; item jsonb; f text; b text; p numeric; regras jsonb:='[]'; chaves text[]:='{}'; chave text;
begin
 if not private.perm('financeiro') then raise exception 'Sem permissão para configurar taxas no Financeiro.' using errcode='42501'; end if;
 if p_ativo is null or jsonb_typeof(p_regras) is distinct from 'array' or jsonb_array_length(p_regras)>13 then raise exception 'Configuração de taxas inválida'; end if;
 for item in select value from jsonb_array_elements(p_regras) loop
  f:=item->>'forma'; b:=nullif(item->>'bandeira','');
  if f not in ('Pix','Cartão de Débito','Cartão de Crédito') or f is null then raise exception 'Forma inválida'; end if;
  if (f='Pix' and b is not null) or (f<>'Pix' and (b is null or b not in ('Visa','Mastercard','Elo','American Express','Hipercard','Diners'))) then raise exception 'Bandeira inválida'; end if;
  if jsonb_typeof(item->'percentual') is distinct from 'number' then raise exception 'Informe a taxa percentual'; end if;
  p:=(item->>'percentual')::numeric;
  if p<0 or p>100 or p<>round(p,4) then raise exception 'Taxa deve estar entre 0 e 100, com até quatro casas'; end if;
  chave:=f||':'||coalesce(b,''); if chave=any(chaves) then raise exception 'Bandeira repetida'; end if; chaves:=array_append(chaves,chave);
  regras:=regras||jsonb_build_array(jsonb_build_object('forma',f,'bandeira',b,'percentual',p));
 end loop;
 perform pg_advisory_xact_lock(hashtextextended('taxas-config:'||e::text,0));
 insert into private.taxas_versoes(empresa_id,ativo,regras,criado_por) values(e,p_ativo,regras,auth.uid()) returning id into v;
 insert into private.taxas_config values(e,v) on conflict(empresa_id) do update set versao_id=excluded.versao_id;
 return public.taxas_pagamento_obter();
end $$;
create function private.taxas_proteger_despesa() returns trigger language plpgsql set search_path='' as $$
begin
 if (case when tg_op='DELETE' then old.taxas_automaticas else new.taxas_automaticas or coalesce(old.taxas_automaticas,false) end)
 and not (current_user in ('postgres','supabase_admin') and coalesce(current_setting('private.taxas_interno',true),'')='1') then
 raise exception 'Despesa automática: a alteração é feita pelo pagamento ou estorno.' using errcode='42501'; end if;
 if tg_op='DELETE' then return old; end if; return new;
end $$;
create trigger taxas_proteger before insert or update or delete on public.despesas for each row execute function private.taxas_proteger_despesa();
create function private.taxas_consolidar(e uuid,d date) returns void language plpgsql security definer set search_path='' as $$
declare total numeric; anterior text:=coalesce(current_setting('private.taxas_interno',true),'');
begin
 perform pg_advisory_xact_lock(hashtextextended('taxas-dia:'||e::text||':'||d::text,0));
 select coalesce(sum(valor_taxa),0) into total from private.taxas_pagamentos where empresa_id=e and data=d and ativo;
 perform set_config('private.taxas_interno','1',true);
 if total=0 then delete from public.despesas where empresa_id=e and data=d and taxas_automaticas;
 else insert into public.despesas(empresa_id,descricao,categoria,valor,data,vencimento,status,pago_em,taxas_automaticas,observacoes)
 values(e,'Despesa administrativa de cartões','Despesa administrativa de cartões',total,d,d,'pago',d,true,'Taxas de cartões e Pix. Calculadas automaticamente pelos pagamentos.')
 on conflict(empresa_id,data) where taxas_automaticas do update set valor=excluded.valor;
 end if;
 perform set_config('private.taxas_interno',anterior,true);
end $$;
create function private.taxas_registrar(p_origem text,p_id uuid,p_meta jsonb) returns void language plpgsql security definer set search_path='' as $$
declare e uuid; bruto numeric; forma text; vid uuid; bid uuid; dt date; cfg private.taxas_versoes%rowtype; b text; taxa numeric:=0; tem boolean; anulada boolean:=false;
begin
 if p_meta->'taxas'->>'config_id' is null then return; end if;
 if p_origem='pdv' then
 select p.empresa_id,p.valor,p.forma_pagamento,p.venda_id,(p.criado_em at time zone 'America/Sao_Paulo')::date,v.cancelada_em is not null into e,bruto,forma,vid,dt,anulada from public.vendas_pagamentos p join public.vendas v on v.id=p.venda_id and v.empresa_id=p.empresa_id where p.id=p_id;
 else
 select p.empresa_id,p.valor,p.forma_pagamento,p.pagamento_id,(p.criado_em at time zone 'America/Sao_Paulo')::date,bp.estornado into e,bruto,forma,bid,dt,anulada from public.bar_pagamentos_formas p join public.bar_pagamentos bp on bp.id=p.pagamento_id and bp.empresa_id=p.empresa_id where p.id=p_id;
 end if;
 if e is null or e is distinct from private.empresa_id_ativa() then raise exception 'Pagamento de outra empresa' using errcode='42501'; end if;
 select * into cfg from private.taxas_versoes where id=(p_meta->'taxas'->>'config_id')::uuid and empresa_id=e;
 if not found then raise exception 'Configuração de outra empresa ou inexistente' using errcode='42501'; end if;
 b:=nullif(p_meta->'taxas'->>'bandeira','');
 if cfg.ativo and forma in ('Pix','Cartão de Débito','Cartão de Crédito') then
 select exists(select 1 from jsonb_array_elements(cfg.regras) r where r->>'forma'=forma) into tem;
 if tem then
  select (r->>'percentual')::numeric into taxa from jsonb_array_elements(cfg.regras) r where r->>'forma'=forma and coalesce(r->>'bandeira','')=coalesce(b,'');
  if taxa is null then raise exception 'Selecione uma bandeira com taxa cadastrada'; end if;
 end if;
 end if;
 taxa:=coalesce(taxa,0);
 insert into private.taxas_pagamentos(origem,pagamento_id,empresa_id,config_id,venda_id,bar_pagamento_id,data,forma,bandeira,valor_bruto,percentual,valor_taxa,ativo)
 values(p_origem,p_id,e,cfg.id,vid,bid,dt,forma,b,bruto,taxa,round(bruto*taxa/100,2),not anulada) on conflict do nothing;
 perform private.taxas_consolidar(e,dt);
end $$;
create function private.taxas_reverter() returns trigger language plpgsql security definer set search_path='' as $$
declare r record;
begin
 if tg_table_name='vendas' then
  if new.cancelada_em is not distinct from old.cancelada_em then return new; end if;
  update private.taxas_pagamentos set ativo=new.cancelada_em is null where empresa_id=new.empresa_id and origem='pdv' and venda_id=new.id;
  for r in select distinct empresa_id,data from private.taxas_pagamentos where empresa_id=new.empresa_id and origem='pdv' and venda_id=new.id loop perform private.taxas_consolidar(r.empresa_id,r.data); end loop;
 elsif tg_table_name='bar_pagamentos' then
  if new.estornado is not distinct from old.estornado then return new; end if;
  update private.taxas_pagamentos set ativo=not new.estornado where empresa_id=new.empresa_id and origem='bar' and bar_pagamento_id=new.id;
  for r in select distinct empresa_id,data from private.taxas_pagamentos where empresa_id=new.empresa_id and origem='bar' and bar_pagamento_id=new.id loop perform private.taxas_consolidar(r.empresa_id,r.data); end loop;
 end if; return new;
end $$;
create trigger taxas_cancelar_venda after update of cancelada_em on public.vendas for each row execute function private.taxas_reverter();
create trigger taxas_estornar_bar after update of estornado on public.bar_pagamentos for each row execute function private.taxas_reverter();
revoke all on function public.taxas_pagamento_obter(), public.taxas_pagamento_salvar(boolean,jsonb) from public,anon;
grant execute on function public.taxas_pagamento_obter(), public.taxas_pagamento_salvar(boolean,jsonb) to authenticated;
revoke all on function private.taxas_proteger_despesa(),private.taxas_consolidar(uuid,date),private.taxas_registrar(text,uuid,jsonb),private.taxas_reverter() from public,anon,authenticated;

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
;

CREATE OR REPLACE FUNCTION public.pdv_desktop_contexto()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e uuid := private.exigir_empresa_ativa(); r jsonb;
begin
  if not private.perm('pdv') then raise exception 'Você não tem permissão para usar o PDV.' using errcode='42501'; end if;
  select jsonb_build_object('empresaId',e,'userId',p.id,'operador',p.nome,'papel',p.papel,
    'empresa',em.nome,'cnpj',em.cnpj,'telefone',em.telefone,
    'permitirSemEstoque',coalesce(c.permitir_venda_sem_estoque,false)) into r
    from public.perfis p join public.empresas em on em.id=e
    left join public.configuracoes_empresa c on c.empresa_id=e where p.id=auth.uid();
  return r || jsonb_build_object('taxas_pagamento', public.taxas_pagamento_obter());
end $function$
;

CREATE OR REPLACE FUNCTION public.registrar_venda_mista(p_cliente_id uuid, p_itens jsonb, p_pagamentos jsonb, p_cpf_nota text DEFAULT NULL::text)
 RETURNS TABLE(venda_id uuid, numero_venda bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare
  -- empresa SEMPRE derivada do usuário autenticado — nenhum parâmetro de empresa existe
  v_empresa      uuid := private.exigir_empresa_ativa();
  v_qtd          integer;
  v_qtd_formas   integer;
  v_unica        text;
  v_soma         numeric;
  v_resumo       text;
  v_venda        uuid;
  v_numero       bigint;
  v_total        numeric;
  v_caixa        uuid;
begin
  -- mesma permissão de public.registrar_venda (proprietário sempre pode; funcionário precisa de PDV)
  if not private.perm('pdv') then
    raise exception 'Você não tem permissão para registrar vendas.' using errcode = '42501';
  end if;

  -- Migration 032: sem Caixa PDV aberto não há venda. Trava o caixa (FOR SHARE) até o fim da transação:
  -- o fechamento espera esta venda terminar; uma venda iniciada depois do fechamento é recusada.
  v_caixa := private.caixa_exigir_aberto('PDV');

  -- 1) valida os pagamentos ANTES de tocar em estoque/venda (falha rápida e barata)
  select count(*)::integer,
         count(distinct x.forma_pagamento)::integer,
         min(x.forma_pagamento),
         coalesce(sum(x.valor), 0)
    into v_qtd, v_qtd_formas, v_unica, v_soma
    from private.venda_mista_validar_pagamentos(p_pagamentos) x;

  -- 2) uma forma distinta -> o nome dela; duas ou mais formas distintas -> 'dividido'
  v_resumo := case when v_qtd_formas = 1 then v_unica else 'dividido' end;

  -- 3) cria a venda pela função EXISTENTE (estoque, pacotes, numeração, itens e total ficam 100%
  --    sob a lógica atual dela — inclusive a validação de itens, cliente e CPF da nota)
  select r.venda_id, r.numero_venda
    into v_venda, v_numero
    from public.registrar_venda(p_cliente_id, v_resumo, p_itens, p_cpf_nota) r;

  if v_venda is null then
    raise exception 'Não foi possível registrar a venda.';
  end if;

  -- 4) total REAL calculado pelo servidor (lido da própria venda recém-criada, da MESMA empresa)
  select v.total
    into v_total
    from public.vendas v
   where v.id = v_venda
     and v.empresa_id = v_empresa;
  if not found then
    raise exception 'Venda não encontrada após o registro.';
  end if;

  -- 5) soma dos pagamentos == total, comparados em CENTAVOS (inteiros); senão exceção = rollback
  --    de tudo (venda, itens, estoque, número da venda e pagamentos)
  if round(v_soma * 100)::bigint <> round(v_total * 100)::bigint then
    raise exception 'A soma dos pagamentos (R$ %) não é igual ao total da venda (R$ %).',
      replace(v_soma::text, '.', ','), replace(v_total::text, '.', ',');
  end if;

  -- 5b) Migration 032: vincula a venda ao Caixa PDV aberto (vínculo persistente, por FK — nunca por data)
  update public.vendas set caixa_id = v_caixa where id = v_venda and empresa_id = v_empresa;

  -- 6) grava os pagamentos: empresa_id e venda_id vêm do servidor (nunca do chamador); a FK
  --    composta (empresa_id, venda_id) reconfirma que a venda é desta empresa
  insert into public.vendas_pagamentos (empresa_id, venda_id, forma_pagamento, valor, ordem, criado_por, caixa_id)
  select v_empresa, v_venda, x.forma_pagamento, x.valor, x.ordem, (select auth.uid()), v_caixa
    from private.venda_mista_validar_pagamentos(p_pagamentos) x
   order by x.ordem;

  perform private.taxas_registrar('pdv',p.id,p_pagamentos->(p.ordem-1)) from public.vendas_pagamentos p where p.empresa_id=v_empresa and p.venda_id=v_venda;
  venda_id := v_venda;
  numero_venda := v_numero;
  return next;
end;
$function$
;

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
;

CREATE OR REPLACE FUNCTION public.pdv_comanda_finalizar(p_sessao_id uuid, p_chave_idempotencia text, p_pagamentos jsonb DEFAULT NULL::jsonb, p_nota_prazo boolean DEFAULT false, p_cpf_nota text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa    uuid := private.exigir_empresa_ativa();
  v_chave      text := btrim(coalesce(p_chave_idempotencia, ''));
  v_prazo      boolean := coalesce(p_nota_prazo, false);
  v_sessao     public.pdv_comandas_sessoes%rowtype;
  v_cpf_nota   text;
  v_qtd_itens  integer;
  v_total      numeric(14,2);
  v_total_iv   numeric(14,2);
  v_qtd_pag    integer;
  v_qtd_formas integer;
  v_unica      text;
  v_soma       numeric;
  v_forma      text;
  v_numero     bigint;
  v_venda      uuid;
  v_iv         bigint;
  v_titulo     uuid;
  v_venc       date;
  v_caixa      uuid;
  r            record;
begin
  if not private.perm('pdv') then
    raise exception 'Você não tem permissão para registrar vendas.' using errcode = '42501';
  end if;
  if p_sessao_id is null then
    raise exception 'Informe a comanda.';
  end if;
  if length(v_chave) < 8 or length(v_chave) > 100 then
    raise exception 'Chave de finalização inválida (8 a 100 caracteres).';
  end if;

  -- trava a sessão: duplo clique/duas abas serializam aqui; a segunda chamada vê a comanda já finalizada
  select * into v_sessao
    from public.pdv_comandas_sessoes s
   where s.id = p_sessao_id and s.empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Comanda não encontrada.';
  end if;

  -- IDEMPOTÊNCIA: mesma chave numa comanda já finalizada devolve a MESMA venda/título (nada novo é criado)
  if v_sessao.status = 'finalizada' then
    if v_sessao.finalizacao_chave = v_chave then
      select v.numero_venda into v_numero from public.vendas v where v.id = v_sessao.venda_id and v.empresa_id = v_empresa;
      select cr.id, cr.vencimento into v_titulo, v_venc
        from public.contas_receber cr
       where cr.empresa_id = v_empresa and cr.venda_id = v_sessao.venda_id and cr.origem = 'nota_prazo';
      select v.forma_pagamento into v_forma from public.vendas v where v.id = v_sessao.venda_id and v.empresa_id = v_empresa;
      return jsonb_build_object('venda_id', v_sessao.venda_id, 'numero_venda', v_numero, 'total', v_sessao.total_final,
                                'forma_pagamento', v_forma, 'titulo_id', v_titulo, 'vencimento', v_venc, 'repetida', true);
    end if;
    raise exception 'Esta comanda já foi finalizada.';
  end if;
  if v_sessao.status = 'cancelada' then
    raise exception 'Esta comanda foi cancelada.';
  end if;

  -- Migration 032: finalizar (paga ou a prazo) é uma VENDA do PDV: exige Caixa PDV aberto. Fica depois do
  -- replay idempotente acima (repetir uma finalização já feita nunca falha por caixa fechado depois).
  v_caixa := private.caixa_exigir_aberto('PDV');

  -- a chave nunca pode ter sido usada por OUTRA comanda
  if exists (select 1 from public.pdv_comandas_sessoes s
              where s.empresa_id = v_empresa and s.finalizacao_chave = v_chave and s.id <> v_sessao.id) then
    raise exception 'Chave de finalização já utilizada em outra comanda. Gere uma nova chave.';
  end if;

  -- modo: OU pagamentos (venda paga) OU nota a prazo (título); nunca os dois, nunca nenhum
  if v_prazo then
    if p_pagamentos is not null and not (jsonb_typeof(p_pagamentos) = 'array' and jsonb_array_length(p_pagamentos) = 0) then
      raise exception 'Nota a Prazo não recebe pagamentos: o valor fica a receber.';
    end if;
  else
    if p_pagamentos is null then
      raise exception 'Informe os pagamentos da comanda ou finalize como Nota a Prazo.';
    end if;
  end if;

  -- CPF na nota (opcional) — mesma validação de registrar_venda
  v_cpf_nota := nullif(regexp_replace(coalesce(p_cpf_nota, ''), '[^0-9]', '', 'g'), '');
  if v_cpf_nota is not null and not private.cpf_valido(v_cpf_nota) then
    raise exception 'CPF informado na nota é inválido.';
  end if;

  -- itens ativos (o total vem dos subtotais gravados nos itens: preços já fixados no lançamento)
  select count(*)::integer, coalesce(sum(i.subtotal), 0)
    into v_qtd_itens, v_total
    from public.pdv_comandas_itens i
   where i.empresa_id = v_empresa and i.sessao_id = v_sessao.id and i.status = 'ativo';
  if v_qtd_itens = 0 then
    raise exception 'A comanda não tem itens.';
  end if;
  if v_total <= 0 then
    raise exception 'A comanda não tem valor a cobrar (total zero).';
  end if;

  if v_prazo then
    v_forma := 'Nota a Prazo';
  else
    -- valida os pagamentos (mesma função da Migration 028) ANTES de criar qualquer coisa
    select count(*)::integer, count(distinct x.forma_pagamento)::integer, min(x.forma_pagamento), coalesce(sum(x.valor), 0)
      into v_qtd_pag, v_qtd_formas, v_unica, v_soma
      from private.venda_mista_validar_pagamentos(p_pagamentos) x;
    if round(v_soma * 100)::bigint <> round(v_total * 100)::bigint then
      raise exception 'A soma dos pagamentos (R$ %) não é igual ao total da comanda (R$ %).',
        replace(v_soma::text, '.', ','), replace(v_total::text, '.', ',');
    end if;
    v_forma := case when v_qtd_formas = 1 then v_unica else 'dividido' end;
  end if;

  -- numeração normal de vendas (a linha do contador serializa vendas simultâneas) — igual a registrar_venda
  insert into public.contadores_venda as c (empresa_id, ultimo_numero)
  values (v_empresa, 1)
  on conflict (empresa_id) do update set ultimo_numero = c.ultimo_numero + 1
  returning c.ultimo_numero into v_numero;

  insert into public.vendas (empresa_id, numero_venda, cliente_id, forma_pagamento, total, criado_por, cpf_nota, caixa_id)
  values (v_empresa, v_numero, v_sessao.cliente_id, v_forma, v_total, (select auth.uid()), v_cpf_nota, v_caixa)
  returning id into v_venda;

  -- itens_venda: um por item ativo, na ordem do lançamento. SEM tocar em produtos.quantidade_estoque
  -- (o estoque já foi baixado em cada lançamento).
  for r in
    select i.id, i.produto_id, i.quantidade, i.preco_unitario
      from public.pdv_comandas_itens i
     where i.empresa_id = v_empresa and i.sessao_id = v_sessao.id and i.status = 'ativo'
     order by i.seq
  loop
    insert into public.itens_venda (empresa_id, venda_id, produto_id, quantidade, preco_unitario)
    values (v_empresa, v_venda, r.produto_id, r.quantidade, r.preco_unitario)
    returning id into v_iv;

    update public.pdv_comandas_itens set item_venda_id = v_iv where id = r.id and empresa_id = v_empresa;
  end loop;

  -- defesa: o total da venda tem que ser exatamente a soma dos itens gravados
  select coalesce(sum(iv.subtotal), 0) into v_total_iv
    from public.itens_venda iv where iv.empresa_id = v_empresa and iv.venda_id = v_venda;
  if round(v_total_iv * 100)::bigint <> round(v_total * 100)::bigint then
    raise exception 'Inconsistência no total da venda (itens R$ %, comanda R$ %). Nada foi gravado.', v_total_iv, v_total;
  end if;

  if v_prazo then
    -- venda SEM pagamento recebido + UM título; vencimento = último dia do mês da venda (fuso do negócio)
    v_venc := private.ultimo_dia_do_mes(private.pdv_hoje());
    insert into public.contas_receber (empresa_id, cliente_id, venda_id, origem, valor_original, saldo_aberto, vencimento, criado_por)
    values (v_empresa, v_sessao.cliente_id, v_venda, 'nota_prazo', v_total, v_total, v_venc, (select auth.uid()))
    returning id into v_titulo;
  else
    insert into public.vendas_pagamentos (empresa_id, venda_id, forma_pagamento, valor, ordem, criado_por, caixa_id)
    select v_empresa, v_venda, x.forma_pagamento, x.valor, x.ordem, (select auth.uid()), v_caixa
      from private.venda_mista_validar_pagamentos(p_pagamentos) x
     order by x.ordem;
  end if;

  perform private.taxas_registrar('pdv',p.id,p_pagamentos->(p.ordem-1)) from public.vendas_pagamentos p where p.empresa_id=v_empresa and p.venda_id=v_venda;

  update public.pdv_comandas_sessoes
     set status = 'finalizada', venda_id = v_venda, finalizada_em = now(), finalizada_por = (select auth.uid()),
         tipo_fechamento = case when v_prazo then 'nota_prazo' else 'pagamento' end,
         finalizacao_chave = v_chave, total_final = v_total
   where id = v_sessao.id and empresa_id = v_empresa;

  -- libera a posição para um novo cliente (histórico fica em pdv_comandas_sessoes/itens)
  update public.pdv_comandas
     set status = 'livre', sessao_atual_id = null
   where id = v_sessao.comanda_id and empresa_id = v_empresa and sessao_atual_id = v_sessao.id;

  return jsonb_build_object('venda_id', v_venda, 'numero_venda', v_numero, 'total', v_total,
                            'forma_pagamento', v_forma, 'titulo_id', v_titulo, 'vencimento', v_venc, 'repetida', false);
end;
$function$
;

-- ==========================================================
-- 002_funcoes_banco.sql
-- PetGestor / ERP PETSHOP — Funções e RPCs (Supabase)
--
-- Reconstrução fiel do estado atual do banco (funções dos schemas
-- private e public), extraída diretamente do Supabase em produção.
-- Não inclui tabelas, policies, triggers, cron jobs ou dados.
--
-- Ordem: funções auxiliares (private) antes das que dependem delas;
-- GRANT/REVOKE ao final, refletindo exatamente as permissões atuais.
-- ==========================================================

-- ==========================================================
-- SCHEMA: private
-- ==========================================================

CREATE OR REPLACE FUNCTION private.florest_cnpj_valido(p_cnpj text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  declare
    d  text := regexp_replace(coalesce(p_cnpj, ''), '\D', '', 'g');
    w1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2];
    w2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
    s  int;
    r  int;
    i  int;
  begin
    if length(d) <> 14 or d ~ '^(\d)\1{13}$' then return false; end if;
    s := 0;
    for i in 1..12 loop s := s + substr(d, i, 1)::int * w1[i]; end loop;
    r := s % 11; r := case when r < 2 then 0 else 11 - r end;
    if r <> substr(d, 13, 1)::int then return false; end if;
    s := 0;
    for i in 1..13 loop s := s + substr(d, i, 1)::int * w2[i]; end loop;
    r := s % 11; r := case when r < 2 then 0 else 11 - r end;
    return r = substr(d, 14, 1)::int;
  end;
  $function$;

CREATE OR REPLACE FUNCTION private.florest_normalizar_cadastro(p_dados jsonb, p_modo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
  declare
    v_estrito boolean := (p_modo = 'estrito');
    v_tol     boolean := (p_modo = 'tolerante');
    v_ufs     text[]  := array['AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO'];
    v_out     jsonb   := '{}'::jsonb;
    rec       record;
    c         text;
    r         text;
    d         text;
    ok        boolean;
  begin
    if p_modo is null or p_modo not in ('estrito','parcial','tolerante') then
      raise exception 'CE000: modo inválido.' using errcode = 'CE000';
    end if;
    if p_dados is null or jsonb_typeof(p_dados) <> 'object' then
      if v_tol then return v_out; end if;
      raise exception 'CE001: dados inválidos.' using errcode = 'CE001';
    end if;

    -- campos de texto livre
    for rec in
      select * from (values
        ('nome',         2, 200, true),
        ('razao_social', 2, 200, true),
        ('responsavel',  2, 200, true),
        ('logradouro',   2, 200, true),
        ('numero',       1,  20, true),
        ('complemento',  1, 100, false),
        ('bairro',       2, 100, true),
        ('cidade',       2, 100, true)
      ) as t(k, mn, mx, obr)
    loop
      c := rec.k; r := null; ok := true;
      if p_dados ? c and jsonb_typeof(p_dados -> c) <> 'null' then
        if jsonb_typeof(p_dados -> c) <> 'string' then
          ok := false;
        else
          r := regexp_replace(btrim(p_dados ->> c), '\s+', ' ', 'g');
          if r = '' then
            r := null;
          elsif r ~ '[[:cntrl:]]' or char_length(r) < rec.mn or char_length(r) > rec.mx then
            ok := false;
          end if;
        end if;
      end if;
      if not ok then
        if v_tol then r := null; else raise exception 'CE001: dado inválido ou ausente: %', c using errcode = 'CE001'; end if;
      end if;
      if r is null and v_estrito and rec.obr then
        raise exception 'CE001: dado inválido ou ausente: %', c using errcode = 'CE001';
      end if;
      if r is not null then v_out := v_out || jsonb_build_object(c, r); end if;
    end loop;

    -- campos com formato: cnpj, telefone, cep, uf
    foreach c in array array['cnpj','telefone','cep','uf'] loop
      r := null; ok := true;
      if p_dados ? c and jsonb_typeof(p_dados -> c) <> 'null' then
        if jsonb_typeof(p_dados -> c) <> 'string' then
          ok := false;
        else
          r := btrim(p_dados ->> c);
          if r = '' then
            r := null;
          elsif c = 'uf' then
            r := upper(r);
            ok := (r = any (v_ufs));
          else
            d := regexp_replace(r, '\D', '', 'g');
            if c = 'telefone' and length(d) in (12, 13) and left(d, 2) = '55' then d := substr(d, 3); end if;
            r := d;
            if c = 'cnpj' then
              ok := private.florest_cnpj_valido(d);
            elsif c = 'telefone' then
              ok := (d ~ '^[1-9][1-9]\d{8,9}$');
            else
              ok := (d ~ '^\d{8}$' and d <> '00000000');
            end if;
          end if;
        end if;
      end if;
      if not ok then
        if v_tol then r := null; else raise exception 'CE001: dado inválido ou ausente: %', c using errcode = 'CE001'; end if;
      end if;
      if r is null and v_estrito then
        raise exception 'CE001: dado inválido ou ausente: %', c using errcode = 'CE001';
      end if;
      if r is not null then v_out := v_out || jsonb_build_object(c, r); end if;
    end loop;

    return v_out;
  end;
  $function$;

CREATE OR REPLACE FUNCTION private.florest_sistema_remoto(p_slug text, p_exigir_ativo boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  declare
    v_s public.florest_sistemas%rowtype;
  begin
    if p_slug is null or p_slug !~ '^[a-z][a-z0-9_]{1,31}$' then
      raise exception 'FC001: sistema não encontrado.' using errcode = 'FC001';
    end if;
    select * into v_s from public.florest_sistemas where slug = p_slug;
    if not found then
      raise exception 'FC001: sistema não encontrado.' using errcode = 'FC001';
    end if;
    if v_s.modo_sync <> 'remoto' then
      raise exception 'FC002: sistema não é remoto.' using errcode = 'FC002';
    end if;
    if p_exigir_ativo and not v_s.ativo then
      raise exception 'FC003: sistema inativo.' using errcode = 'FC003';
    end if;
    return v_s.id;
  end;
  $function$;

CREATE OR REPLACE FUNCTION private.florest_criar_cadastro_remoto(p_sis uuid, p_ref text, p_dados jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
  declare
    v_cli uuid;
    v_ass uuid;
  begin
    insert into public.florest_clientes (nome_empresa, razao_social, responsavel, telefone, email, cnpj, cep, logradouro, numero, complemento, bairro, cidade, uf)
    values (p_dados ->> 'nome', p_dados ->> 'razao_social', p_dados ->> 'responsavel', p_dados ->> 'telefone', p_dados ->> 'email', p_dados ->> 'cnpj',
            p_dados ->> 'cep', p_dados ->> 'logradouro', p_dados ->> 'numero', p_dados ->> 'complemento', p_dados ->> 'bairro', p_dados ->> 'cidade', p_dados ->> 'uf')
    returning id into v_cli;

    insert into public.florest_assinaturas (cliente_id, sistema_id, status_conta, status_pagamento, ref_externa)
    values (v_cli, p_sis, 'pendente', 'em_dia', p_ref)
    returning id into v_ass;

    return jsonb_build_object('assinatura_id', v_ass, 'cliente_id', v_cli);
  end;
  $function$;

CREATE OR REPLACE FUNCTION private.florest_set_atualizado_em()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
  begin
    new.atualizado_em := now();
    return new;
  end;
  $function$;

-- ==========================================================
-- SCHEMA: public
-- ==========================================================

CREATE OR REPLACE FUNCTION public.admin_atualizar_assinatura(p_assinatura_id uuid, p_status_conta text, p_status_pagamento text, p_vencimento date, p_valor_mensal numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from public.admins where id = auth.uid()) then
    raise exception 'Acesso restrito ao administrador.';
  end if;

  update public.florest_assinaturas
  set status_conta = p_status_conta, status_pagamento = p_status_pagamento,
      vencimento = p_vencimento, valor_mensal = p_valor_mensal
  where id = p_assinatura_id;

  update public.empresas
  set bloqueado = (p_status_conta <> 'aprovado'), status_conta = p_status_conta, vencimento = p_vencimento
  where assinatura_id = p_assinatura_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_atualizar_cliente(p_cliente_id uuid, p_telefone text, p_cnpj text, p_observacoes text, p_responsavel text, p_email text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from public.admins where id = auth.uid()) then
    raise exception 'Acesso restrito ao administrador.';
  end if;

  update public.florest_clientes
  set telefone = p_telefone, cnpj = p_cnpj, observacoes = p_observacoes,
      responsavel = p_responsavel, email = p_email
  where id = p_cliente_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_atualizar_cliente_completo(p_cliente_id uuid, p_dados jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  declare
    v_in    jsonb;
    v_n     jsonb;
    v_email text;
    v_obs   text;
  begin
    if not exists (select 1 from public.admins where id = auth.uid()) then
      raise exception 'Acesso restrito ao administrador.';
    end if;
    if p_cliente_id is null or p_dados is null or jsonb_typeof(p_dados) <> 'object' or char_length(p_dados::text) > 6000
       or exists (select 1 from jsonb_object_keys(p_dados) k where k <> all (array['nome_empresa','razao_social','cnpj','responsavel','telefone',
                                                    'email','observacoes','cep','logradouro','numero','complemento','bairro','cidade','uf'])) then
      raise exception 'CE002: campos não permitidos.' using errcode = 'CE002';
    end if;
    if not exists (select 1 from public.florest_clientes where id = p_cliente_id) then
      raise exception 'CE004: cliente não encontrado.' using errcode = 'CE004';
    end if;

    v_in := p_dados - 'nome_empresa' - 'email' - 'observacoes';
    if p_dados ? 'nome_empresa' then v_in := v_in || jsonb_build_object('nome', p_dados -> 'nome_empresa'); end if;
    v_n := private.florest_normalizar_cadastro(v_in, 'parcial');
    if p_dados ? 'nome_empresa' and (v_n ->> 'nome') is null then
      raise exception 'CE001: dado inválido ou ausente: nome_empresa' using errcode = 'CE001';
    end if;

    if p_dados ? 'email' then
      if jsonb_typeof(p_dados -> 'email') not in ('string','null') then
        raise exception 'CE001: dado inválido ou ausente: email' using errcode = 'CE001';
      end if;
      v_email := lower(nullif(btrim(p_dados ->> 'email'), ''));
      if v_email is not null and (char_length(v_email) > 320 or v_email !~ '^[^\s@]{1,64}@[^\s@]{1,255}$') then
        raise exception 'CE001: dado inválido ou ausente: email' using errcode = 'CE001';
      end if;
    end if;
    if p_dados ? 'observacoes' then
      if jsonb_typeof(p_dados -> 'observacoes') not in ('string','null') then
        raise exception 'CE001: dado inválido ou ausente: observacoes' using errcode = 'CE001';
      end if;
      v_obs := nullif(btrim(p_dados ->> 'observacoes'), '');
      if v_obs is not null and char_length(v_obs) > 2000 then
        raise exception 'CE001: dado inválido ou ausente: observacoes' using errcode = 'CE001';
      end if;
    end if;

    update public.florest_clientes set
      nome_empresa = case when p_dados ? 'nome_empresa' then v_n ->> 'nome'         else nome_empresa end,
      razao_social = case when p_dados ? 'razao_social' then v_n ->> 'razao_social' else razao_social end,
      cnpj         = case when p_dados ? 'cnpj'         then v_n ->> 'cnpj'         else cnpj         end,
      responsavel  = case when p_dados ? 'responsavel'  then v_n ->> 'responsavel'  else responsavel  end,
      telefone     = case when p_dados ? 'telefone'     then v_n ->> 'telefone'     else telefone     end,
      email        = case when p_dados ? 'email'        then v_email                else email        end,
      observacoes  = case when p_dados ? 'observacoes'  then v_obs                  else observacoes  end,
      cep          = case when p_dados ? 'cep'          then v_n ->> 'cep'          else cep          end,
      logradouro   = case when p_dados ? 'logradouro'   then v_n ->> 'logradouro'   else logradouro   end,
      numero       = case when p_dados ? 'numero'       then v_n ->> 'numero'       else numero       end,
      complemento  = case when p_dados ? 'complemento'  then v_n ->> 'complemento'  else complemento  end,
      bairro       = case when p_dados ? 'bairro'       then v_n ->> 'bairro'       else bairro       end,
      cidade       = case when p_dados ? 'cidade'       then v_n ->> 'cidade'       else cidade       end,
      uf           = case when p_dados ? 'uf'           then v_n ->> 'uf'           else uf           end
    where id = p_cliente_id;
  end;
  $function$;

CREATE OR REPLACE FUNCTION public.admin_atualizar_licenca(p_empresa_id uuid, p_vencimento date, p_bloqueado boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from public.admins where id = auth.uid()) then
    raise exception 'Acesso restrito ao administrador.';
  end if;

  update public.empresas
  set vencimento = p_vencimento, bloqueado = p_bloqueado
  where id = p_empresa_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_listar_clientes()
 RETURNS TABLE(cliente_id uuid, nome_empresa text, responsavel text, telefone text, email text, cnpj text, observacoes text, sistema text, assinatura_id uuid, status_conta text, status_pagamento text, vencimento date, dias_restantes integer, valor_mensal numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from public.admins where id = auth.uid()) then
    raise exception 'Acesso restrito ao administrador.';
  end if;

  return query
  select
    c.id, c.nome_empresa, c.responsavel, c.telefone, c.email, c.cnpj, c.observacoes,
    s.nome,
    a.id,
    a.status_conta, a.status_pagamento, a.vencimento,
    (a.vencimento - current_date)::integer,
    a.valor_mensal
  from public.florest_clientes c
  join public.florest_assinaturas a on a.cliente_id = c.id
  join public.florest_sistemas s on s.id = a.sistema_id
  order by
    case a.status_conta when 'pendente' then 0 when 'aprovado' then 1 else 2 end,
    a.vencimento asc nulls last;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_listar_clientes_completo()
 RETURNS TABLE(cliente_id uuid, nome_empresa text, razao_social text, responsavel text, telefone text, email text, cnpj text, observacoes text, cep text, logradouro text, numero text, complemento text, bairro text, cidade text, uf text, cadastrado_em timestamp with time zone, sistema text, assinatura_id uuid, status_conta text, status_pagamento text, vencimento date, dias_restantes integer, valor_mensal numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  begin
    if not exists (select 1 from public.admins where id = auth.uid()) then
      raise exception 'Acesso restrito ao administrador.';
    end if;
    return query
    select c.id, c.nome_empresa, c.razao_social, c.responsavel, c.telefone, c.email, c.cnpj,
           c.observacoes, c.cep, c.logradouro, c.numero, c.complemento, c.bairro, c.cidade, c.uf,
           c.criado_em, s.nome, a.id, a.status_conta, a.status_pagamento,
           a.vencimento, (a.vencimento - current_date)::integer, a.valor_mensal
      from public.florest_clientes c
      join public.florest_assinaturas a on a.cliente_id = c.id
      join public.florest_sistemas s on s.id = a.sistema_id
     order by case a.status_conta when 'pendente' then 0 when 'aprovado' then 1 else 2 end,
              a.vencimento asc nulls last;
  end;
  $function$;

CREATE OR REPLACE FUNCTION public.admin_listar_empresas()
 RETURNS TABLE(empresa_id uuid, nome text, email_responsavel text, vencimento date, dias_restantes integer, bloqueado boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from public.admins where id = auth.uid()) then
    raise exception 'Acesso restrito ao administrador.';
  end if;

  return query
  select
    e.id,
    e.nome,
    u.email::text,
    e.vencimento,
    (e.vencimento - current_date)::integer,
    e.bloqueado
  from public.empresas e
  left join public.perfis p on p.empresa_id = e.id
  left join auth.users u on u.id = p.id
  order by e.vencimento asc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_listar_sync()
 RETURNS TABLE(assinatura_id uuid, sistema_slug text, modo_sync text, revisao bigint, sync_status text, sync_erro text, sync_em timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  begin
    if not exists (select 1 from public.admins where id = auth.uid()) then
      raise exception 'Acesso restrito ao administrador.';
    end if;
    return query
      select a.id, s.slug, s.modo_sync, a.revisao, a.sync_status, a.sync_erro, a.sync_em
        from public.florest_assinaturas a
        join public.florest_sistemas s on s.id = a.sistema_id;
  end;
  $function$;

CREATE OR REPLACE FUNCTION public.bloquear_vencidos()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update public.florest_assinaturas
  set status_conta = 'bloqueado', status_pagamento = 'atrasado'
  where vencimento < (current_date - 2) and status_conta = 'aprovado';

  update public.empresas e
  set bloqueado = true
  from public.florest_assinaturas a
  where e.assinatura_id = a.id
    and a.vencimento < (current_date - 2)
    and a.status_conta = 'bloqueado';
$function$;

CREATE OR REPLACE FUNCTION public.dadosjah_obter_credenciais(p_empresa_id uuid)
 RETURNS TABLE(email text, senha text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
begin
  return query
  select c.dadosjah_email, vs.decrypted_secret
  from public.dadosjah_credenciais c
  join vault.decrypted_secrets vs on vs.id = c.dadosjah_password_secret_id
  where c.empresa_id = p_empresa_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fiscal_emitir_nota(p_venda_id uuid)
 RETURNS SETOF documentos_fiscais
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_empresa_id uuid;
  v_valor_produtos numeric(10,2);
  v_valor_servicos numeric(10,2);
begin
  select empresa_id into v_empresa_id from public.perfis where id = auth.uid();
  if v_empresa_id is null then
    raise exception 'Usuário sem empresa vinculada.';
  end if;

  if not exists (select 1 from public.vendas where id = p_venda_id and empresa_id = v_empresa_id) then
    raise exception 'Venda não encontrada para esta empresa.';
  end if;

  select coalesce(sum(iv.subtotal), 0) into v_valor_produtos
  from public.itens_venda iv
  join public.produtos p on p.id = iv.produto_id
  where iv.venda_id = p_venda_id and coalesce(p.tipo_fiscal, 'produto') = 'produto';

  select coalesce(sum(iv.subtotal), 0) into v_valor_servicos
  from public.itens_venda iv
  join public.produtos p on p.id = iv.produto_id
  where iv.venda_id = p_venda_id and p.tipo_fiscal = 'servico';

  if v_valor_produtos > 0
     and not exists (select 1 from public.documentos_fiscais where venda_id = p_venda_id and tipo_documento = 'nfce' and status <> 'cancelada') then
    insert into public.documentos_fiscais (empresa_id, venda_id, tipo_documento, status, valor)
    values (v_empresa_id, p_venda_id, 'nfce', 'nao_emitida', v_valor_produtos);
  end if;

  if v_valor_servicos > 0
     and not exists (select 1 from public.documentos_fiscais where venda_id = p_venda_id and tipo_documento = 'nfse' and status <> 'cancelada') then
    insert into public.documentos_fiscais (empresa_id, venda_id, tipo_documento, status, valor)
    values (v_empresa_id, p_venda_id, 'nfse', 'nao_emitida', v_valor_servicos);
  end if;

  return query select * from public.documentos_fiscais where venda_id = p_venda_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_empresa_id uuid;
  v_numero_final bigint;
begin
  select empresa_id into v_empresa_id from public.perfis where id = auth.uid();
  if v_empresa_id is null then
    raise exception 'Usuário sem empresa vinculada.';
  end if;

  if p_ultimo_numero is null or p_ultimo_numero < 0 then
    raise exception 'Número inválido.';
  end if;

  -- Insere se não existir; se já existir, SÓ eleva o valor (greatest) — nunca diminui,
  -- de forma atômica e segura contra concorrência (upsert é uma única operação no Postgres).
  insert into public.contadores_fiscais (empresa_id, tipo_documento, serie, ultimo_numero)
  values (v_empresa_id, p_tipo_documento, p_serie, p_ultimo_numero)
  on conflict (empresa_id, tipo_documento, serie)
    do update set ultimo_numero = greatest(contadores_fiscais.ultimo_numero, excluded.ultimo_numero)
  returning ultimo_numero into v_numero_final;

  return v_numero_final;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fiscal_proximo_numero(p_empresa_id uuid, p_tipo_documento text, p_serie text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_numero bigint;
begin
  insert into public.contadores_fiscais (empresa_id, tipo_documento, serie, ultimo_numero)
  values (p_empresa_id, p_tipo_documento, p_serie, 1)
  on conflict (empresa_id, tipo_documento, serie)
    do update set ultimo_numero = contadores_fiscais.ultimo_numero + 1
  returning ultimo_numero into v_numero;

  return v_numero;
end;
$function$;

CREATE OR REPLACE FUNCTION public.florest_admin_assinatura_preparar(p_admin_id uuid, p_assinatura_id uuid, p_acao text, p_dados jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  declare
    v_a        public.florest_assinaturas%rowtype;
    v_s        public.florest_sistemas%rowtype;
    v_hoje     date := (now() at time zone 'America/Sao_Paulo')::date;
    v_status   text;
    v_pag      text;
    v_venc     date;
    v_valor    numeric;
    v_remoto   boolean;
    v_muda_sync  boolean;
    v_muda_dados boolean;
    v_precisa    boolean;
    v_rev      bigint;
    v_venc_txt text;
  begin
    -- 1) só administrador (checado no banco, com o uid validado pela Edge Function)
    if p_admin_id is null or not exists (select 1 from public.admins where id = p_admin_id) then
      raise exception 'FA001: acesso restrito ao administrador.' using errcode = 'FA001';
    end if;
    if p_assinatura_id is null or p_acao is null
       or p_acao not in ('aprovar','bloquear','reativar','renovar','atualizar','sincronizar') then
      raise exception 'FA004: dados inválidos.' using errcode = 'FA004';
    end if;

    -- 2) trava a assinatura: comandos simultâneos são serializados
    select * into v_a from public.florest_assinaturas where id = p_assinatura_id for update;
    if not found then
      raise exception 'FA002: assinatura não encontrada.' using errcode = 'FA002';
    end if;
    select * into v_s from public.florest_sistemas where id = v_a.sistema_id;
    v_remoto := (v_s.modo_sync = 'remoto');

    -- 3) novo estado (parte do estado atual)
    v_status := v_a.status_conta;
    v_pag    := v_a.status_pagamento;
    v_venc   := v_a.vencimento;
    v_valor  := v_a.valor_mensal;

    if p_acao = 'aprovar' then
      if v_a.status_conta = 'bloqueado' then
        raise exception 'FA003: assinatura bloqueada — use Reativar.' using errcode = 'FA003';
      end if;
      v_status := 'aprovado'; v_pag := 'em_dia';
      v_venc := coalesce(v_a.vencimento, v_hoje + 30);
    elsif p_acao = 'bloquear' then
      v_status := 'bloqueado';
    elsif p_acao = 'reativar' then
      if v_a.status_conta = 'pendente' then
        raise exception 'FA003: assinatura pendente — use Aprovar.' using errcode = 'FA003';
      end if;
      v_status := 'aprovado'; v_pag := 'em_dia';
      -- fora da tolerância do sistema (ou sem vencimento): renova +30 a partir de hoje
      v_venc := case when v_a.vencimento is null or v_a.vencimento < v_hoje - v_s.tolerancia_dias
                     then v_hoje + 30 else v_a.vencimento end;
    elsif p_acao = 'renovar' then
      if v_a.status_conta <> 'aprovado' then
        raise exception 'FA003: só é possível renovar assinatura aprovada.' using errcode = 'FA003';
      end if;
      v_pag  := 'em_dia';
      v_venc := greatest(coalesce(v_a.vencimento, v_hoje), v_hoje) + 30;
    elsif p_acao = 'atualizar' then
      if p_dados is null or jsonb_typeof(p_dados) <> 'object'
         or not (p_dados ? 'status_conta' and p_dados ? 'status_pagamento' and p_dados ? 'vencimento' and p_dados ? 'valor_mensal') then
        raise exception 'FA004: dados inválidos.' using errcode = 'FA004';
      end if;
      if jsonb_typeof(p_dados->'status_conta') <> 'string' or jsonb_typeof(p_dados->'status_pagamento') <> 'string'
         or (p_dados->>'status_conta') not in ('pendente','aprovado','bloqueado')
         or (p_dados->>'status_pagamento') not in ('em_dia','atrasado')
         or jsonb_typeof(p_dados->'vencimento') not in ('string','null')
         or jsonb_typeof(p_dados->'valor_mensal') not in ('number','null') then
        raise exception 'FA004: dados inválidos.' using errcode = 'FA004';
      end if;
      v_status := p_dados->>'status_conta';
      v_pag    := p_dados->>'status_pagamento';
      v_venc_txt := p_dados->>'vencimento';
      if v_venc_txt is null then
        v_venc := null;
      else
        if v_venc_txt !~ '^\d{4}-\d{2}-\d{2}$' then
          raise exception 'FA004: dados inválidos.' using errcode = 'FA004';
        end if;
        begin
          v_venc := v_venc_txt::date;
        exception when others then
          raise exception 'FA004: dados inválidos.' using errcode = 'FA004';
        end;
      end if;
      if jsonb_typeof(p_dados->'valor_mensal') = 'number' then
        v_valor := (p_dados->>'valor_mensal')::numeric;
        if v_valor < 0 then raise exception 'FA004: dados inválidos.' using errcode = 'FA004'; end if;
      else
        v_valor := null;
      end if;
      -- aprovado sem vencimento: mesmo padrão do Aprovar (hoje + 30)
      if v_status = 'aprovado' and v_venc is null then v_venc := v_hoje + 30; end if;
    end if;
    -- 'sincronizar': nenhum dado muda; só reenvia o estado atual (idempotente pela revisão)

    v_muda_sync  := (v_status is distinct from v_a.status_conta) or (v_venc is distinct from v_a.vencimento);
    v_muda_dados := v_muda_sync or (v_pag is distinct from v_a.status_pagamento) or (v_valor is distinct from v_a.valor_mensal);
    v_precisa    := v_remoto and (v_muda_sync or coalesce(v_a.sync_status, '') <> 'ok');

    -- 4) pré-condições do envio remoto: falha ANTES de alterar qualquer coisa
    if v_precisa then
      if not v_s.ativo then
        raise exception 'FA005: sistema inativo.' using errcode = 'FA005';
      end if;
      if v_s.sync_url is null then
        raise exception 'FA005: sync_url não configurada.' using errcode = 'FA005';
      end if;
      if v_a.ref_externa is null or v_a.ref_externa !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise exception 'FA005: assinatura sem vínculo (ref_externa) com o sistema remoto.' using errcode = 'FA005';
      end if;
    end if;

    -- 5) aplica na Central
    if v_muda_dados then
      update public.florest_assinaturas
         set status_conta = v_status, status_pagamento = v_pag, vencimento = v_venc, valor_mensal = v_valor
       where id = v_a.id;
    end if;

    v_rev := v_a.revisao;
    if v_precisa then
      if v_muda_sync or v_a.revisao < 1 then v_rev := v_a.revisao + 1; end if;   -- reenvio sem mudança mantém a MESMA revisão
      update public.florest_assinaturas
         set revisao = v_rev, sync_status = 'pendente', sync_erro = null
       where id = v_a.id;
    end if;

    -- 6) PetGestor (local): mesma regra de admin_atualizar_assinatura sobre `empresas`
    if not v_remoto then
      update public.empresas
         set bloqueado = (v_status <> 'aprovado'), status_conta = v_status, vencimento = v_venc
       where assinatura_id = v_a.id;
    end if;

    return jsonb_build_object(
      'ok', true,
      'assinatura_id', v_a.id,
      'sistema_slug', v_s.slug,
      'modo_sync', v_s.modo_sync,
      'sync_url', case when v_precisa then v_s.sync_url else null end,
      'ref_externa', v_a.ref_externa,
      'revisao', v_rev,
      'status_conta', v_status,
      'status_pagamento', v_pag,
      'vencimento', v_venc,
      'valor_mensal', v_valor,
      'mudou', v_muda_dados,
      'precisa_sync', v_precisa);
  end;
  $function$;

CREATE OR REPLACE FUNCTION public.florest_admin_assinatura_sync_resultado(p_assinatura_id uuid, p_revisao bigint, p_ok boolean, p_erro text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  declare
    v_a public.florest_assinaturas%rowtype;
  begin
    if p_assinatura_id is null or p_revisao is null or p_ok is null then
      raise exception 'FA004: dados inválidos.' using errcode = 'FA004';
    end if;
    select * into v_a from public.florest_assinaturas where id = p_assinatura_id for update;
    if not found then
      return jsonb_build_object('registrado', false, 'motivo', 'nao_encontrada');
    end if;
    -- resultado de uma revisão já superada não sobrescreve o estado da revisão mais nova
    if v_a.revisao <> p_revisao then
      return jsonb_build_object('registrado', false, 'motivo', 'revisao_superada');
    end if;
    update public.florest_assinaturas
       set sync_status = case when p_ok then 'ok' else 'erro' end,
           sync_erro   = case when p_ok then null else left(coalesce(nullif(btrim(p_erro), ''), 'erro'), 200) end,
           sync_em     = now()
     where id = v_a.id;
    return jsonb_build_object('registrado', true);
  end;
  $function$;

CREATE OR REPLACE FUNCTION public.florest_evento_concluir(p_slug text, p_event_id uuid, p_estado text, p_resultado jsonb DEFAULT NULL::jsonb, p_erro text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  declare
    v_sis  uuid;
    v_ev   public.florest_eventos_recebidos%rowtype;
    v_erro text;
  begin
    v_sis := private.florest_sistema_remoto(p_slug, false);      -- concluir também vale se o sistema foi desativado no meio
    if p_estado is null or p_estado not in ('processado', 'descartado', 'erro') then
      raise exception 'FC007: estado inválido.' using errcode = 'FC007';
    end if;
    if p_event_id is null
       or (p_resultado is not null and (jsonb_typeof(p_resultado) <> 'object' or char_length(p_resultado::text) > 2000)) then
      raise exception 'FC004: dados inválidos.' using errcode = 'FC004';
    end if;

    -- só um código curto: remove tudo que não seja [A-Za-z0-9_.:-] e corta em 100 (nunca guarda texto livre/stack/segredo)
    v_erro := nullif(left(regexp_replace(coalesce(p_erro, ''), '[^A-Za-z0-9_.:-]', '', 'g'), 100), '');

    select * into v_ev
      from public.florest_eventos_recebidos
     where sistema_id = v_sis and event_id = p_event_id
     for update;
    if not found then
      raise exception 'FC006: evento não encontrado.' using errcode = 'FC006';
    end if;

    if v_ev.estado in ('processado', 'descartado') then
      return jsonb_build_object('ok', true, 'alterado', false, 'estado', v_ev.estado);   -- final: não reverte
    end if;

    update public.florest_eventos_recebidos
       set estado        = p_estado,
           resultado     = p_resultado,
           erro          = case when p_estado = 'erro' then coalesce(v_erro, 'erro_nao_informado') else null end,
           atualizado_em = now()
     where id = v_ev.id;
    return jsonb_build_object('ok', true, 'alterado', true, 'estado', p_estado);
  end;
  $function$;

CREATE OR REPLACE FUNCTION public.florest_evento_registrar(p_slug text, p_event_id uuid, p_tipo text, p_ref_externa text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  declare
    v_sis uuid;
    v_ev  public.florest_eventos_recebidos%rowtype;
  begin
    v_sis := private.florest_sistema_remoto(p_slug, true);
    if p_event_id is null
       or p_tipo is null or p_tipo !~ '^[a-z][a-z0-9_]{1,49}$'
       or p_ref_externa is null or p_ref_externa !~ '^[A-Za-z0-9_.:-]{1,100}$' then
      raise exception 'FC004: dados inválidos.' using errcode = 'FC004';
    end if;

    -- Tentativa de criar. Se duas chamadas chegam juntas, a segunda ESPERA a primeira (índice único) e cai no "else".
    insert into public.florest_eventos_recebidos (sistema_id, event_id, tipo, ref_externa, estado)
    values (v_sis, p_event_id, p_tipo, p_ref_externa, 'processando')
    on conflict (sistema_id, event_id) do nothing
    returning * into v_ev;
    if found then
      return jsonb_build_object('deve_processar', true, 'estado', 'processando');
    end if;

    -- já existe: trava a linha (serializa concorrentes; relê a versão mais recente após a espera)
    select * into v_ev
      from public.florest_eventos_recebidos
     where sistema_id = v_sis and event_id = p_event_id
     for update;

    -- o mesmo event_id não pode mudar de assunto
    if v_ev.tipo <> p_tipo or v_ev.ref_externa <> p_ref_externa then
      raise exception 'FC005: event_id já existe com outros dados.' using errcode = 'FC005';
    end if;

    if v_ev.estado in ('processado', 'descartado') then
      return jsonb_build_object('deve_processar', false, 'estado', v_ev.estado);
    end if;

    if v_ev.estado = 'erro' or (v_ev.estado = 'processando' and v_ev.atualizado_em < now() - interval '5 minutes') then
      update public.florest_eventos_recebidos
         set estado = 'processando', tentativas = tentativas + 1, atualizado_em = now()
       where id = v_ev.id;
      return jsonb_build_object('deve_processar', true, 'estado', 'processando');
    end if;

    return jsonb_build_object('deve_processar', false, 'estado', 'processando');
  end;
  $function$;

CREATE OR REPLACE FUNCTION public.florest_registrar_cadastro(p_slug text, p_ref_externa text, p_dados jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  declare
    v_sis      uuid;
    v_ref      text := btrim(coalesce(p_ref_externa, ''));
    v_nome     text;
    v_resp     text;
    v_email    text;
    v_cnpj     text;
    v_tel      text;
    v_conf     boolean := false;
    v_origem   text;
    v_dados    jsonb;
    v_ass      uuid;
    v_pend     public.florest_cadastros_pendentes%rowtype;
    v_novo     jsonb;
    v_ext      jsonb;
  begin
    v_sis := private.florest_sistema_remoto(p_slug, true);
    if v_ref !~ '^[A-Za-z0-9_.:-]{1,100}$' or p_dados is null or jsonb_typeof(p_dados) <> 'object' then
      raise exception 'FC004: dados inválidos.' using errcode = 'FC004';
    end if;

    -- ---- lista fixa de campos (whitelist), sempre tratados como TEXTO NÃO CONFIÁVEL ----
    v_nome  := nullif(btrim(case when jsonb_typeof(p_dados -> 'nome')        = 'string' then p_dados ->> 'nome'        end), '');
    v_resp  := nullif(btrim(case when jsonb_typeof(p_dados -> 'responsavel') = 'string' then p_dados ->> 'responsavel' end), '');
    v_email := lower(nullif(btrim(case when jsonb_typeof(p_dados -> 'email') = 'string' then p_dados ->> 'email'       end), ''));
    v_tel   := nullif(btrim(case when jsonb_typeof(p_dados -> 'telefone')    = 'string' then p_dados ->> 'telefone'    end), '');
    v_cnpj  := nullif(regexp_replace(case when jsonb_typeof(p_dados -> 'cnpj') = 'string' then p_dados ->> 'cnpj' else '' end, '\D', '', 'g'), '');
    if jsonb_typeof(p_dados -> 'email_confirmado') = 'boolean' then
      v_conf := (p_dados ->> 'email_confirmado')::boolean;
    end if;
    if jsonb_typeof(p_dados -> 'criado_em') = 'string' and (p_dados ->> 'criado_em') ~ '^\d{4}-\d{2}-\d{2}T[0-9:.]{5,20}(Z|[+-]\d{2}:\d{2})$' then
      v_origem := p_dados ->> 'criado_em';
    end if;

    if v_nome is null or char_length(v_nome) > 200
       or (v_resp is not null and char_length(v_resp) > 200)
       or (v_tel  is not null and char_length(v_tel)  > 30)
       or (v_email is not null and (char_length(v_email) > 320 or v_email !~ '^[^\s@]{1,64}@[^\s@]{1,255}$')) then
      raise exception 'FC004: dados inválidos.' using errcode = 'FC004';
    end if;
    if v_cnpj is not null and char_length(v_cnpj) <> 14 then
      v_cnpj := null;
    end if;

    -- campos cadastrais novos (razão social, endereço): validados em modo tolerante; inválido/ausente = fica de fora

    v_ext := private.florest_normalizar_cadastro(p_dados, 'tolerante');


    v_dados := jsonb_strip_nulls(jsonb_build_object(
      'nome', v_nome, 'responsavel', v_resp, 'email', v_email, 'email_confirmado', v_conf,
      'cnpj', v_cnpj, 'telefone', v_tel, 'origem_criado_em', v_origem,
      'razao_social', v_ext -> 'razao_social', 'cep', v_ext -> 'cep', 'logradouro', v_ext -> 'logradouro', 'numero', v_ext -> 'numero',
      'complemento', v_ext -> 'complemento', 'bairro', v_ext -> 'bairro', 'cidade', v_ext -> 'cidade', 'uf', v_ext -> 'uf'));

    -- ---- serialização por (sistema, ref): o mesmo cadastro reenviado em paralelo não duplica ----
    perform pg_advisory_xact_lock(hashtextextended('florest_cad_ref:' || v_sis::text || ':' || v_ref, 0));

    -- ---- idempotência: já existe assinatura desta ref neste sistema ----
    select a.id into v_ass
      from public.florest_assinaturas a
     where a.sistema_id = v_sis and a.ref_externa = v_ref;
    if found then
      return jsonb_build_object('acao', 'ja_registrado', 'assinatura_id', v_ass);
    end if;

    -- ---- cadastro pendente antigo desta mesma ref (regra anterior): decisões já tomadas são respeitadas ----
    select * into v_pend
      from public.florest_cadastros_pendentes p
     where p.sistema_id = v_sis and p.ref_externa = v_ref
     for update;
    if found and v_pend.estado <> 'aguardando_decisao' then
      return jsonb_build_object('acao', 'ja_registrado', 'cadastro_pendente_id', v_pend.id, 'estado', v_pend.estado);
    end if;

    -- ---- cliente novo + assinatura PENDENTE, dentro do contexto deste sistema ----
    v_novo := private.florest_criar_cadastro_remoto(v_sis, v_ref, v_dados);

    if v_pend.id is not null then
      update public.florest_cadastros_pendentes set estado = 'criado_novo', atualizado_em = now() where id = v_pend.id;
    end if;

    return jsonb_build_object('acao', 'assinatura_criada', 'assinatura_id', v_novo -> 'assinatura_id', 'cliente_id', v_novo -> 'cliente_id');
  end;
  $function$;

CREATE OR REPLACE FUNCTION public.florest_sistema_obter(p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  declare
    v jsonb;
  begin
    if p_slug is null or p_slug !~ '^[a-z][a-z0-9_]{1,31}$' then
      return null;
    end if;
    select jsonb_build_object('slug', s.slug, 'ativo', s.ativo, 'modo_sync', s.modo_sync, 'sync_url', s.sync_url)
      into v
      from public.florest_sistemas s
     where s.slug = p_slug;
    return v;            -- NULL se o sistema não existe
  end;
  $function$;

CREATE OR REPLACE FUNCTION public.notas_entrada_confirmar(p_nota jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_empresa_id uuid;
  v_fornecedor_id uuid;
  v_nota_id uuid;
  v_item jsonb;
  v_produto_id uuid;
  v_qtd_atual numeric(12,4);
  v_qtd_item numeric(12,4);
  v_parcela jsonb;
  v_soma_pagamento numeric(12,2) := 0;
  v_valor_total numeric(12,2);
  v_chave text;
  v_razao_fornecedor text;
  i integer;
begin
  select empresa_id into v_empresa_id from public.perfis where id = auth.uid();
  if v_empresa_id is null then
    raise exception 'Usuário sem empresa vinculada.';
  end if;

  v_chave := p_nota->>'chave_acesso';

  -- Nunca confiar só na validação do navegador: revalida aqui.
  if v_chave is null or v_chave !~ '^[0-9]{44}$' then
    raise exception 'Não foi possível identificar uma chave de acesso válida de 44 dígitos neste XML.';
  end if;

  -- Trava contra a mesma NF-e lançada duas vezes (checagem explícita, com mensagem
  -- amigável, MAIS a constraint UNIQUE(empresa_id, chave_acesso) como garantia final
  -- contra corrida de duplo clique — se as duas checagens simultâneas passarem aqui,
  -- só uma das duas transações consegue inserir; a outra recebe erro de chave duplicada).
  if exists (
    select 1 from public.notas_entrada
    where empresa_id = v_empresa_id and chave_acesso = v_chave
  ) then
    raise exception 'Esta Nota Fiscal já foi lançada.';
  end if;

  v_valor_total := (p_nota->>'valor_total')::numeric;

  -- Valida que o pagamento informado bate com o valor da nota antes de mexer em qualquer coisa
  if p_nota->>'forma_pagamento' = 'a_vista' then
    v_soma_pagamento := (p_nota->'pagamento'->>'valor')::numeric;
  else
    for v_parcela in select * from jsonb_array_elements(p_nota->'pagamento'->'parcelas') loop
      v_soma_pagamento := v_soma_pagamento + (v_parcela->>'valor')::numeric;
    end loop;
  end if;

  if abs(v_soma_pagamento - v_valor_total) > 0.01 then
    raise exception 'A soma do pagamento (%) não confere com o valor total da nota (%).', v_soma_pagamento, v_valor_total;
  end if;

  -- Fornecedor: usa o existente informado, ou cria um novo vinculado a esta empresa
  if (p_nota->'fornecedor'->>'id') is not null then
    v_fornecedor_id := (p_nota->'fornecedor'->>'id')::uuid;
    if not exists (select 1 from public.fornecedores where id = v_fornecedor_id and empresa_id = v_empresa_id) then
      raise exception 'Fornecedor inválido para esta empresa.';
    end if;
    select razao_social into v_razao_fornecedor from public.fornecedores where id = v_fornecedor_id;
  else
    insert into public.fornecedores (
      empresa_id, cnpj, razao_social, nome_fantasia, inscricao_estadual,
      endereco, numero, complemento, bairro, municipio, uf, cep, telefone
    ) values (
      v_empresa_id,
      p_nota->'fornecedor'->>'cnpj',
      p_nota->'fornecedor'->>'razao_social',
      p_nota->'fornecedor'->>'nome_fantasia',
      p_nota->'fornecedor'->>'inscricao_estadual',
      p_nota->'fornecedor'->>'endereco',
      p_nota->'fornecedor'->>'numero',
      p_nota->'fornecedor'->>'complemento',
      p_nota->'fornecedor'->>'bairro',
      p_nota->'fornecedor'->>'municipio',
      p_nota->'fornecedor'->>'uf',
      p_nota->'fornecedor'->>'cep',
      p_nota->'fornecedor'->>'telefone'
    )
    on conflict (empresa_id, cnpj) do update set razao_social = excluded.razao_social
    returning id into v_fornecedor_id;
    v_razao_fornecedor := p_nota->'fornecedor'->>'razao_social';
  end if;

  -- Nota de entrada
  insert into public.notas_entrada (
    empresa_id, fornecedor_id, chave_acesso, numero, serie, data_emissao, data_entrada,
    valor_produtos, valor_desconto, valor_frete, valor_outras_despesas, valor_total,
    forma_pagamento, status, xml_conteudo, confirmado_em
  ) values (
    v_empresa_id, v_fornecedor_id, v_chave, p_nota->>'numero', p_nota->>'serie',
    nullif(p_nota->>'data_emissao','')::timestamptz,
    coalesce(nullif(p_nota->>'data_entrada','')::date, current_date),
    nullif(p_nota->>'valor_produtos','')::numeric,
    coalesce(nullif(p_nota->>'valor_desconto','')::numeric, 0),
    coalesce(nullif(p_nota->>'valor_frete','')::numeric, 0),
    coalesce(nullif(p_nota->>'valor_outras_despesas','')::numeric, 0),
    v_valor_total,
    p_nota->>'forma_pagamento', 'confirmada', p_nota->>'xml_conteudo', now()
  )
  returning id into v_nota_id;

  -- Itens: vincula a produto existente ou cria um novo, e sempre dá entrada no estoque.
  -- Quantidade tratada como NUMERIC(12,4) do início ao fim — NUNCA arredondada.
  for v_item in select * from jsonb_array_elements(p_nota->'itens') loop
    v_qtd_item := (v_item->>'quantidade')::numeric(12,4);

    if (v_item->>'produto_id') is not null then
      v_produto_id := (v_item->>'produto_id')::uuid;
      if not exists (select 1 from public.produtos where id = v_produto_id and empresa_id = v_empresa_id) then
        raise exception 'Produto vinculado inválido para esta empresa.';
      end if;
    else
      -- IMPORTANTE: CFOP, CST/CSOSN, PIS e COFINS do XML pertencem à operação de ENTRADA
      -- do fornecedor e NÃO são copiados para o cadastro do produto (que alimenta a
      -- tributação de SAÍDA usada na emissão de NFC-e). Esses dados da entrada ficam
      -- preservados em notas_entrada_itens para histórico/conferência.
      -- NCM, CEST, origem, GTIN e unidade são atributos do próprio produto (não mudam
      -- conforme a operação), por isso esses sim são aproveitados automaticamente.
      insert into public.produtos (
        empresa_id, nome, codigo, gtin, preco_venda, preco_custo, quantidade_estoque,
        ncm, cest, unidade_comercial, origem_mercadoria, tipo_fiscal
      ) values (
        v_empresa_id,
        v_item->>'descricao',
        nullif(v_item->>'codigo_fornecedor',''),
        nullif(v_item->>'gtin',''),
        (v_item->>'preco_venda')::numeric,
        (v_item->>'valor_unitario')::numeric,
        0,
        nullif(v_item->>'ncm',''), nullif(v_item->>'cest',''),
        nullif(v_item->>'unidade_comercial',''), nullif(v_item->>'origem_mercadoria',''),
        'produto'
      )
      returning id into v_produto_id;
    end if;

    select quantidade_estoque into v_qtd_atual from public.produtos where id = v_produto_id and empresa_id = v_empresa_id;

    insert into public.notas_entrada_itens (
      empresa_id, nota_entrada_id, produto_id, codigo_fornecedor, gtin, descricao, ncm, cest, cfop,
      unidade_comercial, quantidade, valor_unitario, valor_total, origem_mercadoria, cst_csosn, cst_pis, cst_cofins,
      quantidade_estoque_anterior, quantidade_estoque_nova
    ) values (
      v_empresa_id, v_nota_id, v_produto_id,
      nullif(v_item->>'codigo_fornecedor',''), nullif(v_item->>'gtin',''), v_item->>'descricao',
      nullif(v_item->>'ncm',''), nullif(v_item->>'cest',''), nullif(v_item->>'cfop',''), nullif(v_item->>'unidade_comercial',''),
      v_qtd_item, (v_item->>'valor_unitario')::numeric, (v_item->>'valor_total')::numeric,
      nullif(v_item->>'origem_mercadoria',''), nullif(v_item->>'cst_csosn',''), nullif(v_item->>'cst_pis',''), nullif(v_item->>'cst_cofins',''),
      v_qtd_atual, v_qtd_atual + v_qtd_item
    );

    update public.produtos
    set quantidade_estoque = quantidade_estoque + v_qtd_item
    where id = v_produto_id and empresa_id = v_empresa_id;
  end loop;

  -- Financeiro: à vista (uma despesa já paga) ou a prazo (parcelas pendentes)
  if p_nota->>'forma_pagamento' = 'a_vista' then
    insert into public.despesas (empresa_id, descricao, categoria, valor, data, status, vencimento, fornecedor_id, nota_entrada_id, pago_em)
    values (
      v_empresa_id,
      'Nota de entrada' || case when p_nota->>'numero' is not null then ' #' || (p_nota->>'numero') else '' end || ' - ' || coalesce(v_razao_fornecedor, 'Fornecedor'),
      'Fornecedores',
      (p_nota->'pagamento'->>'valor')::numeric,
      coalesce(nullif(p_nota->'pagamento'->>'data','')::date, current_date),
      'pago',
      coalesce(nullif(p_nota->'pagamento'->>'data','')::date, current_date),
      v_fornecedor_id, v_nota_id, now()
    );
  else
    i := 0;
    for v_parcela in select * from jsonb_array_elements(p_nota->'pagamento'->'parcelas') loop
      i := i + 1;
      insert into public.despesas (empresa_id, descricao, categoria, valor, data, status, vencimento, fornecedor_id, nota_entrada_id)
      values (
        v_empresa_id,
        'Nota de entrada' || case when p_nota->>'numero' is not null then ' #' || (p_nota->>'numero') else '' end || ' - Parcela ' || i,
        'Fornecedores',
        (v_parcela->>'valor')::numeric,
        (v_parcela->>'vencimento')::date,
        'pendente',
        (v_parcela->>'vencimento')::date,
        v_fornecedor_id, v_nota_id
      );
    end loop;
  end if;

  return v_nota_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_empresa(nome_empresa text, nome_responsavel text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  nova_empresa_id uuid;
  v_cliente_id uuid;
  v_assinatura_id uuid;
  v_petgestor_id uuid;
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.';
  end if;

  select email into v_email from auth.users where id = auth.uid();
  select id into v_petgestor_id from public.florest_sistemas where slug = 'petgestor';

  insert into public.florest_clientes (nome_empresa, responsavel, email)
  values (nome_empresa, nome_responsavel, v_email)
  returning id into v_cliente_id;

  insert into public.florest_assinaturas (cliente_id, sistema_id, status_conta, status_pagamento)
  values (v_cliente_id, v_petgestor_id, 'pendente', 'em_dia')
  returning id into v_assinatura_id;

  insert into public.empresas (nome, assinatura_id, bloqueado, status_conta)
  values (nome_empresa, v_assinatura_id, true, 'pendente')
  returning id into nova_empresa_id;

  insert into public.perfis (id, empresa_id, nome)
  values (auth.uid(), nova_empresa_id, nome_responsavel);

  return nova_empresa_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_empresa_completa(p_dados jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  declare
    v_uid     uuid := (select auth.uid());
    v_in      jsonb;
    v_n       jsonb;
    v_email   text;
    v_sis     uuid;
    v_cli     uuid;
    v_ass     uuid;
    v_empresa uuid;
  begin
    if v_uid is null then
      raise exception 'Sessão inválida. Faça login novamente.' using errcode = '28000';
    end if;
    if p_dados is null or jsonb_typeof(p_dados) <> 'object' or char_length(p_dados::text) > 4000
       or exists (select 1 from jsonb_object_keys(p_dados) k where k <> all (array['nome_fantasia','razao_social','cnpj','responsavel','telefone','cep','logradouro','numero','complemento','bairro','cidade','uf'])) then
      raise exception 'CE002: campos não permitidos no cadastro.' using errcode = 'CE002';
    end if;
    v_in := (p_dados - 'nome_fantasia') || jsonb_build_object('nome', p_dados -> 'nome_fantasia');
    v_n  := private.florest_normalizar_cadastro(v_in, 'estrito');          -- erro CE001 com o nome do campo

    if exists (select 1 from public.perfis where id = v_uid) then
      raise exception 'CE003: Este usuário já possui uma empresa cadastrada.' using errcode = 'CE003';
    end if;
    select id into v_sis from public.florest_sistemas where slug = 'petgestor';
    if v_sis is null then
      raise exception 'CE005: sistema não configurado.' using errcode = 'CE005';
    end if;
    select lower(email) into v_email from auth.users where id = v_uid;      -- e-mail SEMPRE da identidade autenticada

    insert into public.florest_clientes (nome_empresa, razao_social, responsavel, telefone, email, cnpj, cep, logradouro, numero, complemento, bairro, cidade, uf)
    values (v_n ->> 'nome', v_n ->> 'razao_social', v_n ->> 'responsavel', v_n ->> 'telefone', v_email, v_n ->> 'cnpj',
            v_n ->> 'cep', v_n ->> 'logradouro', v_n ->> 'numero', v_n ->> 'complemento', v_n ->> 'bairro', v_n ->> 'cidade', v_n ->> 'uf')
    returning id into v_cli;

    insert into public.florest_assinaturas (cliente_id, sistema_id, status_conta, status_pagamento)
    values (v_cli, v_sis, 'pendente', 'em_dia')
    returning id into v_ass;

    insert into public.empresas (nome, assinatura_id, bloqueado, status_conta)
    values (v_n ->> 'nome', v_ass, true, 'pendente')
    returning id into v_empresa;

    insert into public.perfis (id, empresa_id, nome)
    values (v_uid, v_empresa, v_n ->> 'responsavel');

    return v_empresa;
  end;
  $function$;

CREATE OR REPLACE FUNCTION public.registrar_venda(p_cliente_id uuid, p_forma_pagamento text, p_itens jsonb)
 RETURNS TABLE(venda_id uuid, numero_venda bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_empresa_id uuid;
  v_venda_id uuid;
  v_numero_venda bigint;
  v_total numeric(10,2) := 0;
  item jsonb;
  v_produto record;
  v_pacote_id uuid;
  v_qtd integer;
  i integer;
begin
  select empresa_id into v_empresa_id from public.perfis where id = auth.uid();
  if v_empresa_id is null then
    raise exception 'Usuário sem empresa vinculada.';
  end if;

  for item in select * from jsonb_array_elements(p_itens) loop
    v_total := v_total + ((item->>'quantidade')::integer * (item->>'preco_unitario')::numeric);
  end loop;

  if p_cliente_id is null and exists (
    select 1
    from jsonb_array_elements(p_itens) it
    join public.produtos p on p.id = (it->>'produto_id')::uuid
    where p.empresa_id = v_empresa_id and p.vendavel_pacote = true
  ) then
    raise exception 'Selecione um cliente para vender um pacote.';
  end if;

  insert into public.contadores_venda (empresa_id, ultimo_numero)
  values (v_empresa_id, 1001)
  on conflict (empresa_id) do update set ultimo_numero = contadores_venda.ultimo_numero + 1
  returning ultimo_numero into v_numero_venda;

  insert into public.vendas (empresa_id, cliente_id, forma_pagamento, total, numero_venda)
  values (v_empresa_id, p_cliente_id, p_forma_pagamento, v_total, v_numero_venda)
  returning id into v_venda_id;

  for item in select * from jsonb_array_elements(p_itens) loop
    select * into v_produto from public.produtos
    where id = (item->>'produto_id')::uuid and empresa_id = v_empresa_id;

    if v_produto.id is null then
      raise exception 'Produto não encontrado para esta empresa.';
    end if;

    v_qtd := (item->>'quantidade')::integer;

    if v_produto.vendavel_pacote then
      for i in 1..v_qtd loop
        insert into public.pacotes_clientes (empresa_id, cliente_id, produto_id, sessoes_totais, sessoes_usadas)
        values (v_empresa_id, p_cliente_id, v_produto.id, v_produto.pacote_qtd, 0)
        returning id into v_pacote_id;

        insert into public.itens_venda (empresa_id, venda_id, produto_id, quantidade, preco_unitario, subtotal, pacote_cliente_id)
        values (v_empresa_id, v_venda_id, v_produto.id, 1, (item->>'preco_unitario')::numeric, (item->>'preco_unitario')::numeric, v_pacote_id);
      end loop;
      -- Pacote NÃO baixa estoque.
    else
      insert into public.itens_venda (empresa_id, venda_id, produto_id, quantidade, preco_unitario, subtotal)
      values (v_empresa_id, v_venda_id, v_produto.id, v_qtd, (item->>'preco_unitario')::numeric, v_qtd * (item->>'preco_unitario')::numeric);

      update public.produtos
      set quantidade_estoque = quantidade_estoque - v_qtd
      where id = v_produto.id and empresa_id = v_empresa_id;
    end if;
  end loop;

  return query select v_venda_id, v_numero_venda;
end;
$function$;

CREATE OR REPLACE FUNCTION public.usar_sessao_pacote(p_pacote_id uuid)
 RETURNS TABLE(total_sessoes integer, usadas_sessoes integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_empresa_id uuid;
  v_pacote public.pacotes_clientes%rowtype;
begin
  select empresa_id into v_empresa_id from public.perfis where id = auth.uid();

  select * into v_pacote from public.pacotes_clientes pc
  where pc.id = p_pacote_id and pc.empresa_id = v_empresa_id;

  if v_pacote.id is null then
    raise exception 'Pacote não encontrado.';
  end if;

  if v_pacote.sessoes_usadas >= v_pacote.sessoes_totais then
    raise exception 'Este pacote já está concluído.';
  end if;

  update public.pacotes_clientes
  set sessoes_usadas = sessoes_usadas + 1
  where id = p_pacote_id;

  insert into public.pacote_usos (empresa_id, pacote_id)
  values (v_empresa_id, p_pacote_id);

  return query select pc.sessoes_totais, pc.sessoes_usadas from public.pacotes_clientes pc where pc.id = p_pacote_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.vender_pacote_produto(p_cliente_id uuid, p_produto_id uuid, p_forma_pagamento text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_empresa_id uuid;
  v_produto record;
  v_venda_id uuid;
  v_pacote_id uuid;
begin
  select empresa_id into v_empresa_id from public.perfis where id = auth.uid();
  if v_empresa_id is null then
    raise exception 'Usuário sem empresa vinculada.';
  end if;

  select * into v_produto from public.produtos
  where id = p_produto_id and empresa_id = v_empresa_id and vendavel_pacote = true;

  if v_produto.id is null then
    raise exception 'Produto não encontrado ou não é vendável como pacote.';
  end if;

  insert into public.vendas (empresa_id, cliente_id, forma_pagamento, total, tipo)
  values (v_empresa_id, p_cliente_id, p_forma_pagamento, v_produto.pacote_preco, 'pacote_novo')
  returning id into v_venda_id;

  -- Agora também entra em itens_venda, pra contar nos relatórios de produtos mais vendidos
  insert into public.itens_venda (empresa_id, venda_id, produto_id, quantidade, preco_unitario, subtotal)
  values (v_empresa_id, v_venda_id, p_produto_id, 1, v_produto.pacote_preco, v_produto.pacote_preco);

  insert into public.pacotes_clientes (empresa_id, cliente_id, produto_id, sessoes_totais, sessoes_usadas)
  values (v_empresa_id, p_cliente_id, p_produto_id, v_produto.pacote_qtd, 0)
  returning id into v_pacote_id;

  return v_pacote_id;
end;
$function$;
-- ==========================================================
-- GRANT / REVOKE — permissões de execução (estado atual)
-- ==========================================================

revoke all on function private.florest_cnpj_valido(p_cnpj text) from public, anon, authenticated, service_role;

revoke all on function private.florest_criar_cadastro_remoto(p_sis uuid, p_ref text, p_dados jsonb) from public, anon, authenticated, service_role;

revoke all on function private.florest_normalizar_cadastro(p_dados jsonb, p_modo text) from public, anon, authenticated, service_role;

revoke all on function private.florest_set_atualizado_em() from public, anon, authenticated, service_role;

revoke all on function private.florest_sistema_remoto(p_slug text, p_exigir_ativo boolean) from public, anon, authenticated, service_role;

revoke all on function public.admin_atualizar_assinatura(p_assinatura_id uuid, p_status_conta text, p_status_pagamento text, p_vencimento date, p_valor_mensal numeric) from public, anon, authenticated, service_role;
grant execute on function public.admin_atualizar_assinatura(p_assinatura_id uuid, p_status_conta text, p_status_pagamento text, p_vencimento date, p_valor_mensal numeric) to public, anon, authenticated, service_role;

revoke all on function public.admin_atualizar_cliente(p_cliente_id uuid, p_telefone text, p_cnpj text, p_observacoes text, p_responsavel text, p_email text) from public, anon, authenticated, service_role;
grant execute on function public.admin_atualizar_cliente(p_cliente_id uuid, p_telefone text, p_cnpj text, p_observacoes text, p_responsavel text, p_email text) to public, anon, authenticated, service_role;

revoke all on function public.admin_atualizar_cliente_completo(p_cliente_id uuid, p_dados jsonb) from public, anon, authenticated, service_role;
grant execute on function public.admin_atualizar_cliente_completo(p_cliente_id uuid, p_dados jsonb) to authenticated, service_role;

revoke all on function public.admin_atualizar_licenca(p_empresa_id uuid, p_vencimento date, p_bloqueado boolean) from public, anon, authenticated, service_role;
grant execute on function public.admin_atualizar_licenca(p_empresa_id uuid, p_vencimento date, p_bloqueado boolean) to public, anon, authenticated, service_role;

revoke all on function public.admin_listar_clientes() from public, anon, authenticated, service_role;
grant execute on function public.admin_listar_clientes() to public, anon, authenticated, service_role;

revoke all on function public.admin_listar_clientes_completo() from public, anon, authenticated, service_role;
grant execute on function public.admin_listar_clientes_completo() to authenticated, service_role;

revoke all on function public.admin_listar_empresas() from public, anon, authenticated, service_role;
grant execute on function public.admin_listar_empresas() to public, anon, authenticated, service_role;

revoke all on function public.admin_listar_sync() from public, anon, authenticated, service_role;
grant execute on function public.admin_listar_sync() to authenticated, service_role;

revoke all on function public.bloquear_vencidos() from public, anon, authenticated, service_role;
grant execute on function public.bloquear_vencidos() to public, anon, authenticated, service_role;

revoke all on function public.dadosjah_obter_credenciais(p_empresa_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.dadosjah_obter_credenciais(p_empresa_id uuid) to service_role;

revoke all on function public.fiscal_emitir_nota(p_venda_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.fiscal_emitir_nota(p_venda_id uuid) to public, anon, authenticated, service_role;

revoke all on function public.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero bigint) from public, anon, authenticated, service_role;
grant execute on function public.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero bigint) to public, anon, authenticated, service_role;

revoke all on function public.fiscal_proximo_numero(p_empresa_id uuid, p_tipo_documento text, p_serie text) from public, anon, authenticated, service_role;
grant execute on function public.fiscal_proximo_numero(p_empresa_id uuid, p_tipo_documento text, p_serie text) to service_role;

revoke all on function public.florest_admin_assinatura_preparar(p_admin_id uuid, p_assinatura_id uuid, p_acao text, p_dados jsonb) from public, anon, authenticated, service_role;
grant execute on function public.florest_admin_assinatura_preparar(p_admin_id uuid, p_assinatura_id uuid, p_acao text, p_dados jsonb) to service_role;

revoke all on function public.florest_admin_assinatura_sync_resultado(p_assinatura_id uuid, p_revisao bigint, p_ok boolean, p_erro text) from public, anon, authenticated, service_role;
grant execute on function public.florest_admin_assinatura_sync_resultado(p_assinatura_id uuid, p_revisao bigint, p_ok boolean, p_erro text) to service_role;

revoke all on function public.florest_evento_concluir(p_slug text, p_event_id uuid, p_estado text, p_resultado jsonb, p_erro text) from public, anon, authenticated, service_role;
grant execute on function public.florest_evento_concluir(p_slug text, p_event_id uuid, p_estado text, p_resultado jsonb, p_erro text) to service_role;

revoke all on function public.florest_evento_registrar(p_slug text, p_event_id uuid, p_tipo text, p_ref_externa text) from public, anon, authenticated, service_role;
grant execute on function public.florest_evento_registrar(p_slug text, p_event_id uuid, p_tipo text, p_ref_externa text) to service_role;

revoke all on function public.florest_registrar_cadastro(p_slug text, p_ref_externa text, p_dados jsonb) from public, anon, authenticated, service_role;
grant execute on function public.florest_registrar_cadastro(p_slug text, p_ref_externa text, p_dados jsonb) to service_role;

revoke all on function public.florest_sistema_obter(p_slug text) from public, anon, authenticated, service_role;
grant execute on function public.florest_sistema_obter(p_slug text) to service_role;

revoke all on function public.notas_entrada_confirmar(p_nota jsonb) from public, anon, authenticated, service_role;
grant execute on function public.notas_entrada_confirmar(p_nota jsonb) to public, anon, authenticated, service_role;

revoke all on function public.registrar_empresa(nome_empresa text, nome_responsavel text) from public, anon, authenticated, service_role;
grant execute on function public.registrar_empresa(nome_empresa text, nome_responsavel text) to public, anon, authenticated, service_role;

revoke all on function public.registrar_empresa_completa(p_dados jsonb) from public, anon, authenticated, service_role;
grant execute on function public.registrar_empresa_completa(p_dados jsonb) to authenticated, service_role;

revoke all on function public.registrar_venda(p_cliente_id uuid, p_forma_pagamento text, p_itens jsonb) from public, anon, authenticated, service_role;
grant execute on function public.registrar_venda(p_cliente_id uuid, p_forma_pagamento text, p_itens jsonb) to public, anon, authenticated, service_role;

revoke all on function public.usar_sessao_pacote(p_pacote_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.usar_sessao_pacote(p_pacote_id uuid) to public, anon, authenticated, service_role;

revoke all on function public.vender_pacote_produto(p_cliente_id uuid, p_produto_id uuid, p_forma_pagamento text) from public, anon, authenticated, service_role;
grant execute on function public.vender_pacote_produto(p_cliente_id uuid, p_produto_id uuid, p_forma_pagamento text) to public, anon, authenticated, service_role;

-- =====================================================================
-- 002_funcoes_banco.sql
-- Florest ERP (Supabase / PostgreSQL) — funções/RPCs dos schemas private e public
-- Gerado exclusivamente a partir do CSV de funções (definições preservadas
-- exatamente como exportadas, inclusive quebras de linha e SET/SECURITY).
-- Somente funções: sem tabelas, sem políticas RLS, sem triggers, sem dados,
-- sem segredos e sem GRANT/REVOKE (permissões não constam no CSV).
--
-- Pré-requisito: executar antes o 001_estrutura_banco.sql (várias funções
-- retornam/usam tipos de tabela do schema public).
-- Ordem: schema private -> funções private -> funções public.
-- =====================================================================

set search_path = public;
set check_function_bodies = off;

create schema if not exists private;


-- =====================================================================
-- FUNÇÕES DO SCHEMA PRIVATE
-- =====================================================================

-- private.eh_proprietario()
CREATE OR REPLACE FUNCTION private.eh_proprietario()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select p.ativo and p.papel = 'proprietario' from public.perfis p where p.id = (select auth.uid())), false);
$function$;

-- private.empresa_id_ativa()
CREATE OR REPLACE FUNCTION private.empresa_id_ativa()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select e.id
    from public.perfis p
    join public.empresas e on e.id = p.empresa_id
   where p.id = (select auth.uid())
     and p.ativo
     and e.status_conta = 'aprovado'
     and e.bloqueado = false;
$function$;

-- private.empresa_id_do_usuario()
CREATE OR REPLACE FUNCTION private.empresa_id_do_usuario()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

  select p.empresa_id from public.perfis p where p.id = (select auth.uid());

$function$;

-- private.empresas_regras()
CREATE OR REPLACE FUNCTION private.empresas_regras()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

begin

  new.bloqueado := (new.status_conta <> 'aprovado');

  if tg_op = 'INSERT' then

    if new.status_conta = 'aprovado'  then new.aprovado_em  := coalesce(new.aprovado_em, now());  end if;

    if new.status_conta = 'bloqueado' then new.bloqueado_em := coalesce(new.bloqueado_em, now()); end if;

  else

    if new.status_conta = 'aprovado' and old.status_conta <> 'aprovado'

       and new.aprovado_em is not distinct from old.aprovado_em then

      new.aprovado_em := now();

    end if;

    if new.status_conta = 'bloqueado' and old.status_conta <> 'bloqueado'

       and new.bloqueado_em is not distinct from old.bloqueado_em then

      new.bloqueado_em := now();

    end if;

  end if;

  return new;

end;

$function$;

-- private.exigir_empresa_ativa()
CREATE OR REPLACE FUNCTION private.exigir_empresa_ativa()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid    uuid := (select auth.uid());
  v_emp    uuid;
  v_status text;
  v_bloq   boolean;
  v_ativo  boolean;
begin
  if v_uid is null then
    raise exception 'Sessão expirada. Faça login novamente.' using errcode = '28000';
  end if;
  select e.id, e.status_conta, e.bloqueado, p.ativo into v_emp, v_status, v_bloq, v_ativo
    from public.perfis p join public.empresas e on e.id = p.empresa_id
   where p.id = v_uid;
  if v_emp is null then
    raise exception 'Usuário sem empresa vinculada.' using errcode = '42501';
  end if;
  if v_status = 'pendente' then
    raise exception 'Sua conta ainda está em análise.' using errcode = '42501';
  end if;
  if v_status <> 'aprovado' or v_bloq then
    raise exception 'Seu acesso está bloqueado. Entre em contato com seu revendedor.' using errcode = '42501';
  end if;
  if not v_ativo then
    raise exception 'Seu usuário está desativado. Fale com o administrador da empresa.' using errcode = '42501';
  end if;
  return v_emp;
end;
$function$;

-- private.fiscal_emitir_nota(p_venda_id uuid)
CREATE OR REPLACE FUNCTION private.fiscal_emitir_nota(p_venda_id uuid)
 RETURNS SETOF documentos_fiscais
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_empresa uuid := private.exigir_empresa_ativa();

  v_tem_prod boolean;

  v_tem_serv boolean;

  v_val_prod numeric;

  v_val_serv numeric;

begin

  perform 1 from public.vendas v where v.id = p_venda_id and v.empresa_id = v_empresa;

  if not found then

    raise exception 'Venda não encontrada.';

  end if;

  select coalesce(bool_or(p.tipo_fiscal <> 'servico'), false), coalesce(bool_or(p.tipo_fiscal = 'servico'), false),

         coalesce(sum(i.subtotal) filter (where p.tipo_fiscal <> 'servico'), 0),

         coalesce(sum(i.subtotal) filter (where p.tipo_fiscal = 'servico'), 0)

    into v_tem_prod, v_tem_serv, v_val_prod, v_val_serv

    from public.itens_venda i

    join public.produtos p on p.id = i.produto_id and p.empresa_id = i.empresa_id

   where i.venda_id = p_venda_id and i.empresa_id = v_empresa;

  if v_tem_prod then

    insert into public.documentos_fiscais (empresa_id, venda_id, tipo_documento, valor)

    values (v_empresa, p_venda_id, 'nfce', v_val_prod)

    on conflict (venda_id, tipo_documento) where status not in ('cancelada', 'rejeitada') do nothing;

  end if;

  if v_tem_serv then

    insert into public.documentos_fiscais (empresa_id, venda_id, tipo_documento, valor)

    values (v_empresa, p_venda_id, 'nfse', v_val_serv)

    on conflict (venda_id, tipo_documento) where status not in ('cancelada', 'rejeitada') do nothing;

  end if;

  return query

    select d.* from public.documentos_fiscais d

     where d.venda_id = p_venda_id and d.empresa_id = v_empresa

     order by d.created_at, d.id;

end;

$function$;

-- private.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero integer)
CREATE OR REPLACE FUNCTION private.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_empresa uuid := private.exigir_empresa_ativa();

  v_serie   text := btrim(coalesce(p_serie, ''));

  v_result  integer;

begin

  if p_tipo_documento is null or p_tipo_documento not in ('nfce', 'nfse', 'nfe') then

    raise exception 'Tipo de documento fiscal inválido.';

  end if;

  if v_serie = '' then

    raise exception 'Informe a série.';

  end if;

  if p_ultimo_numero is null or p_ultimo_numero < 0 then

    raise exception 'Informe um número válido.';

  end if;

  insert into public.contadores_fiscais as c (empresa_id, tipo_documento, serie, ultimo_numero)

  values (v_empresa, p_tipo_documento, v_serie, p_ultimo_numero)

  on conflict (empresa_id, tipo_documento, serie)

  do update set ultimo_numero = greatest(c.ultimo_numero, excluded.ultimo_numero), atualizado_em = now()

  returning c.ultimo_numero into v_result;

  return v_result;

end;

$function$;

-- private.florest_cnpj_valido(p_cnpj text)
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

-- private.florest_empresas_outbox()
CREATE OR REPLACE FUNCTION private.florest_empresas_outbox()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.florest_outbox (tipo, empresa_id)
  values ('cadastro_criado', new.id)
  on conflict (empresa_id) where tipo = 'cadastro_criado' do nothing;
  return new;
end;
$function$;

-- private.florest_normalizar_cadastro(p_dados jsonb, p_modo text)
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

-- private.notas_entrada_confirmar(p_nota jsonb)
CREATE OR REPLACE FUNCTION private.notas_entrada_confirmar(p_nota jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_empresa   uuid := private.exigir_empresa_ativa();

  v_chave     text;

  v_numero    text;

  v_forn      uuid;

  v_forn_nome text;

  v_fj        jsonb;

  v_cnpj      text;

  v_forma     text;

  v_total     numeric;

  v_nota      uuid;

  v_emissao   date;

  v_txt       text;

  v_itens     jsonb;

  v_it        jsonb;

  v_pid       uuid;

  v_prod      record;

  v_qtd       numeric;

  v_vu        numeric;

  v_vt        numeric;

  v_gtin      text;

  v_un_xml    text;

  v_desc      text;

  v_pv        numeric;

  v_ant       numeric;

  v_nova      numeric;

  v_criados   uuid[] := '{}';

  v_pag       jsonb;

  v_parcelas  jsonb;

  v_pc        jsonb;

  v_soma      numeric := 0;

  v_venc      date;

  v_valor     numeric;

  v_n         integer;

  v_i         integer := 0;

  v_dt_pag    date;

begin

  if p_nota is null or jsonb_typeof(p_nota) <> 'object' then

    raise exception 'Dados da nota inválidos.';

  end if;

  -- chave de acesso: 44 dígitos, sem duplicidade por empresa

  v_chave := btrim(coalesce(p_nota->>'chave_acesso', ''));

  if v_chave !~ '^[0-9]{44}$' then

    raise exception 'Não foi possível identificar uma chave de acesso válida de 44 dígitos.';

  end if;

  if exists (select 1 from public.notas_entrada n where n.empresa_id = v_empresa and n.chave_acesso = v_chave) then

    raise exception 'Esta Nota Fiscal já foi lançada.';

  end if;

  v_numero := nullif(btrim(coalesce(p_nota->>'numero', '')), '');

  v_total  := coalesce(nullif(p_nota->>'valor_total', '')::numeric, 0);

  if v_total < 0 then raise exception 'Valor total da nota inválido.'; end if;

  v_txt := nullif(p_nota->>'data_emissao', '');

  if v_txt is not null and v_txt ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then

    v_emissao := left(v_txt, 10)::date;     -- data local do emitente (sem deslocar por fuso)

  end if;

  v_forma := coalesce(p_nota->>'forma_pagamento', '');

  if v_forma not in ('a_vista', 'a_prazo') then

    raise exception 'Forma de pagamento da nota inválida.';

  end if;

  v_itens := p_nota->'itens';

  if v_itens is null or jsonb_typeof(v_itens) <> 'array' or jsonb_array_length(v_itens) = 0 then

    raise exception 'A nota não possui itens.';

  end if;

  if jsonb_array_length(v_itens) > 1000 then

    raise exception 'Itens demais na nota (máximo 1000).';

  end if;

  -- pagamento: soma precisa bater com o total (tolerância de 1 centavo)

  v_pag := p_nota->'pagamento';

  if v_pag is null or jsonb_typeof(v_pag) <> 'object' then

    raise exception 'Informe o pagamento da nota.';

  end if;

  if v_forma = 'a_vista' then

    v_soma := coalesce(nullif(v_pag->>'valor', '')::numeric, 0);

  else

    v_parcelas := v_pag->'parcelas';

    if v_parcelas is null or jsonb_typeof(v_parcelas) <> 'array' or jsonb_array_length(v_parcelas) = 0 then

      raise exception 'Informe ao menos uma parcela.';

    end if;

    for v_pc in select value from jsonb_array_elements(v_parcelas) loop

      if nullif(v_pc->>'vencimento', '') is null or coalesce(nullif(v_pc->>'valor', '')::numeric, 0) <= 0 then

        raise exception 'Parcela inválida (vencimento e valor são obrigatórios).';

      end if;

      v_soma := v_soma + (v_pc->>'valor')::numeric;

    end loop;

  end if;

  if abs(v_soma - v_total) > 0.01 then

    raise exception 'O pagamento informado (%) não confere com o valor total da nota (%).', v_soma, v_total;

  end if;

  -- fornecedor: usa o informado (da própria empresa) ou acha/cria pelo CNPJ

  v_fj := p_nota->'fornecedor';

  if v_fj is null or jsonb_typeof(v_fj) <> 'object' then

    raise exception 'Fornecedor da nota não informado.';

  end if;

  if nullif(v_fj->>'id', '') is not null then

    select f.id, f.razao_social into v_forn, v_forn_nome

      from public.fornecedores f

     where f.id = (v_fj->>'id')::uuid and f.empresa_id = v_empresa;

    if not found then raise exception 'Fornecedor não encontrado.'; end if;

  else

    v_cnpj := regexp_replace(coalesce(v_fj->>'cnpj', ''), '[^0-9]', '', 'g');

    if length(v_cnpj) not in (11, 14) then

      raise exception 'CNPJ do fornecedor inválido.';

    end if;

    select f.id, f.razao_social into v_forn, v_forn_nome

      from public.fornecedores f where f.empresa_id = v_empresa and f.cnpj = v_cnpj;

    if not found then

      v_forn_nome := btrim(coalesce(v_fj->>'razao_social', ''));

      if v_forn_nome = '' then raise exception 'Informe a razão social do fornecedor.'; end if;

      insert into public.fornecedores (empresa_id, cnpj, razao_social, nome_fantasia, inscricao_estadual, telefone,

                                       cep, endereco, numero, complemento, bairro, municipio, uf)

      values (v_empresa, v_cnpj, v_forn_nome, nullif(btrim(v_fj->>'nome_fantasia'), ''),

              nullif(btrim(v_fj->>'inscricao_estadual'), ''), nullif(btrim(v_fj->>'telefone'), ''),

              nullif(btrim(v_fj->>'cep'), ''), nullif(btrim(v_fj->>'endereco'), ''), nullif(btrim(v_fj->>'numero'), ''),

              nullif(btrim(v_fj->>'complemento'), ''), nullif(btrim(v_fj->>'bairro'), ''),

              nullif(btrim(v_fj->>'municipio'), ''), nullif(upper(btrim(v_fj->>'uf')), ''))

      returning id into v_forn;

    end if;

  end if;

  -- cabeçalho da nota (a unique (empresa_id, chave_acesso) é a garantia final contra duplicidade)

  insert into public.notas_entrada (empresa_id, fornecedor_id, chave_acesso, numero, serie, data_emissao,

                                    valor_produtos, valor_desconto, valor_frete, valor_outras_despesas, valor_total,

                                    forma_pagamento, status, xml_conteudo, criado_por)

  values (v_empresa, v_forn, v_chave, v_numero, nullif(btrim(coalesce(p_nota->>'serie', '')), ''), v_emissao,

          coalesce(nullif(p_nota->>'valor_produtos', '')::numeric, 0),

          coalesce(nullif(p_nota->>'valor_desconto', '')::numeric, 0),

          coalesce(nullif(p_nota->>'valor_frete', '')::numeric, 0),

          coalesce(nullif(p_nota->>'valor_outras_despesas', '')::numeric, 0),

          v_total, v_forma, 'confirmada', p_nota->>'xml_conteudo', (select auth.uid()))

  returning id into v_nota;

  -- itens: vincula/cria produto e dá entrada no estoque (quantidade decimal, sem arredondar para inteiro)

  for v_it in select value from jsonb_array_elements(v_itens) loop

    v_desc   := btrim(coalesce(v_it->>'descricao', ''));

    v_qtd    := coalesce(nullif(v_it->>'quantidade', '')::numeric, 0);

    v_vu     := coalesce(nullif(v_it->>'valor_unitario', '')::numeric, 0);

    v_vt     := coalesce(nullif(v_it->>'valor_total', '')::numeric, 0);

    v_un_xml := nullif(btrim(coalesce(v_it->>'unidade_comercial', '')), '');

    v_gtin   := nullif(regexp_replace(coalesce(v_it->>'gtin', ''), '[^0-9]', '', 'g'), '');

    if v_desc = '' or v_qtd <= 0 or v_vu < 0 or v_vt < 0 then

      raise exception 'Item da nota inválido (descrição e quantidade maior que zero são obrigatórias).';

    end if;

    v_pid := null;

    if nullif(v_it->>'produto_id', '') is not null then

      v_pid := (v_it->>'produto_id')::uuid;

    elsif v_gtin is not null then

      -- item marcado como "novo", mas o GTIN já existe na empresa?

      select p.id into v_pid from public.produtos p

       where p.empresa_id = v_empresa and nullif(ltrim(p.gtin, '0'), '') = nullif(ltrim(v_gtin, '0'), '');

      if v_pid is not null and not (v_pid = any (v_criados)) then

        raise exception 'Já existe um produto com o código de barras % nesta empresa. Vincule o item “%” a esse produto.', v_gtin, v_desc;

      end if;

    end if;

    if v_pid is null then

      -- produto novo: só dados básicos. Nenhuma tributação de entrada é copiada para a saída.

      v_pv := coalesce(nullif(v_it->>'preco_venda', '')::numeric, v_vu);

      if v_pv < 0 then raise exception 'Preço de venda inválido para “%”.', v_desc; end if;

      insert into public.produtos (empresa_id, nome, gtin, unidade_comercial, preco_venda, preco_custo, quantidade_estoque, tipo_fiscal)

      values (v_empresa, left(v_desc, 200), v_gtin, v_un_xml, v_pv, v_vu, 0, 'produto')

      returning id into v_pid;

      v_criados := v_criados || v_pid;

    end if;

    select p.nome, p.quantidade_estoque, p.unidade_comercial into v_prod

      from public.produtos p

     where p.id = v_pid and p.empresa_id = v_empresa

       for update;

    if not found then

      raise exception 'Produto vinculado não encontrado nesta empresa.';

    end if;

    -- sem conversão automática de unidade: divergiu, bloqueia (mesma regra do front)

    if nullif(btrim(coalesce(v_prod.unidade_comercial, '')), '') is not null and v_un_xml is not null

       and btrim(v_prod.unidade_comercial) <> v_un_xml then

      raise exception 'A unidade do XML (%) é diferente da unidade cadastrada no produto “%” (%). Vincule a um produto com a mesma unidade.',

        v_un_xml, v_prod.nome, v_prod.unidade_comercial;

    end if;

    v_ant  := v_prod.quantidade_estoque;

    v_nova := v_ant + v_qtd;

    update public.produtos set quantidade_estoque = v_nova where id = v_pid and empresa_id = v_empresa;

    insert into public.notas_entrada_itens (empresa_id, nota_entrada_id, produto_id, codigo_fornecedor, gtin, descricao,

                                            ncm, cest, cfop, unidade_comercial, quantidade, valor_unitario, valor_total,

                                            origem_mercadoria, cst_csosn, cst_pis, cst_cofins,

                                            quantidade_estoque_anterior, quantidade_estoque_nova)

    values (v_empresa, v_nota, v_pid, nullif(btrim(v_it->>'codigo_fornecedor'), ''), v_gtin, left(v_desc, 500),

            nullif(btrim(v_it->>'ncm'), ''), nullif(btrim(v_it->>'cest'), ''), nullif(btrim(v_it->>'cfop'), ''),

            v_un_xml, v_qtd, v_vu, v_vt,

            nullif(btrim(v_it->>'origem_mercadoria'), ''), nullif(btrim(v_it->>'cst_csosn'), ''),

            nullif(btrim(v_it->>'cst_pis'), ''), nullif(btrim(v_it->>'cst_cofins'), ''),

            v_ant, v_nova);

  end loop;

  -- contas a pagar (despesas ligadas à nota). data = quando o dinheiro sai (vencimento / pagamento).

  if v_forma = 'a_vista' then

    v_dt_pag := coalesce(nullif(v_pag->>'data', '')::date, (now() at time zone 'America/Sao_Paulo')::date);

    insert into public.despesas (empresa_id, descricao, categoria, valor, data, vencimento, status, pago_em, nota_entrada_id)

    values (v_empresa, left('NF ' || coalesce(v_numero, 's/n') || ' — ' || v_forn_nome, 200), 'Compra de mercadorias',

            v_soma, v_dt_pag, v_dt_pag, 'pago', v_dt_pag, v_nota);

  else

    v_n := jsonb_array_length(v_parcelas);

    for v_pc in select value from jsonb_array_elements(v_parcelas) loop

      v_i := v_i + 1;

      v_venc  := (v_pc->>'vencimento')::date;

      v_valor := (v_pc->>'valor')::numeric;

      insert into public.despesas (empresa_id, descricao, categoria, valor, data, vencimento, status, nota_entrada_id)

      values (v_empresa,

              left('NF ' || coalesce(v_numero, 's/n') || ' — ' || v_forn_nome || ' (parcela ' || v_i || '/' || v_n || ')', 200),

              'Compra de mercadorias', v_valor, v_venc, v_venc, 'pendente', v_nota);

    end loop;

  end if;

  return v_nota;

end;

$function$;

-- private.perm(p_modulo text)
CREATE OR REPLACE FUNCTION private.perm(p_modulo text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((
    select p.ativo and (p.papel = 'proprietario' or p_modulo = any (p.permissoes))
      from public.perfis p
     where p.id = (select auth.uid())), false);
$function$;

-- private.perm_alguma(p_modulos text[])
CREATE OR REPLACE FUNCTION private.perm_alguma(p_modulos text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((
    select p.ativo and (p.papel = 'proprietario' or p.permissoes && p_modulos)
      from public.perfis p
     where p.id = (select auth.uid())), false);
$function$;

-- private.produtos_proteger_colunas()
CREATE OR REPLACE FUNCTION private.produtos_proteger_colunas()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if current_user = 'authenticated' and not private.perm('produtos') then
    if (to_jsonb(new) - array['quantidade_estoque', 'estoque_minimo', 'atualizado_em'])
       is distinct from (to_jsonb(old) - array['quantidade_estoque', 'estoque_minimo', 'atualizado_em']) then
      raise exception 'Seu acesso permite alterar apenas o estoque do produto.' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$function$;

-- private.proteger_config_fiscal()
CREATE OR REPLACE FUNCTION private.proteger_config_fiscal()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

begin

  if current_user in ('anon', 'authenticated') then

    if tg_op = 'INSERT' then

      new.nfce_ambiente := 'homologacao';

      new.certificado_status := 'nao_configurado';

      new.certificado_razao_social := null;

      new.certificado_cnpj := null;

      new.certificado_validade := null;

      new.certificado_certificadora := null;

      new.certificado_numero_serie := null;

      new.dadosjah_usuario_criado := false;

      new.emitente_registrado := false;

    else

      new.empresa_id := old.empresa_id;

      new.nfce_ambiente := old.nfce_ambiente;

      new.certificado_status := old.certificado_status;

      new.certificado_razao_social := old.certificado_razao_social;

      new.certificado_cnpj := old.certificado_cnpj;

      new.certificado_validade := old.certificado_validade;

      new.certificado_certificadora := old.certificado_certificadora;

      new.certificado_numero_serie := old.certificado_numero_serie;

      new.dadosjah_usuario_criado := old.dadosjah_usuario_criado;

      new.emitente_registrado := old.emitente_registrado;

    end if;

  end if;

  return new;

end;

$function$;

-- private.set_atualizado_em()
CREATE OR REPLACE FUNCTION private.set_atualizado_em()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

begin

  new.atualizado_em := now();

  return new;

end;

$function$;

-- private.usuarios_alvo(p_ator uuid, p_alvo uuid, OUT o_empresa uuid, OUT o_papel_ator text, OUT o_perm_ator text[])
CREATE OR REPLACE FUNCTION private.usuarios_alvo(p_ator uuid, p_alvo uuid, OUT o_empresa uuid, OUT o_papel_ator text, OUT o_perm_ator text[])
 RETURNS record
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_t record;
begin
  select a.o_empresa, a.o_papel, a.o_permissoes into o_empresa, o_papel_ator, o_perm_ator
    from private.usuarios_ator(p_ator) a;
  if p_alvo is null or p_alvo = p_ator then
    raise exception 'Você não pode alterar o seu próprio acesso.' using errcode = '42501';
  end if;
  select p.papel, p.permissoes into v_t
    from public.perfis p where p.id = p_alvo and p.empresa_id = o_empresa;
  if not found then
    raise exception 'Usuário não encontrado.' using errcode = '42501';
  end if;
  if v_t.papel = 'proprietario' then
    raise exception 'O proprietário da empresa não pode ser alterado.' using errcode = '42501';
  end if;
  if o_papel_ator <> 'proprietario' and 'usuarios' = any (v_t.permissoes) then
    raise exception 'Somente o proprietário pode alterar quem administra usuários.' using errcode = '42501';
  end if;
end;
$function$;

-- private.usuarios_ator(p_ator uuid, OUT o_empresa uuid, OUT o_papel text, OUT o_permissoes text[])
CREATE OR REPLACE FUNCTION private.usuarios_ator(p_ator uuid, OUT o_empresa uuid, OUT o_papel text, OUT o_permissoes text[])
 RETURNS record
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_status text;
  v_bloq   boolean;
  v_ativo  boolean;
begin
  if p_ator is null then
    raise exception 'Sessão expirada. Faça login novamente.' using errcode = '28000';
  end if;
  select p.empresa_id, p.papel, p.permissoes, p.ativo, e.status_conta, e.bloqueado
    into o_empresa, o_papel, o_permissoes, v_ativo, v_status, v_bloq
    from public.perfis p join public.empresas e on e.id = p.empresa_id
   where p.id = p_ator;
  if o_empresa is null then
    raise exception 'Usuário sem empresa vinculada.' using errcode = '42501';
  end if;
  if v_status <> 'aprovado' or v_bloq then
    raise exception 'Seu acesso está bloqueado. Entre em contato com seu revendedor.' using errcode = '42501';
  end if;
  if not v_ativo then
    raise exception 'Seu usuário está desativado. Fale com o administrador da empresa.' using errcode = '42501';
  end if;
  if o_papel <> 'proprietario' and not ('usuarios' = any (o_permissoes)) then
    raise exception 'Você não tem permissão para administrar usuários e acessos.' using errcode = '42501';
  end if;
end;
$function$;

-- private.usuarios_modulos()
CREATE OR REPLACE FUNCTION private.usuarios_modulos()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ select array['dashboard','clientes','produtos','estoque','pdv','fornecedores',
                   'notas_entrada','financeiro','fiscal','relatorios','configuracoes','usuarios']::text[] $function$;

-- private.usuarios_normalizar_permissoes(p_perm text[], p_ator_papel text, p_ator_perm text[])
CREATE OR REPLACE FUNCTION private.usuarios_normalizar_permissoes(p_perm text[], p_ator_papel text, p_ator_perm text[])
 RETURNS text[]
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v text[];
begin
  if p_perm is null then
    raise exception 'Informe as permissões do usuário.';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v from unnest(p_perm) x;
  if exists (select 1 from unnest(v) x where x is null or x <> all (private.usuarios_modulos())) then
    raise exception 'Permissão inválida.';
  end if;
  if p_ator_papel <> 'proprietario' then
    if 'usuarios' = any (v) then
      raise exception 'Somente o proprietário pode liberar o módulo Usuários e Acessos.' using errcode = '42501';
    end if;
    if not (v <@ p_ator_perm) then
      raise exception 'Você só pode liberar módulos aos quais você mesmo tem acesso.' using errcode = '42501';
    end if;
  end if;
  return v;
end;
$function$;


-- =====================================================================
-- FUNÇÕES DO SCHEMA PUBLIC
-- =====================================================================

-- public.configuracao_venda_sem_estoque_definir(p_permitir boolean)
CREATE OR REPLACE FUNCTION public.configuracao_venda_sem_estoque_definir(p_permitir boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa uuid := private.exigir_empresa_ativa();
begin
  if not private.perm('configuracoes') then
    raise exception 'Você não tem permissão para alterar as configurações.' using errcode = '42501';
  end if;
  if p_permitir is null then
    raise exception 'Valor inválido.';
  end if;
  insert into public.configuracoes_empresa as c (empresa_id, permitir_venda_sem_estoque, atualizado_por)
  values (v_empresa, p_permitir, (select auth.uid()))
  on conflict (empresa_id) do update
     set permitir_venda_sem_estoque = excluded.permitir_venda_sem_estoque,
         atualizado_por = excluded.atualizado_por;
  return p_permitir;
end;
$function$;

-- public.fiscal_emitir_nota(p_venda_id uuid)
CREATE OR REPLACE FUNCTION public.fiscal_emitir_nota(p_venda_id uuid)
 RETURNS SETOF documentos_fiscais
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not private.perm_alguma(array['fiscal','pdv']) then
    raise exception 'Você não tem permissão para emitir documentos fiscais.' using errcode = '42501';
  end if;
  return query select * from private.fiscal_emitir_nota(p_venda_id);
end;
$function$;

-- public.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero integer)
CREATE OR REPLACE FUNCTION public.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not private.perm_alguma(array['configuracoes','fiscal']) then
    raise exception 'Você não tem permissão para configurar a numeração fiscal.' using errcode = '42501';
  end if;
  return private.fiscal_inicializar_contador(p_tipo_documento, p_serie, p_ultimo_numero);
end;
$function$;

-- public.florest_aplicar_assinatura(p_empresa_id uuid, p_assinatura_id uuid, p_revisao bigint, p_status_conta text, p_vencimento date, p_motivo text, p_ator text)
CREATE OR REPLACE FUNCTION public.florest_aplicar_assinatura(p_empresa_id uuid, p_assinatura_id uuid, p_revisao bigint, p_status_conta text, p_vencimento date, p_motivo text DEFAULT NULL::text, p_ator text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_emp    public.empresas%rowtype;
  v_ator   text := left(nullif(btrim(coalesce(p_ator, '')), ''), 200);
  v_motivo text := left(nullif(btrim(coalesce(p_motivo, '')), ''), 500);
  v_novo   public.empresas%rowtype;
begin
  -- validação de entrada (antes de tocar em qualquer linha)
  if p_empresa_id is null or p_assinatura_id is null or p_revisao is null or p_revisao < 1 then
    raise exception 'FS001: empresa_id, assinatura_id e revisao (>= 1) são obrigatórios.' using errcode = 'FS001';
  end if;
  if p_status_conta is null or p_status_conta not in ('pendente','aprovado','bloqueado') then
    raise exception 'FS002: status_conta inválido (use pendente, aprovado ou bloqueado).' using errcode = 'FS002';
  end if;
  if p_status_conta = 'aprovado' and p_vencimento is null then
    raise exception 'FS003: vencimento é obrigatório para aprovar.' using errcode = 'FS003';
  end if;

  -- trava a empresa: dois comandos simultâneos são serializados
  select * into v_emp from public.empresas where id = p_empresa_id for update;
  if not found then
    raise exception 'FS004: empresa não encontrada.' using errcode = 'FS004';
  end if;

  -- proteção: nunca trocar a assinatura já vinculada (vale mesmo para revisão antiga)
  if v_emp.assinatura_id is not null and v_emp.assinatura_id <> p_assinatura_id then
    raise exception 'FS005: esta empresa já está vinculada a outra assinatura.' using errcode = 'FS005';
  end if;

  -- idempotência por revisão
  if p_revisao <= v_emp.florest_revisao then
    return jsonb_build_object(
      'ok', true, 'aplicado', false,
      'motivo', case when p_revisao = v_emp.florest_revisao then 'revisao_repetida' else 'revisao_antiga' end,
      'revisao_atual', v_emp.florest_revisao,
      'status_conta', v_emp.status_conta,
      'vencimento', v_emp.vencimento);
  end if;

  -- a assinatura não pode estar vinculada a OUTRA empresa
  if exists (select 1 from public.empresas o where o.assinatura_id = p_assinatura_id and o.id <> p_empresa_id) then
    raise exception 'FS006: esta assinatura já está vinculada a outra empresa.' using errcode = 'FS006';
  end if;

  -- aplica. bloqueado NÃO é enviado: o trigger private.empresas_regras o deriva de status_conta
  -- e carimba aprovado_em / bloqueado_em nas transições. Aqui ficam aprovado_por e bloqueado_motivo.
  update public.empresas
     set assinatura_id    = p_assinatura_id,
         status_conta     = p_status_conta,
         vencimento       = p_vencimento,
         florest_revisao  = p_revisao,
         florest_sync_em  = now(),
         aprovado_por     = case when p_status_conta = 'aprovado'  and v_emp.status_conta <> 'aprovado'
                                 then coalesce(v_ator, 'florest-sync') else aprovado_por end,
         bloqueado_motivo = case when p_status_conta = 'bloqueado' and v_emp.status_conta <> 'bloqueado'
                                 then coalesce(v_motivo, 'nao_informado') else bloqueado_motivo end
   where id = p_empresa_id
   returning * into v_novo;

  return jsonb_build_object(
    'ok', true, 'aplicado', true,
    'revisao_anterior', v_emp.florest_revisao,
    'revisao_atual', v_novo.florest_revisao,
    'status_conta', v_novo.status_conta,
    'bloqueado', v_novo.bloqueado,
    'vencimento', v_novo.vencimento);
end;
$function$;

-- public.florest_listar_empresas(p_apos_atualizado timestamp with time zone, p_apos_id uuid, p_limite integer)
CREATE OR REPLACE FUNCTION public.florest_listar_empresas(p_apos_atualizado timestamp with time zone DEFAULT NULL::timestamp with time zone, p_apos_id uuid DEFAULT NULL::uuid, p_limite integer DEFAULT 200)
 RETURNS TABLE(empresa_id uuid, nome text, status_conta text, bloqueado boolean, vencimento date, assinatura_id uuid, revisao bigint, criado_em timestamp with time zone, atualizado_em timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select e.id, e.nome, e.status_conta, e.bloqueado, e.vencimento, e.assinatura_id,
         e.florest_revisao, e.criado_em, e.atualizado_em
    from public.empresas e
   where p_apos_atualizado is null
      or (e.atualizado_em, e.id) > (p_apos_atualizado, coalesce(p_apos_id, '00000000-0000-0000-0000-000000000000'::uuid))
   order by e.atualizado_em, e.id
   limit least(greatest(coalesce(p_limite, 200), 1), 500);
$function$;

-- public.florest_obter_empresa(p_empresa_id uuid)
CREATE OR REPLACE FUNCTION public.florest_obter_empresa(p_empresa_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  declare
    v_res jsonb;
  begin
    select jsonb_build_object(
             'versao', 1,
             'empresa_id', e.id,
             'nome', e.nome,
             'status_conta', e.status_conta,
             'bloqueado', e.bloqueado,
             'vencimento', e.vencimento,
             'assinatura_id', e.assinatura_id,
             'revisao', e.florest_revisao,
             'criado_em', e.criado_em,
             'responsavel', pf.nome,
             'email', u.email::text,
             'email_confirmado', (u.email_confirmed_at is not null),
             -- dados cadastrais (cadastros antigos: null)
             'razao_social', e.razao_social,
             'cnpj', e.cnpj,
             'telefone', e.telefone,
             'cep', e.cep,
             'logradouro', e.logradouro,
             'numero', e.numero,
             'complemento', e.complemento,
             'bairro', e.bairro,
             'cidade', e.cidade,
             'uf', e.uf)
      into v_res
      from public.empresas e
      left join lateral (select p.id, p.nome
                           from public.perfis p
                          where p.empresa_id = e.id
                          order by p.criado_em, p.id
                          limit 1) pf on true
      left join auth.users u on u.id = pf.id
     where e.id = p_empresa_id;
    return v_res;
  end;
  $function$;

-- public.florest_outbox_concluir(p_id bigint, p_ok boolean, p_erro text)
CREATE OR REPLACE FUNCTION public.florest_outbox_concluir(p_id bigint, p_ok boolean, p_erro text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_o      public.florest_outbox%rowtype;
  v_espera integer;
begin
  select * into v_o from public.florest_outbox where id = p_id for update;
  if not found then
    raise exception 'FS007: evento do outbox não encontrado.' using errcode = 'FS007';
  end if;
  if v_o.status = 'enviado' then
    return 'enviado';                                  -- idempotente
  end if;

  if coalesce(p_ok, false) then
    update public.florest_outbox
       set status = 'enviado', enviado_em = now(), reservado_ate = null, ultimo_erro = null
     where id = p_id;
    return 'enviado';
  end if;

  if v_o.tentativas >= 20 then
    update public.florest_outbox
       set status = 'falhou', reservado_ate = null, ultimo_erro = left(p_erro, 500)
     where id = p_id;
    return 'falhou';
  end if;

  v_espera := (array[60, 300, 900, 3600, 21600])[least(greatest(v_o.tentativas, 1), 5)];
  update public.florest_outbox
     set status = 'pendente', reservado_ate = null, ultimo_erro = left(p_erro, 500),
         proxima_tentativa_em = now() + make_interval(secs => v_espera)
   where id = p_id;
  return 'pendente';
end;
$function$;

-- public.florest_outbox_reenfileirar(p_event_id uuid)
CREATE OR REPLACE FUNCTION public.florest_outbox_reenfileirar(p_event_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  update public.florest_outbox
     set status = 'pendente', tentativas = 0, proxima_tentativa_em = now(), reservado_ate = null
   where event_id = p_event_id and status in ('pendente','falhou');
  return found;
end;
$function$;

-- public.florest_outbox_reservar(p_limite integer, p_lease_segundos integer, p_empresa_id uuid)
CREATE OR REPLACE FUNCTION public.florest_outbox_reservar(p_limite integer DEFAULT 10, p_lease_segundos integer DEFAULT 60, p_empresa_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id bigint, event_id uuid, tipo text, empresa_id uuid, criado_em timestamp with time zone, tentativas integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
begin
  -- reserva vencida (despachador caiu) que já gastou as 20 tentativas: encerra como falhou
  update public.florest_outbox o
     set status = 'falhou', reservado_ate = null,
         ultimo_erro = coalesce(o.ultimo_erro, 'reserva expirada após 20 tentativas')
   where o.status = 'enviando' and o.reservado_ate <= now() and o.tentativas >= 20;

  return query
  with escolhidos as (
    select o.id
      from public.florest_outbox o
     where ((o.status = 'pendente'  and o.proxima_tentativa_em <= now())
         or (o.status = 'enviando'  and o.reservado_ate        <= now()))
       and (p_empresa_id is null or o.empresa_id = p_empresa_id)
     order by o.id
     limit least(greatest(coalesce(p_limite, 10), 1), 50)
     for update skip locked
  )
  update public.florest_outbox o
     set status        = 'enviando',
         reservado_ate = now() + make_interval(secs => least(greatest(coalesce(p_lease_segundos, 60), 10), 900)),
         tentativas    = o.tentativas + 1
    from escolhidos e
   where o.id = e.id
  returning o.id, o.event_id, o.tipo, o.empresa_id, o.criado_em, o.tentativas;
end;
$function$;

-- public.notas_entrada_confirmar(p_nota jsonb)
CREATE OR REPLACE FUNCTION public.notas_entrada_confirmar(p_nota jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not private.perm('notas_entrada') then
    raise exception 'Você não tem permissão para lançar notas de entrada.' using errcode = '42501';
  end if;
  return private.notas_entrada_confirmar(p_nota);
end;
$function$;

-- public.pdv_atalhos_listar()
CREATE OR REPLACE FUNCTION public.pdv_atalhos_listar()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa uuid := private.exigir_empresa_ativa();
begin
  if not private.perm('pdv') then
    raise exception 'Você não tem permissão para usar o PDV.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id,
             'nome', a.nome,
             'imagem', a.imagem,
             'produtos', coalesce((
                select jsonb_agg(jsonb_build_object('produto_id', ap.produto_id, 'imagem', ap.imagem)
                                 order by ap.ordem, ap.produto_id)
                  from public.pdv_atalhos_produtos ap
                 where ap.atalho_id = a.id and ap.empresa_id = a.empresa_id), '[]'::jsonb))
           order by a.ordem, a.criado_em, a.id)
      from public.pdv_atalhos a
     where a.empresa_id = v_empresa), '[]'::jsonb);
end;
$function$;

-- public.pdv_atalhos_salvar(p_atalhos jsonb)
CREATE OR REPLACE FUNCTION public.pdv_atalhos_salvar(p_atalhos jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa uuid := private.exigir_empresa_ativa();
  v_uid     uuid := (select auth.uid());
  v_a       jsonb;
  v_p       jsonb;
  v_id      uuid;
  v_ordem   integer := 0;
  v_pord    integer;
  v_ids     uuid[] := '{}';
  v_pid     uuid;
  v_img     text;
begin
  if not exists (select 1 from public.perfis p
                  where p.id = v_uid and p.empresa_id = v_empresa and p.ativo and p.papel = 'proprietario') then
    raise exception 'Só o proprietário da empresa pode configurar os atalhos do PDV.' using errcode = '42501';
  end if;
  if p_atalhos is null or jsonb_typeof(p_atalhos) <> 'array' then
    raise exception 'Lista de atalhos inválida.';
  end if;
  if jsonb_array_length(p_atalhos) > 30 then
    raise exception 'No máximo 30 atalhos por empresa.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('pdv_atalhos:' || v_empresa::text, 0));

  for v_a in select value from jsonb_array_elements(p_atalhos) loop
    begin
      v_id := (v_a->>'id')::uuid;
    exception when others then
      raise exception 'Atalho com identificador inválido.';
    end;
    if v_id = any (v_ids) then
      raise exception 'Atalho repetido na lista.';
    end if;
    if length(btrim(coalesce(v_a->>'nome', ''))) not between 1 and 40 then
      raise exception 'O nome do atalho deve ter de 1 a 40 caracteres.';
    end if;
    if jsonb_typeof(coalesce(v_a->'produtos', '[]'::jsonb)) <> 'array'
       or jsonb_array_length(coalesce(v_a->'produtos', '[]'::jsonb)) > 100 then
      raise exception 'No máximo 100 produtos por atalho.';
    end if;
    -- um id de atalho de OUTRA empresa nunca é sobrescrito
    if exists (select 1 from public.pdv_atalhos x where x.id = v_id and x.empresa_id <> v_empresa) then
      raise exception 'Atalho com identificador inválido.';
    end if;
    v_ids := v_ids || v_id;

    insert into public.pdv_atalhos as t (id, empresa_id, nome, imagem, ordem, atualizado_por)
    values (v_id, v_empresa, btrim(v_a->>'nome'), nullif(v_a->>'imagem', ''), v_ordem, v_uid)
    on conflict (id) do update
       set nome = excluded.nome, imagem = excluded.imagem, ordem = excluded.ordem,
           atualizado_por = excluded.atualizado_por
     where t.empresa_id = v_empresa;
    v_ordem := v_ordem + 1;

    delete from public.pdv_atalhos_produtos where atalho_id = v_id and empresa_id = v_empresa;
    v_pord := 0;
    for v_p in select value from jsonb_array_elements(coalesce(v_a->'produtos', '[]'::jsonb)) loop
      begin
        v_pid := (v_p->>'produto_id')::uuid;
      exception when others then
        continue;
      end;
      v_img := nullif(v_p->>'imagem', '');
      insert into public.pdv_atalhos_produtos (atalho_id, empresa_id, produto_id, ordem, imagem)
      select v_id, v_empresa, pr.id, v_pord, v_img
        from public.produtos pr
       where pr.id = v_pid and pr.empresa_id = v_empresa
      on conflict (atalho_id, produto_id) do nothing;
      v_pord := v_pord + 1;
    end loop;
  end loop;

  delete from public.pdv_atalhos where empresa_id = v_empresa and not (id = any (v_ids));
  return v_ordem;
end;
$function$;

-- public.pdv_produtos_consultar(p_ids uuid[], p_gtins text[], p_codigo text, p_busca text, p_limite integer)
CREATE OR REPLACE FUNCTION public.pdv_produtos_consultar(p_ids uuid[] DEFAULT NULL::uuid[], p_gtins text[] DEFAULT NULL::text[], p_codigo text DEFAULT NULL::text, p_busca text DEFAULT NULL::text, p_limite integer DEFAULT 10)
 RETURNS TABLE(id uuid, nome text, codigo text, gtin text, preco_venda numeric, quantidade_estoque numeric, unidade_comercial text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa uuid := private.exigir_empresa_ativa();
  v_lim     integer := least(greatest(coalesce(p_limite, 10), 1), 50);
  v_busca   text := nullif(btrim(coalesce(p_busca, '')), '');
  v_pad     text;
begin
  if not private.perm('pdv') then
    raise exception 'Você não tem permissão para usar o PDV.' using errcode = '42501';
  end if;
  if p_ids is not null and cardinality(p_ids) > 100 then
    raise exception 'Muitos produtos na consulta.';
  end if;
  if p_gtins is not null and cardinality(p_gtins) > 20 then
    raise exception 'Muitos códigos de barras na consulta.';
  end if;
  if p_ids is not null then v_lim := 100; end if;
  if v_busca is not null then
    v_pad := '%' || replace(replace(replace(left(v_busca, 80), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;
  if p_ids is null and p_gtins is null and nullif(p_codigo, '') is null and v_busca is null then
    return;
  end if;

  return query
    select p.id, p.nome, p.codigo, p.gtin, p.preco_venda, p.quantidade_estoque, p.unidade_comercial
      from public.produtos p
     where p.empresa_id = v_empresa
       and ( (p_ids is not null   and p.id = any (p_ids))
          or (p_gtins is not null and p.gtin = any (p_gtins))
          or (nullif(p_codigo, '') is not null and p.codigo = p_codigo)
          or (v_busca is not null and (p.nome ilike v_pad or p.codigo ilike v_pad or p.gtin ilike v_pad)) )
     order by p.nome, p.id
     limit v_lim;
end;
$function$;

-- public.registrar_empresa(nome_empresa text, nome_responsavel text)
CREATE OR REPLACE FUNCTION public.registrar_empresa(nome_empresa text, nome_responsavel text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_uid     uuid := (select auth.uid());

  v_nome    text := btrim(coalesce(nome_empresa, ''));

  v_resp    text := btrim(coalesce(nome_responsavel, ''));

  v_empresa uuid;

begin

  if v_uid is null then

    raise exception 'Sessão inválida. Faça login novamente.' using errcode = '28000';

  end if;

  if length(v_nome) < 2 or length(v_nome) > 200 then

    raise exception 'Informe o nome da empresa (2 a 200 caracteres).';

  end if;

  if length(v_resp) < 2 or length(v_resp) > 200 then

    raise exception 'Informe o nome do responsável (2 a 200 caracteres).';

  end if;

  if exists (select 1 from public.perfis where id = v_uid) then

    raise exception 'Este usuário já possui uma empresa cadastrada.';

  end if;

  -- nasce pendente e bloqueada (padrões da tabela; o trigger private.empresas_regras reforça)

  insert into public.empresas (nome, status_conta)

  values (v_nome, 'pendente')

  returning id into v_empresa;

  insert into public.perfis (id, empresa_id, nome)

  values (v_uid, v_empresa, v_resp);

  return v_empresa;

end;

$function$;

-- public.registrar_empresa_completa(p_dados jsonb)
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
    v_n  := private.florest_normalizar_cadastro(v_in, 'estrito');            -- erro CE001 com o nome do campo

    if exists (select 1 from public.perfis where id = v_uid) then
      raise exception 'CE003: Este usuário já possui uma empresa cadastrada.' using errcode = 'CE003';
    end if;

    -- nasce pendente e bloqueada (padrões da tabela; private.empresas_regras reforça). O evento cadastro_criado é enfileirado pelo gatilho existente.
    insert into public.empresas (nome, status_conta, razao_social, cnpj, telefone, cep, logradouro, numero, complemento, bairro, cidade, uf)
    values (v_n ->> 'nome', 'pendente', v_n ->> 'razao_social', v_n ->> 'cnpj', v_n ->> 'telefone', v_n ->> 'cep', v_n ->> 'logradouro',
            v_n ->> 'numero', v_n ->> 'complemento', v_n ->> 'bairro', v_n ->> 'cidade', v_n ->> 'uf')
    returning id into v_empresa;

    insert into public.perfis (id, empresa_id, nome)
    values (v_uid, v_empresa, v_n ->> 'responsavel');

    return v_empresa;
  end;
  $function$;

-- public.registrar_venda(p_cliente_id uuid, p_forma_pagamento text, p_itens jsonb)
CREATE OR REPLACE FUNCTION public.registrar_venda(p_cliente_id uuid, p_forma_pagamento text, p_itens jsonb)
 RETURNS TABLE(venda_id uuid, numero_venda integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare
  v_empresa uuid := private.exigir_empresa_ativa();
  v_forma   text := btrim(coalesce(p_forma_pagamento, ''));
  v_venda   uuid;
  v_numero  integer;
  v_invalido boolean;
  r         record;
  v_nome    text;
  v_estoque numeric;
  v_sem_estoque boolean;
begin
  -- permissão de módulo (proprietário sempre pode; funcionário precisa de PDV)
  if not private.perm('pdv') then
    raise exception 'Você não tem permissão para registrar vendas.' using errcode = '42501';
  end if;
  -- configuração POR EMPRESA (sem linha = desligado = comportamento antigo)
  select coalesce((select c.permitir_venda_sem_estoque from public.configuracoes_empresa c where c.empresa_id = v_empresa), false)
    into v_sem_estoque;
  if v_forma = '' or length(v_forma) > 40 then
    raise exception 'Forma de pagamento inválida.';
  end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'A venda precisa ter pelo menos um item.';
  end if;
  if jsonb_array_length(p_itens) > 500 then
    raise exception 'Itens demais em uma única venda (máximo 500).';
  end if;
  if p_cliente_id is not null and not exists (
       select 1 from public.clientes c where c.id = p_cliente_id and c.empresa_id = v_empresa) then
    raise exception 'Cliente não encontrado.';
  end if;

  -- valida os itens (tipos, quantidade > 0, preço >= 0)
  begin
    select exists (
      select 1 from jsonb_to_recordset(p_itens) as x(produto_id uuid, quantidade numeric, preco_unitario numeric)
       where x.produto_id is null or x.quantidade is null or x.quantidade <= 0
          or x.preco_unitario is null or x.preco_unitario < 0
    ) into v_invalido;
  exception when others then
    v_invalido := true;
  end;
  if v_invalido then
    raise exception 'Item da venda inválido (produto, quantidade maior que zero e preço são obrigatórios).';
  end if;

  -- trava os produtos (ordem fixa = sem deadlock), confere estoque e dá baixa
  for r in
    select x.produto_id, sum(round(x.quantidade, 4)) as qtd
      from jsonb_to_recordset(p_itens) as x(produto_id uuid, quantidade numeric, preco_unitario numeric)
     group by x.produto_id
     order by x.produto_id
  loop
    select p.nome, p.quantidade_estoque into v_nome, v_estoque
      from public.produtos p
     where p.id = r.produto_id and p.empresa_id = v_empresa
       for update;
    if not found then
      raise exception 'Produto não encontrado.';
    end if;
    if v_estoque < r.qtd and not v_sem_estoque then
      raise exception 'Estoque insuficiente para "%": disponível %, solicitado %.', v_nome, v_estoque, r.qtd;
    end if;
    update public.produtos set quantidade_estoque = quantidade_estoque - r.qtd
     where id = r.produto_id and empresa_id = v_empresa;
  end loop;

  -- número sequencial por empresa (a linha do contador serializa vendas simultâneas)
  insert into public.contadores_venda as c (empresa_id, ultimo_numero)
  values (v_empresa, 1)
  on conflict (empresa_id) do update set ultimo_numero = c.ultimo_numero + 1
  returning c.ultimo_numero into v_numero;

  insert into public.vendas (empresa_id, numero_venda, cliente_id, forma_pagamento, total, criado_por)
  values (v_empresa, v_numero, p_cliente_id, v_forma, 0, (select auth.uid()))
  returning id into v_venda;

  insert into public.itens_venda (empresa_id, venda_id, produto_id, quantidade, preco_unitario)
  select v_empresa, v_venda, x.produto_id, round(x.quantidade, 4), round(x.preco_unitario, 2)
    from rows from (jsonb_to_recordset(p_itens) as (produto_id uuid, quantidade numeric, preco_unitario numeric))
         with ordinality as x(produto_id, quantidade, preco_unitario, ordem)
   order by x.ordem;

  update public.vendas v
     set total = (select coalesce(sum(i.subtotal), 0) from public.itens_venda i where i.venda_id = v_venda)
   where v.id = v_venda;

  venda_id := v_venda;
  numero_venda := v_numero;
  return next;
end;
$function$;

-- public.usuarios_atualizar(p_id uuid, p_nome text, p_ativo boolean, p_permissoes text[])
CREATE OR REPLACE FUNCTION public.usuarios_atualizar(p_id uuid, p_nome text DEFAULT NULL::text, p_ativo boolean DEFAULT NULL::boolean, p_permissoes text[] DEFAULT NULL::text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid  uuid := (select auth.uid());
  v_a    record;
  v_nome text;
  v_perm text[];
begin
  select * into v_a from private.usuarios_alvo(v_uid, p_id);
  if p_nome is not null then
    v_nome := btrim(p_nome);
    if length(v_nome) < 2 or length(v_nome) > 200 then
      raise exception 'Informe o nome do usuário (2 a 200 caracteres).';
    end if;
  end if;
  if p_permissoes is not null then
    v_perm := private.usuarios_normalizar_permissoes(p_permissoes, v_a.o_papel_ator, v_a.o_perm_ator);
  end if;
  update public.perfis p
     set nome = coalesce(v_nome, p.nome),
         ativo = coalesce(p_ativo, p.ativo),
         permissoes = coalesce(v_perm, p.permissoes)
   where p.id = p_id and p.empresa_id = v_a.o_empresa and p.papel = 'funcionario';
end;
$function$;

-- public.usuarios_autorizar_alvo(p_ator uuid, p_alvo uuid)
CREATE OR REPLACE FUNCTION public.usuarios_autorizar_alvo(p_ator uuid, p_alvo uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform private.usuarios_alvo(p_ator, p_alvo);
end;
$function$;

-- public.usuarios_listar()
CREATE OR REPLACE FUNCTION public.usuarios_listar()
 RETURNS TABLE(id uuid, nome text, email text, papel text, ativo boolean, permissoes text[], criado_em timestamp with time zone, ultimo_acesso timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_emp uuid;
begin
  select a.o_empresa into v_emp from private.usuarios_ator((select auth.uid())) a;
  return query
    select p.id, p.nome, u.email::text, p.papel, p.ativo, p.permissoes, p.criado_em, u.last_sign_in_at
      from public.perfis p
      left join auth.users u on u.id = p.id
     where p.empresa_id = v_emp
     order by (p.papel = 'proprietario') desc, p.nome, p.id;
end;
$function$;

-- public.usuarios_preparar_criacao(p_ator uuid, p_permissoes text[])
CREATE OR REPLACE FUNCTION public.usuarios_preparar_criacao(p_ator uuid, p_permissoes text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_a record;
begin
  select * into v_a from private.usuarios_ator(p_ator);
  perform private.usuarios_normalizar_permissoes(p_permissoes, v_a.o_papel, v_a.o_permissoes);
  if (select count(*) from public.perfis p where p.empresa_id = v_a.o_empresa and p.papel = 'funcionario') >= 50 then
    raise exception 'Limite de 50 funcionários por empresa atingido.';
  end if;
end;
$function$;

-- public.usuarios_vincular(p_ator uuid, p_user_id uuid, p_nome text, p_permissoes text[])
CREATE OR REPLACE FUNCTION public.usuarios_vincular(p_ator uuid, p_user_id uuid, p_nome text, p_permissoes text[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_a    record;
  v_nome text := btrim(coalesce(p_nome, ''));
  v_perm text[];
begin
  select * into v_a from private.usuarios_ator(p_ator);
  v_perm := private.usuarios_normalizar_permissoes(p_permissoes, v_a.o_papel, v_a.o_permissoes);
  if length(v_nome) < 2 or length(v_nome) > 200 then
    raise exception 'Informe o nome do usuário (2 a 200 caracteres).';
  end if;
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'Usuário de autenticação não encontrado.';
  end if;
  if exists (select 1 from public.perfis p where p.id = p_user_id) then
    raise exception 'Este e-mail já está vinculado a uma empresa.';
  end if;
  if (select count(*) from public.perfis p where p.empresa_id = v_a.o_empresa and p.papel = 'funcionario') >= 50 then
    raise exception 'Limite de 50 funcionários por empresa atingido.';
  end if;
  insert into public.perfis (id, empresa_id, nome, papel, permissoes, ativo, criado_por)
  values (p_user_id, v_a.o_empresa, v_nome, 'funcionario', v_perm, true, p_ator);
  return p_user_id;
end;
$function$;


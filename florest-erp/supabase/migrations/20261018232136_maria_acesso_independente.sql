-- PREPARAÇÃO SOMENTE: não aplicar em produção sem aprovação.
-- Derivada das definições publicadas recuperadas em 18/10/2026; gates existentes preservados.
-- Nenhum UPDATE/INSERT de usuários, empresas ou permissões reais.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
CREATE OR REPLACE FUNCTION private.usuarios_modulos()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select array['maria','dashboard','clientes','produtos','estoque','pdv','fornecedores',
               'notas_entrada','financeiro','fiscal','relatorios','configuracoes','usuarios',
               'pets','agenda','pacotes',
               'bar_visualizar','bar_mesas','bar_pedidos','bar_caixa','bar_portaria',
               'bar_configurar','bar_cancelar_pedido','bar_corrigir_pessoas',
               'bar_estornar_pagamento']::text[]
$function$;
ALTER TABLE public.perfis DROP CONSTRAINT perfis_permissoes_ck;
ALTER TABLE public.perfis ADD CONSTRAINT perfis_permissoes_ck CHECK (permissoes <@ ARRAY['maria'::text, 'dashboard'::text, 'clientes'::text, 'produtos'::text, 'estoque'::text, 'pdv'::text, 'fornecedores'::text, 'notas_entrada'::text, 'financeiro'::text, 'fiscal'::text, 'relatorios'::text, 'configuracoes'::text, 'usuarios'::text, 'pets'::text, 'agenda'::text, 'pacotes'::text, 'bar_visualizar'::text, 'bar_mesas'::text, 'bar_pedidos'::text, 'bar_caixa'::text, 'bar_portaria'::text, 'bar_configurar'::text, 'bar_cancelar_pedido'::text, 'bar_corrigir_pessoas'::text, 'bar_estornar_pagamento'::text]);
CREATE OR REPLACE FUNCTION private.maria_exigir_acesso(p_recurso text DEFAULT 'acesso', p_foco text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path TO ''
AS $maria_access$
begin
  -- Reutiliza o contexto existente, que valida Auth, perfil ativo e empresa aprovada/não bloqueada.
  perform private.maria_empresa();
  if auth.uid() is null or not private.perm('maria') then
    raise exception 'MARIA_SEM_PERMISSAO' using errcode='42501';
  end if;
  -- Permissão de entrada nunca substitui autorização dos dados. Gates originais continuam abaixo.
  if p_recurso = any(array['maria_resumo_vendas_hoje','maria_resumo_vendas_ontem',
    'maria_resumo_vendas_mes','maria_formas_pagamento_mes','maria_produtos_mais_vendidos_mes',
    'maria_ranking_produtos','maria_pagamento_por_semana','maria_produto_por_dia_semana',
    'maria_comparar_produtos','maria_clientes_ranking','maria_clientes_situacao',
    'maria_comparar_clientes','maria_panorama']) and not private.perm('relatorios') then
    raise exception 'MARIA_SEM_PERMISSAO' using errcode='42501';
  end if;
  if p_recurso='maria_bar_analise' and lower(btrim(coalesce(p_foco,'agora'))) <> 'agora'
     and not private.perm_alguma(array['relatorios','financeiro']) then
    raise exception 'MARIA_SEM_PERMISSAO' using errcode='42501';
  end if;
  if p_recurso='maria_produto_detalhe' and not private.perm_alguma(array['produtos','relatorios']) then
    raise exception 'MARIA_SEM_PERMISSAO' using errcode='42501';
  end if;
  if p_recurso='maria_estoque_analise' then
    if not private.perm_alguma(array['produtos','estoque','notas_entrada','fiscal','relatorios']) then
      raise exception 'MARIA_SEM_PERMISSAO' using errcode='42501';
    end if;
    if lower(btrim(coalesce(p_foco,''))) <> 'abaixo_minimo'
       and not private.perm('relatorios') then
      raise exception 'MARIA_SEM_PERMISSAO' using errcode='42501';
    end if;
  end if;
end;
$maria_access$;
REVOKE ALL ON FUNCTION private.maria_exigir_acesso(text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION private.maria_exigir_acesso(text,text) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.maria_autorizar()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path TO ''
AS $maria_auth$
begin
  perform private.maria_exigir_acesso();
  return true;
end;
$maria_auth$;
REVOKE ALL ON FUNCTION public.maria_autorizar() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.maria_autorizar() TO authenticated,service_role;
CREATE OR REPLACE FUNCTION public.maria_acao_pendente_atual()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_emp uuid := private.exigir_empresa_ativa(); r record;
begin
  perform private.maria_exigir_acesso('maria_acao_pendente_atual');
  select a.id, a.tipo, a.resumo, a.reforcada, a.expira_em into r from public.maria_acoes_pendentes a
   where a.empresa_id = v_emp and a.user_id = auth.uid() and a.status = 'pendente' and a.expira_em > now()
   order by a.criado_em desc limit 1;
  if not found then return jsonb_build_object('pendente', false); end if;
  return jsonb_build_object('pendente', true, 'acao_id', r.id, 'tipo', r.tipo, 'resumo', r.resumo,
                            'reforcada', r.reforcada, 'expira_em', r.expira_em);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_acao_preparar(p_tipo text, p_params jsonb, p_interacao_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_emp uuid; v_uid uuid := auth.uid(); v_cfg jsonb; v_bl text; v_n jsonb; v_ttl integer; v_id uuid;
  v_tipo text := lower(btrim(coalesce(p_tipo, ''))); v_ref boolean; v_exp timestamptz; r record;
begin
  perform private.maria_exigir_acesso('maria_acao_preparar');
  perform private.maria_exigir_servidor();
  v_emp := private.exigir_empresa_ativa();
  v_cfg := private.maria_config_efetiva(v_emp);
  if not (v_cfg->>'ativa')::boolean then
    return jsonb_build_object('ok', false, 'codigo', 'desativada', 'mensagem', 'A MARIA não está ativa para a sua empresa. Entre em contato com a Florest Sistemas.'); end if;
  if not (v_cfg->>'permite_acoes')::boolean then
    return jsonb_build_object('ok', false, 'codigo', 'acoes_indisponiveis', 'mensagem', 'Seu plano atual da MARIA não inclui a realização de ações. Entre em contato com a Florest Sistemas.'); end if;
  if p_params is null or jsonb_typeof(p_params) <> 'object' or pg_column_size(p_params) > 12000 then
    return jsonb_build_object('ok', false, 'codigo', 'validacao', 'mensagem', 'Não consegui entender os dados da ação. Pode repetir?'); end if;

  v_bl := private.maria_acao_bloqueio(v_tipo);
  if v_bl = 'tipo_invalido' then
    return jsonb_build_object('ok', false, 'codigo', 'tipo_invalido', 'mensagem', 'Essa operação não pode ser feita pela MARIA.'); end if;
  if v_bl is not null then
    perform private.maria_auditar(v_emp, v_uid, 'negada', null, v_tipo, null, null, false,
      case v_bl when 'sem_modulo' then 'Módulo ausente' else 'Sem permissão' end, p_interacao_id);
    return jsonb_build_object('ok', false, 'codigo', v_bl, 'mensagem',
      case v_bl when 'sem_modulo' then 'Esse recurso depende do módulo correspondente.'
                else 'Seu usuário não possui permissão para realizar essa operação.' end);
  end if;

  v_n := private.maria_acao_normalizar(v_emp, v_tipo, p_params);
  if v_n ? 'erro' then return jsonb_build_object('ok', false, 'codigo', 'validacao', 'mensagem', v_n->>'erro'); end if;
  if v_n ? 'ambiguo' then
    return jsonb_build_object('ok', false, 'codigo', 'ambiguo', 'campo', v_n->>'campo', 'candidatos', v_n->'candidatos',
      'mensagem', 'Encontrei mais de uma opção. Pergunte ao usuário qual deseja, sem escolher por conta própria.'); end if;

  v_ref := coalesce((v_n->>'reforcada')::boolean, false) or coalesce((private.maria_acao_requisitos(v_tipo)->>'reforcada')::boolean, false);
  select acao_ttl_minutos into v_ttl from public.maria_config_global where id;
  v_exp := now() + make_interval(mins => v_ttl);

  -- Só existe UMA ação pendente por usuário: as anteriores são encerradas (e auditadas).
  for r in
    update public.maria_acoes_pendentes a set
        status = case when a.expira_em <= now() then 'expirada' else 'cancelada' end,
        decidido_em = now(), erro = case when a.expira_em <= now() then 'Expirada' else 'Substituída por uma nova ação' end
      where a.empresa_id = v_emp and a.user_id = v_uid and a.status = 'pendente'
      returning a.id, a.tipo, a.parametros, a.status as novo_status
  loop
    perform private.maria_auditar(v_emp, v_uid, case when r.novo_status = 'expirada' then 'expirada' else 'substituida' end,
                                  r.id, r.tipo, r.parametros, null, false, null, p_interacao_id);
  end loop;

  insert into public.maria_acoes_pendentes (empresa_id, user_id, tipo, parametros, resumo, reforcada, expira_em, interacao_id)
  values (v_emp, v_uid, v_tipo, v_n->'params', left(v_n->>'resumo', 1500), v_ref, v_exp, p_interacao_id)
  returning id into v_id;
  perform private.maria_auditar(v_emp, v_uid, 'preparada', v_id, v_tipo, v_n->'params', null, false, null, p_interacao_id);

  return jsonb_build_object('ok', true, 'acao_id', v_id, 'tipo', v_tipo, 'resumo', v_n->>'resumo', 'reforcada', v_ref,
                            'expira_em', v_exp, 'validade_minutos', v_ttl);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_acao_responder(p_acao_id uuid DEFAULT NULL::uuid, p_decisao text DEFAULT NULL::text, p_texto text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_emp uuid; v_uid uuid := auth.uid(); v_cfg jsonb; a public.maria_acoes_pendentes%rowtype;
  v_dec text := lower(btrim(coalesce(p_decisao, ''))); v_res jsonb; v_msg text; v_st text; v_code text; v_ret jsonb;
begin
  perform private.maria_exigir_acesso('maria_acao_responder');
  perform private.maria_exigir_servidor();
  v_emp := private.exigir_empresa_ativa();
  v_cfg := private.maria_config_efetiva(v_emp);

  select * into a from public.maria_acoes_pendentes
   where empresa_id = v_emp and user_id = v_uid and status = 'pendente'
     and (p_acao_id is null or id = p_acao_id)
   order by criado_em desc limit 1 for update;
  if not found then
    if p_acao_id is not null then
      select status into v_st from public.maria_acoes_pendentes where id = p_acao_id and empresa_id = v_emp and user_id = v_uid;
      return jsonb_build_object('tipo', 'indisponivel', 'status', v_st,
        'mensagem', 'Essa ação não está mais pendente' || coalesce(' (' || v_st || ')', '') || '. Se ainda quiser, peça novamente.');
    end if;
    return jsonb_build_object('tipo', 'sem_pendencia');
  end if;

  if v_dec not in ('confirmar', 'cancelar') then
    v_dec := coalesce(private.maria_interpretar_resposta(p_texto), '');
    if v_dec = '' then return jsonb_build_object('tipo', 'nao_e_resposta', 'acao_id', a.id, 'resumo', a.resumo); end if;
  end if;

  if a.expira_em <= now() then
    update public.maria_acoes_pendentes set status = 'expirada', decidido_em = now(), erro = 'Expirada' where id = a.id;
    perform private.maria_auditar(v_emp, v_uid, 'expirada', a.id, a.tipo, a.parametros, null, false, null, a.interacao_id);
    return jsonb_build_object('tipo', 'expirada', 'mensagem', 'O prazo para confirmar essa ação terminou. Peça novamente se ainda quiser fazê-la.');
  end if;

  if v_dec = 'cancelar' then
    update public.maria_acoes_pendentes set status = 'cancelada', decidido_em = now() where id = a.id;
    perform private.maria_auditar(v_emp, v_uid, 'cancelada', a.id, a.tipo, a.parametros, null, false, null, a.interacao_id);
    return jsonb_build_object('tipo', 'cancelada', 'mensagem', 'Tudo bem, cancelei. Nada foi alterado.');
  end if;

  -- confirmar
  if not (v_cfg->>'ativa')::boolean or not (v_cfg->>'permite_acoes')::boolean then
    return jsonb_build_object('tipo', 'bloqueada', 'mensagem', 'A MARIA não está habilitada para realizar ações na sua empresa. Entre em contato com a Florest Sistemas.');
  end if;
  if a.reforcada and private.maria_norm(btrim(coalesce(p_texto, ''))) <> 'confirmo' then
    return jsonb_build_object('tipo', 'reforco_necessario', 'acao_id', a.id, 'resumo', a.resumo,
      'mensagem', 'Esta ação é sensível. Para continuar, digite exatamente CONFIRMO. Para desistir, responda "cancelar".');
  end if;

  perform private.maria_auditar(v_emp, v_uid, 'confirmada', a.id, a.tipo, a.parametros, null, true, null, a.interacao_id);
  begin
    v_res := private.maria_acao_executar(v_emp, v_uid, a.id, a.tipo, a.parametros);
    update public.maria_acoes_pendentes set status = 'executada', decidido_em = now(), resultado = v_res where id = a.id;
    perform private.maria_auditar(v_emp, v_uid, 'executada', a.id, a.tipo, a.parametros, v_res, true, null, a.interacao_id);
    return jsonb_build_object('tipo', 'executada', 'mensagem', v_res->>'mensagem', 'registro_id', v_res->>'registro_id');
  exception when others then
    v_code := sqlstate;
    v_msg := case
      when sqlerrm = 'MARIA_SEM_MODULO' or (v_code = '42501' and sqlerrm ilike '%módulo%') then 'Esse recurso depende do módulo correspondente.'
      when v_code = '42501' then 'Seu usuário não possui permissão para realizar essa operação.'
      when v_code = 'P0001' then left(sqlerrm, 300)
      when v_code = '23505' then 'Já existe um registro com esses dados.'
      when v_code in ('23514','22003','22007','22P02') then 'Algum dos valores informados é inválido.'
      else 'Não foi possível concluir a operação. Nada foi alterado.' end;
    update public.maria_acoes_pendentes set status = 'erro', decidido_em = now(), erro = left(v_msg, 500) where id = a.id;
    perform private.maria_auditar(v_emp, v_uid, 'falhou', a.id, a.tipo, a.parametros, null, true, v_msg || ' [' || v_code || ']', a.interacao_id);
    return jsonb_build_object('tipo', 'falhou', 'mensagem', v_msg);
  end;
end $function$;

CREATE OR REPLACE FUNCTION public.maria_auditoria_minha(p_limite integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_emp uuid := private.exigir_empresa_ativa(); v_lim integer := private.maria_lim(p_limite, 30, 100);
begin
  perform private.maria_exigir_acesso('maria_auditoria_minha');
  if not exists (select 1 from public.perfis where id = auth.uid() and papel = 'proprietario' and ativo) then
    raise exception 'Apenas o proprietário da empresa pode ver a auditoria da MARIA.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x)) from (
    select quando, user_id, evento, tipo, parametros, resultado, confirmada, erro from public.maria_auditoria
     where empresa_id = v_emp and evento <> 'config_admin' order by quando desc, id desc limit v_lim) x), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_bar_analise(p_foco text DEFAULT 'agora'::text, p_inicio date DEFAULT NULL::date, p_fim date DEFAULT NULL::date, p_limite integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_foco text := lower(btrim(coalesce(p_foco,'agora')));
  v_lim integer := private.maria_lim(p_limite, 10, 30);
  p record; ts_i timestamptz; ts_f timestamptz; v_itens jsonb; t record; v_extra jsonb := '{}'::jsonb;
  c_op constant text[] := array['bar_visualizar','bar_mesas','bar_pedidos','bar_caixa','bar_configurar'];
  c_pg constant text[] := array['bar_caixa','bar_configurar','bar_estornar_pagamento','financeiro','relatorios','dashboard'];
begin
  perform private.maria_exigir_acesso('maria_bar_analise', p_foco);
  if v_foco not in ('agora','periodo','produtos','horarios','pagamentos','destino') then
    raise exception 'Foco inválido para o Bar.';
  end if;
  if v_foco in ('agora','produtos','destino') then perform private.maria_exigir(c_op, 'bar');
  else perform private.maria_exigir(c_pg, 'bar'); end if;
  select * into p from private.maria_periodo(p_inicio, p_fim);
  ts_i := p.o_ini::timestamp at time zone 'America/Sao_Paulo';
  ts_f := (p.o_fim + 1)::timestamp at time zone 'America/Sao_Paulo';

  if v_foco = 'agora' then
    select count(*) filter (where status = 'ocupada') as ocupadas, count(*) as total,
           coalesce(sum(pessoas_atual) filter (where status = 'ocupada'),0) as pessoas into t
      from public.bar_mesas where empresa_id = v_emp;
    select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
      select m.numero as mesa, m.pessoas_atual as pessoas, m.aberta_em,
             round(extract(epoch from (now() - m.aberta_em)) / 60) as minutos_aberta,
             coalesce((select sum(i.quantidade * i.preco_unitario) from public.bar_pedidos_itens i
                        where i.empresa_id = v_emp and i.comanda_id = m.comanda_atual_id and not i.estornado and i.pagamento_id is null),0) as consumo_em_aberto
        from public.bar_mesas m where m.empresa_id = v_emp and m.status = 'ocupada'
       order by m.numero limit 60) x;
    return jsonb_build_object('foco', v_foco, 'mesas_total', t.total, 'mesas_ocupadas', t.ocupadas, 'pessoas_no_bar', t.pessoas,
      'consumo_total_em_aberto', (select coalesce(sum((e->>'consumo_em_aberto')::numeric),0) from jsonb_array_elements(v_itens) e),
      'mesas', v_itens);

  elsif v_foco = 'periodo' then
    select count(*) as comandas, coalesce(sum(bp.total),0) as total, coalesce(sum(bp.pessoas_liberadas),0) as pessoas,
           coalesce(sum(bp.taxa_servico),0) as taxa, coalesce(sum(bp.desconto),0) as desconto, coalesce(sum(bp.acrescimo),0) as acrescimo into t
      from public.bar_pagamentos bp
     where bp.empresa_id = v_emp and not bp.estornado and bp.criado_em >= ts_i and bp.criado_em < ts_f;
    return jsonb_build_object('foco', v_foco, 'periodo', jsonb_build_object('inicio', p.o_ini, 'fim', p.o_fim),
      'pagamentos_registrados', t.comandas, 'total_recebido', t.total, 'pessoas_atendidas', t.pessoas,
      'ticket_medio_por_pagamento', case when t.comandas > 0 then round(t.total / t.comandas, 2) end,
      'ticket_medio_por_pessoa', case when t.pessoas > 0 then round(t.total / t.pessoas, 2) end,
      'taxa_servico_total', t.taxa, 'descontos_total', t.desconto, 'acrescimos_total', t.acrescimo);

  elsif v_foco = 'produtos' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
      select pr.nome as produto, sum(i.quantidade) as quantidade, sum(i.quantidade * i.preco_unitario) as valor,
             max(i.destino_operacional) as destino
        from public.bar_pedidos_itens i join public.produtos pr on pr.id = i.produto_id and pr.empresa_id = i.empresa_id
       where i.empresa_id = v_emp and not i.estornado and i.criado_em >= ts_i and i.criado_em < ts_f
       group by pr.nome order by sum(i.quantidade * i.preco_unitario) desc, pr.nome limit v_lim) x;
    return jsonb_build_object('foco', v_foco, 'periodo', jsonb_build_object('inicio', p.o_ini, 'fim', p.o_fim), 'produtos', v_itens);

  elsif v_foco = 'horarios' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.hora), '[]'::jsonb) into v_itens from (
      select extract(hour from bp.criado_em at time zone 'America/Sao_Paulo')::int as hora, count(*) as pagamentos,
             sum(bp.total) as total, sum(bp.pessoas_liberadas) as pessoas
        from public.bar_pagamentos bp
       where bp.empresa_id = v_emp and not bp.estornado and bp.criado_em >= ts_i and bp.criado_em < ts_f group by 1) x;
    return jsonb_build_object('foco', v_foco, 'periodo', jsonb_build_object('inicio', p.o_ini, 'fim', p.o_fim), 'por_hora', v_itens);

  elsif v_foco = 'pagamentos' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
      select f.forma_pagamento, sum(f.valor) as total, count(*) as quantidade
        from public.bar_pagamentos_formas f join public.bar_pagamentos bp on bp.id = f.pagamento_id and bp.empresa_id = f.empresa_id
       where f.empresa_id = v_emp and not bp.estornado and bp.criado_em >= ts_i and bp.criado_em < ts_f
       group by f.forma_pagamento order by sum(f.valor) desc) x;
    return jsonb_build_object('foco', v_foco, 'periodo', jsonb_build_object('inicio', p.o_ini, 'fim', p.o_fim), 'formas_de_pagamento', v_itens);

  else -- destino (cozinha x bar)
    select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
      select i.destino_operacional as destino, count(*) as itens, sum(i.quantidade * i.preco_unitario) as valor,
             coalesce(sum(i.quantidade * i.preco_unitario) filter (where i.pagamento_id is null),0) as ainda_em_aberto
        from public.bar_pedidos_itens i
       where i.empresa_id = v_emp and not i.estornado and i.criado_em >= ts_i and i.criado_em < ts_f
       group by i.destino_operacional order by 3 desc) x;
    return jsonb_build_object('foco', v_foco, 'periodo', jsonb_build_object('inicio', p.o_ini, 'fim', p.o_fim), 'por_destino', v_itens);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION public.maria_buscar_produto(p_busca text, p_limite integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_resultado jsonb;
  v_busca text;
  v_limite integer;
begin
  perform private.maria_exigir_acesso('maria_buscar_produto');
  v_empresa_id := private.empresa_id_ativa();

  if not (
    private.perm('produtos')
    or private.perm('estoque')
    or private.perm('pdv')
  ) then
    raise exception 'Usuário sem permissão para consultar produtos.';
  end if;

  v_busca := trim(coalesce(p_busca,''));

  if length(v_busca) < 2 then
    raise exception 'Informe pelo menos 2 caracteres para buscar.';
  end if;

  v_limite := greatest(1, least(coalesce(p_limite,10),50));

  select coalesce(
    jsonb_agg(to_jsonb(x)),
    '[]'::jsonb
  )
  into v_resultado
  from (
    select
      id,
      codigo,
      nome,
      gtin,
      unidade_comercial,
      preco_venda,
      quantidade_estoque,
      estoque_minimo,
      categoria,
      tipo_fiscal,
      ncm,
      cest
    from public.produtos
    where empresa_id = v_empresa_id
      and (
        nome ilike '%' || v_busca || '%'
        or codigo ilike '%' || v_busca || '%'
        or gtin ilike '%' || v_busca || '%'
      )
    order by
      case
        when gtin = v_busca then 0
        when codigo = v_busca then 1
        when lower(nome) = lower(v_busca) then 2
        else 3
      end,
      nome
    limit v_limite
  ) x;

  return v_resultado;
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_cliente_detalhe(p_cliente_id uuid DEFAULT NULL::uuid, p_busca text DEFAULT NULL::text, p_dias integer DEFAULT 365)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_dias integer := least(greatest(coalesce(p_dias,365),1),1095);
  v_id uuid; v_cand jsonb; c public.clientes%rowtype;
  v_ts timestamptz := now() - make_interval(days => least(greatest(coalesce(p_dias,365),1),1095));
  tot record; per record; v_top jsonb; v_ult jsonb; v_cr record; v_vend boolean;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  perform private.maria_exigir_acesso('maria_cliente_detalhe');
  perform private.maria_exigir(array['clientes','pdv','dashboard','financeiro','fiscal','relatorios']);
  select o_id, o_candidatos into v_id, v_cand from private.maria_resolver_cliente(v_emp, p_cliente_id, p_busca);
  if v_cand is not null then return jsonb_build_object('ambiguo', true, 'mensagem', 'Há mais de um cliente com esse nome. Pergunte ao usuário qual deles.', 'candidatos', v_cand); end if;
  if v_id is null then return jsonb_build_object('encontrado', false); end if;
  select * into c from public.clientes where id = v_id and empresa_id = v_emp;
  v_vend := private.perm('relatorios') and private.perm_alguma(array['pdv','dashboard','financeiro','fiscal','relatorios']);

  if not v_vend then
    return jsonb_build_object('encontrado', true, 'cliente', jsonb_build_object('id', c.id, 'nome', c.nome, 'telefone', c.telefone,
      'email', c.email, 'cidade', c.cidade, 'uf', c.uf, 'cliente_desde', c.criado_em),
      'observacao', 'O usuário não tem permissão para ver o histórico de compras.');
  end if;

  select count(*) as compras, coalesce(sum(total),0) as total, min(criado_em) as primeira, max(criado_em) as ultima into tot
    from public.vendas where empresa_id = v_emp and cliente_id = v_id and cancelada_em is null;
  select count(*) as compras, coalesce(sum(total),0) as total into per
    from public.vendas where empresa_id = v_emp and cliente_id = v_id and cancelada_em is null and criado_em >= v_ts;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_top from (
    select p.nome as produto, sum(i.quantidade) as quantidade, sum(i.subtotal) as valor
      from public.itens_venda i join public.vendas v on v.id = i.venda_id and v.empresa_id = i.empresa_id
      join public.produtos p on p.id = i.produto_id and p.empresa_id = i.empresa_id
     where v.empresa_id = v_emp and v.cliente_id = v_id and v.cancelada_em is null and v.criado_em >= v_ts
     group by p.nome order by sum(i.subtotal) desc nulls last limit 5) x;
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_ult from (
    select numero_venda, criado_em, total, forma_pagamento from public.vendas
     where empresa_id = v_emp and cliente_id = v_id and cancelada_em is null order by criado_em desc limit 5) x;

  select coalesce(sum(saldo_aberto),0) as aberto into v_cr from public.contas_receber
   where empresa_id = v_emp and cliente_id = v_id and status in ('aberto','parcialmente_pago') and cancelado_em is null;

  return jsonb_build_object('encontrado', true,
    'cliente', jsonb_build_object('id', c.id, 'nome', c.nome, 'telefone', c.telefone, 'email', c.email,
                                  'cidade', c.cidade, 'uf', c.uf, 'cliente_desde', c.criado_em),
    'historico_total', jsonb_build_object('compras', tot.compras, 'total_comprado', tot.total,
        'ticket_medio', case when tot.compras > 0 then round(tot.total / tot.compras, 2) end,
        'primeira_compra', tot.primeira, 'ultima_compra', tot.ultima,
        'dias_desde_ultima_compra', case when tot.ultima is not null then v_hoje - (tot.ultima at time zone 'America/Sao_Paulo')::date end),
    'periodo', jsonb_build_object('dias', v_dias, 'compras', per.compras, 'total', per.total,
        'ticket_medio', case when per.compras > 0 then round(per.total / per.compras, 2) end),
    'produtos_mais_comprados', v_top, 'ultimas_compras', v_ult,
    'contas_a_receber_em_aberto', v_cr.aberto);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_clientes_buscar(p_busca text, p_limite integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_pad text := private.maria_like(p_busca);
  v_dig text := regexp_replace(coalesce(p_busca,''), '\D', '', 'g');
  v_lim integer := private.maria_lim(p_limite, 10, 25);
  v_vend boolean; v_itens jsonb; v_n integer;
begin
  perform private.maria_exigir_acesso('maria_clientes_buscar');
  perform private.maria_exigir(array['clientes','pdv','dashboard','financeiro','fiscal','relatorios']);
  if length(btrim(coalesce(p_busca,''))) < 2 then raise exception 'Informe pelo menos 2 caracteres para buscar o cliente.'; end if;
  v_vend := private.perm('relatorios') and private.perm_alguma(array['pdv','dashboard','financeiro','fiscal','relatorios']);

  select count(*) into v_n from public.clientes c
   where c.empresa_id = v_emp and (private.maria_norm(c.nome) like v_pad escape '\'
      or (length(v_dig) >= 4 and (regexp_replace(coalesce(c.telefone,''),'\D','','g') like '%'||v_dig||'%'
                                  or regexp_replace(coalesce(c.cpf,''),'\D','','g') = v_dig)));

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
    select c.id, c.nome, c.telefone, c.cidade,
           case when v_vend then s.compras end as compras,
           case when v_vend then s.total end as total_comprado,
           case when v_vend then s.ultima end as ultima_compra
      from public.clientes c
      left join lateral (select count(*) as compras, coalesce(sum(v.total),0) as total, max(v.criado_em) as ultima
                           from public.vendas v where v.empresa_id = c.empresa_id and v.cliente_id = c.id and v.cancelada_em is null) s on v_vend
     where c.empresa_id = v_emp and (private.maria_norm(c.nome) like v_pad escape '\'
        or (length(v_dig) >= 4 and (regexp_replace(coalesce(c.telefone,''),'\D','','g') like '%'||v_dig||'%'
                                    or regexp_replace(coalesce(c.cpf,''),'\D','','g') = v_dig)))
     order by c.nome, c.id limit v_lim) x;

  return jsonb_build_object('total_encontrados', v_n, 'exibindo', jsonb_array_length(v_itens),
                            'ambiguo', v_n > 1, 'clientes', v_itens);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_clientes_ranking(p_dias integer DEFAULT 90, p_limite integer DEFAULT 10, p_ordem text DEFAULT 'valor'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_dias integer := least(greatest(coalesce(p_dias,90),1),731);
  v_lim integer := private.maria_lim(p_limite, 10, 30);
  v_ord text := lower(btrim(coalesce(p_ordem,'valor')));
  v_ts timestamptz := now() - make_interval(days => least(greatest(coalesce(p_dias,90),1),731));
  v_itens jsonb; v_sem numeric;
begin
  perform private.maria_exigir_acesso('maria_clientes_ranking');
  perform private.maria_exigir(array['pdv','dashboard','financeiro','fiscal','relatorios']);
  perform private.maria_exigir(array['clientes','pdv','dashboard','financeiro','fiscal','relatorios']);
  if v_ord not in ('valor','compras','ticket') then raise exception 'Ordenação inválida (use valor, compras ou ticket).'; end if;
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
    select c.id, c.nome, count(*) as compras, sum(v.total) as total, round(sum(v.total) / count(*), 2) as ticket_medio,
           max(v.criado_em) as ultima_compra
      from public.vendas v join public.clientes c on c.id = v.cliente_id and c.empresa_id = v.empresa_id
     where v.empresa_id = v_emp and v.cancelada_em is null and v.criado_em >= v_ts
     group by c.id, c.nome
     order by case v_ord when 'valor' then sum(v.total) when 'compras' then count(*)::numeric else sum(v.total) / count(*) end desc, c.nome
     limit v_lim) x;
  select coalesce(sum(total),0) into v_sem from public.vendas
   where empresa_id = v_emp and cancelada_em is null and criado_em >= v_ts and cliente_id is null;
  return jsonb_build_object('dias', v_dias, 'ordenado_por', v_ord, 'clientes', v_itens,
                            'vendas_sem_cliente_identificado_total', v_sem);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_clientes_situacao(p_tipo text, p_dias integer DEFAULT 60, p_min_compras integer DEFAULT 2, p_limite integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_tipo text := lower(btrim(coalesce(p_tipo,'')));
  v_dias integer := least(greatest(coalesce(p_dias,60),1),1095);
  v_min integer := least(greatest(coalesce(p_min_compras,2),2),100);
  v_lim integer := private.maria_lim(p_limite, 20, 50);
  v_ts timestamptz := now() - make_interval(days => least(greatest(coalesce(p_dias,60),1),1095));
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_itens jsonb; v_n integer;
begin
  perform private.maria_exigir_acesso('maria_clientes_situacao');
  perform private.maria_exigir(array['clientes','pdv','dashboard','financeiro','fiscal','relatorios']);
  if v_tipo not in ('inativos','novos','recorrentes','sem_compra') then
    raise exception 'Tipo inválido (use inativos, novos, recorrentes ou sem_compra).';
  end if;
  if v_tipo <> 'novos' then
    perform private.maria_exigir(array['pdv','dashboard','financeiro','fiscal','relatorios']);
  end if;

  if v_tipo = 'novos' then
    select count(*) into v_n from public.clientes where empresa_id = v_emp and criado_em >= v_ts;
    select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
      select id, nome, telefone, cidade, criado_em as cadastrado_em from public.clientes
       where empresa_id = v_emp and criado_em >= v_ts order by criado_em desc limit v_lim) x;
  elsif v_tipo = 'inativos' then
    with u as (select v.cliente_id, max(v.criado_em) as ultima, count(*) as compras, sum(v.total) as total
                 from public.vendas v where v.empresa_id = v_emp and v.cancelada_em is null and v.cliente_id is not null
                group by v.cliente_id having max(v.criado_em) < v_ts)
    select (select count(*) from u),
           coalesce((select jsonb_agg(to_jsonb(x)) from (
              select c.id, c.nome, c.telefone, u.compras, u.total as total_comprado, u.ultima as ultima_compra,
                     v_hoje - (u.ultima at time zone 'America/Sao_Paulo')::date as dias_sem_comprar
                from u join public.clientes c on c.id = u.cliente_id and c.empresa_id = v_emp
               order by u.total desc, c.nome limit v_lim) x), '[]'::jsonb)
      into v_n, v_itens;
  elsif v_tipo = 'recorrentes' then
    with u as (select v.cliente_id, count(*) as compras, sum(v.total) as total, max(v.criado_em) as ultima
                 from public.vendas v where v.empresa_id = v_emp and v.cancelada_em is null and v.cliente_id is not null and v.criado_em >= v_ts
                group by v.cliente_id having count(*) >= v_min)
    select (select count(*) from u),
           coalesce((select jsonb_agg(to_jsonb(x)) from (
              select c.id, c.nome, u.compras, u.total, round(u.total / u.compras, 2) as ticket_medio, u.ultima as ultima_compra
                from u join public.clientes c on c.id = u.cliente_id and c.empresa_id = v_emp
               order by u.compras desc, u.total desc limit v_lim) x), '[]'::jsonb)
      into v_n, v_itens;
  else -- sem_compra
    select count(*) into v_n from public.clientes c where c.empresa_id = v_emp
       and not exists (select 1 from public.vendas v where v.empresa_id = c.empresa_id and v.cliente_id = c.id and v.cancelada_em is null);
    select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
      select c.id, c.nome, c.telefone, c.criado_em as cadastrado_em from public.clientes c
       where c.empresa_id = v_emp
         and not exists (select 1 from public.vendas v where v.empresa_id = c.empresa_id and v.cliente_id = c.id and v.cancelada_em is null)
       order by c.criado_em desc limit v_lim) x;
  end if;
  return jsonb_build_object('tipo', v_tipo, 'dias', v_dias, 'total', v_n, 'exibindo', jsonb_array_length(v_itens), 'clientes', v_itens);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_comparar_clientes(p_clientes text[], p_dias integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_dias integer := least(greatest(coalesce(p_dias,90),1),731);
  v_ts timestamptz := now() - make_interval(days => least(greatest(coalesce(p_dias,90),1),731));
  v_nome text; v_id uuid; v_cand jsonb; v_res jsonb := '[]'::jsonb; s record; v_n integer := 0;
begin
  perform private.maria_exigir_acesso('maria_comparar_clientes');
  perform private.maria_exigir(array['pdv','dashboard','financeiro','fiscal','relatorios']);
  perform private.maria_exigir(array['clientes','pdv','dashboard','financeiro','fiscal','relatorios']);
  if p_clientes is null or array_length(p_clientes,1) is null then raise exception 'Informe os clientes a comparar.'; end if;
  if array_length(p_clientes,1) > 5 then raise exception 'Compare no máximo 5 clientes por vez.'; end if;
  foreach v_nome in array p_clientes loop
    v_n := v_n + 1;
    select o_id, o_candidatos into v_id, v_cand from private.maria_resolver_cliente(v_emp, null, left(v_nome, 120));
    if v_cand is not null then
      v_res := v_res || jsonb_build_array(jsonb_build_object('pesquisado', left(v_nome,120), 'ambiguo', true, 'candidatos', v_cand));
    elsif v_id is null then
      v_res := v_res || jsonb_build_array(jsonb_build_object('pesquisado', left(v_nome,120), 'encontrado', false));
    else
      select c.nome, count(v.id) as compras, coalesce(sum(v.total),0) as total, max(v.criado_em) as ultima into s
        from public.clientes c left join public.vendas v on v.empresa_id = c.empresa_id and v.cliente_id = c.id
             and v.cancelada_em is null and v.criado_em >= v_ts
       where c.id = v_id and c.empresa_id = v_emp group by c.nome;
      v_res := v_res || jsonb_build_array(jsonb_build_object('pesquisado', left(v_nome,120), 'encontrado', true, 'id', v_id,
          'nome', s.nome, 'compras', s.compras, 'total', s.total,
          'ticket_medio', case when s.compras > 0 then round(s.total / s.compras, 2) end, 'ultima_compra', s.ultima));
    end if;
  end loop;
  return jsonb_build_object('dias', v_dias, 'clientes', v_res);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_comparar_periodos(p_a_inicio date DEFAULT NULL::date, p_a_fim date DEFAULT NULL::date, p_b_inicio date DEFAULT NULL::date, p_b_fim date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  a_ini date; a_fim date; b_ini date; b_fim date;
  va record; vb record; da numeric; db numeric;
begin
  perform private.maria_exigir_acesso('maria_comparar_periodos');
  perform private.maria_exigir(array['financeiro','relatorios']);
  if p_a_inicio is null and p_a_fim is null then
    a_ini := date_trunc('month', v_hoje)::date; a_fim := v_hoje;
  else select o_ini, o_fim into a_ini, a_fim from private.maria_periodo(p_a_inicio, p_a_fim); end if;
  if p_b_inicio is null and p_b_fim is null then
    -- mesmo recorte de dias do mês anterior (comparação justa)
    b_ini := (date_trunc('month', a_ini) - interval '1 month')::date;
    b_fim := least(b_ini + (a_fim - a_ini), (date_trunc('month', a_ini) - interval '1 day')::date);
  else select o_ini, o_fim into b_ini, b_fim from private.maria_periodo(p_b_inicio, p_b_fim); end if;

  select coalesce(sum(v.total),0) as total, count(*) as qtd into va from public.vendas v
   where v.empresa_id = v_emp and v.cancelada_em is null
     and v.criado_em >= a_ini::timestamp at time zone 'America/Sao_Paulo'
     and v.criado_em <  (a_fim + 1)::timestamp at time zone 'America/Sao_Paulo';
  select coalesce(sum(v.total),0) as total, count(*) as qtd into vb from public.vendas v
   where v.empresa_id = v_emp and v.cancelada_em is null
     and v.criado_em >= b_ini::timestamp at time zone 'America/Sao_Paulo'
     and v.criado_em <  (b_fim + 1)::timestamp at time zone 'America/Sao_Paulo';
  select coalesce(sum(valor),0) into da from public.despesas where empresa_id = v_emp and data between a_ini and a_fim;
  select coalesce(sum(valor),0) into db from public.despesas where empresa_id = v_emp and data between b_ini and b_fim;

  return jsonb_build_object(
    'periodo_a', jsonb_build_object('inicio', a_ini, 'fim', a_fim, 'vendas', va.total, 'quantidade_vendas', va.qtd,
        'despesas_cadastradas', da, 'resultado_operacional', va.total - da),
    'periodo_b', jsonb_build_object('inicio', b_ini, 'fim', b_fim, 'vendas', vb.total, 'quantidade_vendas', vb.qtd,
        'despesas_cadastradas', db, 'resultado_operacional', vb.total - db),
    'variacao_percentual_a_sobre_b', jsonb_build_object(
        'vendas', case when vb.total > 0 then round((va.total - vb.total) / vb.total * 100, 1) end,
        'despesas', case when db > 0 then round((da - db) / db * 100, 1) end,
        'resultado_operacional', case when (vb.total - db) <> 0 then round(((va.total - da) - (vb.total - db)) / abs(vb.total - db) * 100, 1) end),
    'observacao', 'Resultado operacional = vendas - despesas cadastradas; não é lucro líquido.');
end $function$;

CREATE OR REPLACE FUNCTION public.maria_comparar_produtos(p_produtos text[], p_dias integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_resultado jsonb;
begin
  perform private.maria_exigir_acesso('maria_comparar_produtos');
  v_empresa_id := private.empresa_id_ativa();

  if not private.perm('pdv') then
    raise exception 'Sem permissão para consultar vendas';
  end if;

  if p_produtos is null
     or coalesce(array_length(p_produtos, 1), 0) = 0 then
    raise exception 'Informe pelo menos um produto';
  end if;

  if array_length(p_produtos, 1) > 20 then
    raise exception 'Máximo de 20 produtos por comparação';
  end if;

  p_dias := greatest(1, least(coalesce(p_dias, 30), 3650));

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into v_resultado
  from (
    select
      p.id as produto_id,
      p.nome as produto,
      coalesce(sum(iv.quantidade), 0) as quantidade_vendida,
      coalesce(sum(iv.subtotal), 0) as valor_vendido,
      count(distinct v.id) as vendas
    from public.produtos p
    left join public.itens_venda iv
      on iv.produto_id = p.id
     and iv.empresa_id = v_empresa_id
    left join public.vendas v
      on v.id = iv.venda_id
     and v.empresa_id = v_empresa_id
     and v.criado_em >= now() - make_interval(days => p_dias)
    where p.empresa_id = v_empresa_id
      and exists (
        select 1
        from unnest(p_produtos) termo
        where p.nome ilike '%' || trim(termo) || '%'
      )
    group by p.id, p.nome
    order by quantidade_vendida desc, valor_vendido desc
  ) x;

  return jsonb_build_object(
    'periodo_dias', p_dias,
    'produtos_pesquisados', to_jsonb(p_produtos),
    'resultados', v_resultado
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_contas_pagar(p_dias_a_frente integer DEFAULT 30, p_limite integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_dias integer := least(greatest(coalesce(p_dias_a_frente,30),1),365);
  v_lim integer := private.maria_lim(p_limite, 20, 50);
  v_venc jsonb; v_prox jsonb; t record;
begin
  perform private.maria_exigir_acesso('maria_contas_pagar');
  perform private.maria_exigir(array['financeiro','relatorios']);
  select coalesce(sum(valor) filter (where vencimento < v_hoje),0) as venc_total,
         count(*) filter (where vencimento < v_hoje) as venc_qtd,
         coalesce(sum(valor) filter (where vencimento between v_hoje and v_hoje + v_dias),0) as prox_total,
         count(*) filter (where vencimento between v_hoje and v_hoje + v_dias) as prox_qtd,
         count(*) filter (where vencimento is null) as sem_venc_qtd,
         coalesce(sum(valor) filter (where vencimento is null),0) as sem_venc_total into t
    from public.despesas where empresa_id = v_emp and status <> 'pago';

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_venc from (
    select d.id, d.descricao, d.categoria, d.valor, d.vencimento, v_hoje - d.vencimento as dias_em_atraso,
           coalesce(fo.nome_fantasia, fo.razao_social) as fornecedor
      from public.despesas d left join public.fornecedores fo on fo.id = d.fornecedor_id and fo.empresa_id = d.empresa_id
     where d.empresa_id = v_emp and d.status <> 'pago' and d.vencimento < v_hoje
     order by d.vencimento asc, d.id limit v_lim) x;
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_prox from (
    select d.id, d.descricao, d.categoria, d.valor, d.vencimento, d.vencimento - v_hoje as dias_para_vencer,
           coalesce(fo.nome_fantasia, fo.razao_social) as fornecedor
      from public.despesas d left join public.fornecedores fo on fo.id = d.fornecedor_id and fo.empresa_id = d.empresa_id
     where d.empresa_id = v_emp and d.status <> 'pago' and d.vencimento between v_hoje and v_hoje + v_dias
     order by d.vencimento asc, d.id limit v_lim) x;

  return jsonb_build_object('hoje', v_hoje, 'janela_dias', v_dias,
    'vencidas', jsonb_build_object('total', t.venc_total, 'quantidade', t.venc_qtd, 'itens', v_venc),
    'a_vencer', jsonb_build_object('total', t.prox_total, 'quantidade', t.prox_qtd, 'itens', v_prox),
    'pendentes_sem_vencimento', jsonb_build_object('total', t.sem_venc_total, 'quantidade', t.sem_venc_qtd));
end $function$;

CREATE OR REPLACE FUNCTION public.maria_despesas_agrupadas(p_inicio date DEFAULT NULL::date, p_fim date DEFAULT NULL::date, p_agrupar text DEFAULT 'categoria'::text, p_limite integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  p record; v_ag text := lower(btrim(coalesce(p_agrupar,'categoria'))); v_lim integer := private.maria_lim(p_limite, 10, 30);
  v_tot numeric; v_grupos jsonb;
begin
  perform private.maria_exigir_acesso('maria_despesas_agrupadas');
  perform private.maria_exigir(array['financeiro','relatorios']);
  if v_ag not in ('categoria','fornecedor','mes') then raise exception 'Agrupamento inválido (use categoria, fornecedor ou mes).'; end if;
  select * into p from private.maria_periodo(p_inicio, p_fim);
  select coalesce(sum(valor),0) into v_tot from public.despesas where empresa_id = v_emp and data between p.o_ini and p.o_fim;

  select coalesce(jsonb_agg(to_jsonb(g) order by g.total desc), '[]'::jsonb) into v_grupos from (
    select case v_ag when 'categoria' then coalesce(nullif(btrim(d.categoria),''), 'Sem categoria')
                     when 'fornecedor' then coalesce(fo.nome_fantasia, fo.razao_social, 'Sem fornecedor')
                     else to_char(d.data, 'YYYY-MM') end as grupo,
           sum(d.valor) as total, count(*) as quantidade,
           sum(d.valor) filter (where d.status <> 'pago') as pendente,
           case when v_tot > 0 then round(sum(d.valor) / v_tot * 100, 1) end as percentual
      from public.despesas d
      left join public.fornecedores fo on fo.id = d.fornecedor_id and fo.empresa_id = d.empresa_id
     where d.empresa_id = v_emp and d.data between p.o_ini and p.o_fim
     group by 1 order by sum(d.valor) desc limit v_lim) g;

  return jsonb_build_object('periodo', jsonb_build_object('inicio', p.o_ini, 'fim', p.o_fim),
                            'agrupado_por', v_ag, 'total_despesas', v_tot, 'grupos', v_grupos);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_despesas_listar(p_status text DEFAULT NULL::text, p_inicio date DEFAULT NULL::date, p_fim date DEFAULT NULL::date, p_base_data text DEFAULT 'data'::text, p_categoria text DEFAULT NULL::text, p_busca text DEFAULT NULL::text, p_limite integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ini date; v_fim date; v_lim integer := private.maria_lim(p_limite, 20, 50);
  v_st text := lower(btrim(coalesce(p_status,'')));
  v_base text := lower(btrim(coalesce(p_base_data,'data')));
  v_cat text := nullif(private.maria_like(p_categoria), '%%');
  v_bus text := nullif(private.maria_like(p_busca), '%%');
  v_tot numeric; v_qtd integer; v_itens jsonb; v_sem_datas boolean;
begin
  perform private.maria_exigir_acesso('maria_despesas_listar');
  perform private.maria_exigir(array['financeiro','relatorios']);
  if v_st not in ('','pendente','pago','vencida') then raise exception 'Situação inválida (use pendente, pago ou vencida).'; end if;
  if v_base not in ('data','vencimento') then raise exception 'Base de data inválida.'; end if;
  v_sem_datas := p_inicio is null and p_fim is null and v_st in ('pendente','vencida');
  if not v_sem_datas then
    select o_ini, o_fim into v_ini, v_fim from private.maria_periodo(p_inicio, p_fim);
  end if;

  with f as (
    select d.*, coalesce(fo.nome_fantasia, fo.razao_social) as fornecedor
      from public.despesas d
      left join public.fornecedores fo on fo.id = d.fornecedor_id and fo.empresa_id = d.empresa_id
     where d.empresa_id = v_emp
       and (v_st = '' or (v_st = 'pago' and d.status = 'pago') or (v_st = 'pendente' and d.status <> 'pago')
            or (v_st = 'vencida' and d.status <> 'pago' and d.vencimento < v_hoje))
       and (v_sem_datas or (case when v_base = 'vencimento' then d.vencimento else d.data end) between v_ini and v_fim)
       and (v_cat is null or private.maria_norm(d.categoria) like v_cat escape '\')
       and (v_bus is null or private.maria_norm(d.descricao) like v_bus escape '\'
            or private.maria_norm(coalesce(fo.nome_fantasia, fo.razao_social)) like v_bus escape '\')
  )
  select coalesce(sum(valor),0), count(*),
         coalesce((select jsonb_agg(to_jsonb(x)) from (
            select id, descricao, categoria, valor, data, vencimento, status, pago_em, fornecedor,
                   case when status <> 'pago' and vencimento < v_hoje then v_hoje - vencimento end as dias_em_atraso
              from f order by case when v_st in ('pendente','vencida') then vencimento end asc nulls last, data desc, id
             limit v_lim) x), '[]'::jsonb)
    into v_tot, v_qtd, v_itens from f;

  return jsonb_build_object('filtro', jsonb_build_object('situacao', nullif(v_st,''), 'base_data', v_base,
                              'inicio', v_ini, 'fim', v_fim),
                            'total_valor', v_tot, 'quantidade', v_qtd, 'exibindo', least(v_qtd, v_lim), 'despesas', v_itens);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_estoque_analise(p_foco text, p_dias integer DEFAULT 30, p_limite integer DEFAULT 15, p_cobertura_dias integer DEFAULT 15)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_foco text := lower(btrim(coalesce(p_foco,'')));
  v_dias integer := least(greatest(coalesce(p_dias,30),1),365);
  v_lim integer := private.maria_lim(p_limite, 15, 40);
  v_cob integer := least(greatest(coalesce(p_cobertura_dias,15),1),180);
  v_ts timestamptz := now() - make_interval(days => least(greatest(coalesce(p_dias,30),1),365));
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_itens jsonb; v_total integer; v_extra jsonb := '{}'::jsonb; t record;
begin
  perform private.maria_exigir_acesso('maria_estoque_analise', p_foco);
  perform private.maria_exigir(array['produtos','estoque','notas_entrada','fiscal','dashboard','relatorios','bar_pedidos']);
  if v_foco = 'encalhados' then v_foco := 'sem_venda'; end if;
  if v_foco not in ('abaixo_minimo','excesso','sem_venda','giro_alto','giro_baixo','reposicao','promocao','valor_estoque','margem','lucro_bruto') then
    raise exception 'Foco inválido para análise de estoque.';
  end if;
  if v_foco not in ('abaixo_minimo','valor_estoque','margem') then
    perform private.maria_exigir(array['pdv','dashboard','financeiro','fiscal','relatorios']);
  end if;

  if v_foco = 'abaixo_minimo' then
    select coalesce(jsonb_agg(to_jsonb(x) - 'tg'), '[]'), coalesce(max(tg),0) into v_itens, v_total from (
      select b.id, b.nome, b.codigo, b.estoque, b.minimo, b.minimo - b.estoque as falta, count(*) over() as tg
        from private.maria_base_estoque(v_emp, v_ts) b
       where b.minimo is not null and b.minimo > 0 and b.estoque < b.minimo
       order by (b.estoque / b.minimo) asc, b.nome limit v_lim) x;

  elsif v_foco = 'excesso' then
    select coalesce(jsonb_agg(to_jsonb(x) - 'tg'), '[]'), coalesce(max(tg),0) into v_itens, v_total from (
      select b.id, b.nome, b.codigo, b.estoque, b.vendido as vendido_no_periodo,
             round(b.estoque / (b.vendido / v_dias), 0) as cobertura_dias,
             round(b.estoque * coalesce(b.custo, b.preco), 2) as valor_parado, count(*) over() as tg
        from private.maria_base_estoque(v_emp, v_ts) b
       where b.estoque > 0 and b.vendido > 0 and b.estoque / (b.vendido / v_dias) > 90
       order by b.estoque * coalesce(b.custo, b.preco) desc, b.nome limit v_lim) x;
    v_extra := jsonb_build_object('criterio', 'estoque que cobre mais de 90 dias no ritmo de venda do período');

  elsif v_foco in ('sem_venda','promocao') then
    select coalesce(jsonb_agg(to_jsonb(x) - 'tg'), '[]'), coalesce(max(tg),0) into v_itens, v_total from (
      select f.*, (select max(v.criado_em) from public.itens_venda i join public.vendas v on v.id = i.venda_id and v.empresa_id = i.empresa_id
                    where i.produto_id = f.id and v.empresa_id = v_emp and v.cancelada_em is null) as ultima_venda
      from (select b.id, b.nome, b.codigo, b.estoque, b.preco as preco_venda,
                   round(b.estoque * coalesce(b.custo, b.preco), 2) as valor_parado,
                   case when b.custo > 0 and b.preco > 0 then round((b.preco - b.custo) / b.preco * 100, 1) end as margem_percentual,
                   case when b.vendido = 0 then 'sem venda no período' else 'estoque acima de 90 dias de venda' end as motivo,
                   count(*) over() as tg
              from private.maria_base_estoque(v_emp, v_ts) b
             where b.estoque > 0 and (b.vendido = 0 or (v_foco = 'promocao' and b.estoque / (b.vendido / v_dias) > 90))
             order by b.estoque * coalesce(b.custo, b.preco) desc, b.nome limit v_lim) f) x;
    -- dias sem vender (calculado depois da ordenação)
    select coalesce(jsonb_agg(e || jsonb_build_object('dias_sem_vender',
             case when (e->>'ultima_venda') is not null then v_hoje - ((e->>'ultima_venda')::timestamptz at time zone 'America/Sao_Paulo')::date end)), '[]')
      into v_itens from jsonb_array_elements(v_itens) e;

  elsif v_foco = 'giro_alto' then
    select coalesce(jsonb_agg(to_jsonb(x) - 'tg'), '[]'), coalesce(max(tg),0) into v_itens, v_total from (
      select b.id, b.nome, b.estoque, b.vendido as vendido_no_periodo, b.receita,
             round(b.vendido / greatest(b.estoque, 1), 2) as giro,
             case when b.vendido > 0 then round(b.estoque / (b.vendido / v_dias), 0) end as cobertura_dias, count(*) over() as tg
        from private.maria_base_estoque(v_emp, v_ts) b where b.vendido > 0
       order by b.vendido / greatest(b.estoque, 1) desc, b.nome limit v_lim) x;

  elsif v_foco = 'giro_baixo' then
    select coalesce(jsonb_agg(to_jsonb(x) - 'tg'), '[]'), coalesce(max(tg),0) into v_itens, v_total from (
      select b.id, b.nome, b.estoque, b.vendido as vendido_no_periodo,
             round(b.vendido / b.estoque, 3) as giro, round(b.estoque / (b.vendido / v_dias), 0) as cobertura_dias, count(*) over() as tg
        from private.maria_base_estoque(v_emp, v_ts) b where b.vendido > 0 and b.estoque > 0
       order by b.vendido / b.estoque asc, b.nome limit v_lim) x;

  elsif v_foco = 'reposicao' then
    select coalesce(jsonb_agg(to_jsonb(x) - 'tg'), '[]'), coalesce(max(tg),0) into v_itens, v_total from (
      select b.id, b.nome, b.codigo, b.estoque, b.minimo, b.vendido as vendido_no_periodo,
             case when b.vendido > 0 then round(b.estoque / (b.vendido / v_dias), 1) end as cobertura_dias,
             greatest(ceil(b.vendido / v_dias * v_cob) - b.estoque,
                      case when b.minimo > 0 then b.minimo - b.estoque else 0 end, 0) as quantidade_sugerida,
             count(*) over() as tg
        from private.maria_base_estoque(v_emp, v_ts) b
       where (b.vendido > 0 and b.estoque / (b.vendido / v_dias) < v_cob) or (b.minimo > 0 and b.estoque < b.minimo)
       order by case when b.vendido > 0 then b.estoque / (b.vendido / v_dias) else 0 end asc, b.nome limit v_lim) x;
    v_extra := jsonb_build_object('cobertura_alvo_dias', v_cob);

  elsif v_foco = 'valor_estoque' then
    select coalesce(sum(b.estoque * b.custo) filter (where b.custo is not null and b.estoque > 0),0) as custo_total,
           coalesce(sum(b.estoque * b.preco) filter (where b.estoque > 0),0) as venda_total,
           count(*) filter (where b.estoque > 0) as com_estoque,
           count(*) filter (where b.estoque > 0 and (b.custo is null or b.custo = 0)) as sem_custo into t
      from private.maria_base_estoque(v_emp, v_ts) b;
    v_extra := jsonb_build_object('valor_a_custo', t.custo_total, 'valor_a_preco_de_venda', t.venda_total,
                                  'produtos_com_estoque', t.com_estoque, 'produtos_sem_custo_cadastrado', t.sem_custo,
                                  'observacao', 'Valor a custo considera só produtos com preço de custo cadastrado.');
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v_itens from (
      select b.id, b.nome, b.estoque, round(b.estoque * b.custo, 2) as valor_a_custo
        from private.maria_base_estoque(v_emp, v_ts) b where b.estoque > 0 and b.custo > 0
       order by b.estoque * b.custo desc limit v_lim) x;
    v_total := t.com_estoque;

  elsif v_foco = 'margem' then
    select count(*) filter (where b.custo > 0 and b.preco > 0) into v_total
      from private.maria_base_estoque(v_emp, v_ts) b;
    return jsonb_build_object('foco', v_foco, 'produtos_com_custo', v_total,
      'produtos_sem_custo_cadastrado', (select count(*) from private.maria_base_estoque(v_emp, v_ts) b where b.custo is null or b.custo = 0),
      'maiores_margens', coalesce((select jsonb_agg(to_jsonb(x)) from (
          select b.id, b.nome, b.preco as preco_venda, b.custo as preco_custo, round((b.preco - b.custo) / b.preco * 100, 1) as margem_percentual
            from private.maria_base_estoque(v_emp, v_ts) b where b.custo > 0 and b.preco > 0
           order by (b.preco - b.custo) / b.preco desc, b.nome limit v_lim) x), '[]'),
      'menores_margens', coalesce((select jsonb_agg(to_jsonb(x)) from (
          select b.id, b.nome, b.preco as preco_venda, b.custo as preco_custo, round((b.preco - b.custo) / b.preco * 100, 1) as margem_percentual
            from private.maria_base_estoque(v_emp, v_ts) b where b.custo > 0 and b.preco > 0
           order by (b.preco - b.custo) / b.preco asc, b.nome limit v_lim) x), '[]'),
      'observacao', 'Margem calculada só para produtos com preço de custo cadastrado.');

  else -- lucro_bruto
    select coalesce(jsonb_agg(to_jsonb(x) - 'tg'), '[]'), coalesce(max(tg),0) into v_itens, v_total from (
      select b.id, b.nome, b.vendido as vendido_no_periodo, b.receita,
             round(b.receita - b.vendido * b.custo, 2) as lucro_bruto_estimado,
             case when b.receita > 0 then round((b.receita - b.vendido * b.custo) / b.receita * 100, 1) end as margem_percentual,
             count(*) over() as tg
        from private.maria_base_estoque(v_emp, v_ts) b where b.vendido > 0 and b.custo > 0
       order by b.receita - b.vendido * b.custo desc, b.nome limit v_lim) x;
    v_extra := jsonb_build_object('observacao', 'Lucro bruto estimado = receita - quantidade x preço de custo ATUAL; só produtos com custo cadastrado.');
  end if;

  return jsonb_build_object('foco', v_foco, 'dias', v_dias, 'total_encontrado', v_total,
                            'exibindo', jsonb_array_length(v_itens), 'itens', v_itens) || v_extra;
end $function$;

CREATE OR REPLACE FUNCTION public.maria_estoque_baixo(p_limite integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_resultado jsonb;
  v_limite integer;
begin
  perform private.maria_exigir_acesso('maria_estoque_baixo');
  v_empresa_id := private.empresa_id_ativa();

  if not (
    private.perm('estoque')
    or private.perm('produtos')
  ) then
    raise exception 'Usuário sem permissão para consultar estoque.';
  end if;

  v_limite := greatest(1, least(coalesce(p_limite,20),100));

  select coalesce(
    jsonb_agg(to_jsonb(x) order by x.quantidade_estoque asc),
    '[]'::jsonb
  )
  into v_resultado
  from (
    select
      id,
      nome,
      codigo,
      gtin,
      quantidade_estoque,
      estoque_minimo,
      unidade_comercial
    from public.produtos
    where empresa_id = v_empresa_id
      and estoque_minimo is not null
      and quantidade_estoque <= estoque_minimo
    order by quantidade_estoque asc, nome
    limit v_limite
  ) x;

  return v_resultado;
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_estoque_zerado(p_limite integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_resultado jsonb;
  v_limite integer;
begin
  perform private.maria_exigir_acesso('maria_estoque_zerado');
  v_empresa_id := private.empresa_id_ativa();

  if not (
    private.perm('estoque')
    or private.perm('produtos')
  ) then
    raise exception 'Usuário sem permissão para consultar estoque.';
  end if;

  v_limite := greatest(1, least(coalesce(p_limite,20),100));

  select coalesce(
    jsonb_agg(to_jsonb(x) order by x.nome),
    '[]'::jsonb
  )
  into v_resultado
  from (
    select
      id,
      nome,
      codigo,
      gtin,
      quantidade_estoque,
      estoque_minimo,
      unidade_comercial
    from public.produtos
    where empresa_id = v_empresa_id
      and quantidade_estoque <= 0
    order by nome
    limit v_limite
  ) x;

  return v_resultado;
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_financeiro_resumo(p_inicio date DEFAULT NULL::date, p_fim date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  p record; ts_i timestamptz; ts_f timestamptz;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  vend record; desp record; cp record; cr record;
begin
  perform private.maria_exigir_acesso('maria_financeiro_resumo');
  perform private.maria_exigir(array['financeiro','relatorios']);
  select * into p from private.maria_periodo(p_inicio, p_fim);
  ts_i := p.o_ini::timestamp at time zone 'America/Sao_Paulo';
  ts_f := (p.o_fim + 1)::timestamp at time zone 'America/Sao_Paulo';

  select coalesce(sum(v.total),0) as total, count(*) as qtd into vend
    from public.vendas v
   where v.empresa_id = v_emp and v.cancelada_em is null and v.criado_em >= ts_i and v.criado_em < ts_f;

  select coalesce(sum(d.valor),0) as total,
         coalesce(sum(d.valor) filter (where d.status = 'pago'),0) as pagas,
         coalesce(sum(d.valor) filter (where d.status <> 'pago'),0) as pendentes,
         count(*) as qtd into desp
    from public.despesas d
   where d.empresa_id = v_emp and d.data between p.o_ini and p.o_fim;

  select coalesce(sum(d.valor),0) as aberto,
         coalesce(sum(d.valor) filter (where d.vencimento < v_hoje),0) as vencidas_total,
         count(*) filter (where d.vencimento < v_hoje) as vencidas_qtd,
         coalesce(sum(d.valor) filter (where d.vencimento between v_hoje and v_hoje + 7),0) as prox7 into cp
    from public.despesas d
   where d.empresa_id = v_emp and d.status <> 'pago';

  select coalesce(sum(c.saldo_aberto),0) as aberto,
         coalesce(sum(c.saldo_aberto) filter (where c.vencimento < v_hoje),0) as vencido into cr
    from public.contas_receber c
   where c.empresa_id = v_emp and c.status in ('aberto','parcialmente_pago') and c.cancelado_em is null;

  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p.o_ini, 'fim', p.o_fim),
    'vendas', jsonb_build_object('total', vend.total, 'quantidade', vend.qtd,
                                 'ticket_medio', case when vend.qtd > 0 then round(vend.total / vend.qtd, 2) else 0 end),
    'despesas_cadastradas', jsonb_build_object('total', desp.total, 'pagas', desp.pagas, 'pendentes', desp.pendentes, 'quantidade', desp.qtd),
    'resultado_operacional', vend.total - desp.total,
    'observacao', 'Resultado operacional considerando as despesas cadastradas no período (data da despesa). Não é lucro líquido: não inclui custo das mercadorias nem despesas não cadastradas.',
    'contas_a_pagar', jsonb_build_object('em_aberto_total', cp.aberto, 'vencidas_total', cp.vencidas_total,
                                         'vencidas_quantidade', cp.vencidas_qtd, 'vence_em_7_dias', cp.prox7),
    'contas_a_receber', jsonb_build_object('em_aberto_total', cr.aberto, 'vencido_total', cr.vencido)
  );
end $function$;

CREATE OR REPLACE FUNCTION public.maria_formas_pagamento_mes()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_resultado jsonb;
  v_inicio timestamptz;
  v_fim timestamptz;
begin
  perform private.maria_exigir_acesso('maria_formas_pagamento_mes');
  v_empresa_id := private.empresa_id_ativa();

  if not private.perm('pdv') then
    raise exception 'Usuário sem permissão para consultar vendas.';
  end if;

  v_inicio :=
    date_trunc('month', now() at time zone 'America/Sao_Paulo')
    at time zone 'America/Sao_Paulo';

  v_fim := v_inicio + interval '1 month';

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'forma_pagamento', forma_pagamento,
        'quantidade_vendas', quantidade,
        'total', round(total,2)
      )
      order by total desc
    ),
    '[]'::jsonb
  )
  into v_resultado
  from (
    select
      forma_pagamento,
      count(*) as quantidade,
      sum(total) as total
    from public.vendas
    where empresa_id = v_empresa_id
      and criado_em >= v_inicio
      and criado_em < v_fim
    group by forma_pagamento
  ) x;

  return v_resultado;
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_pagamento_por_semana(p_forma_pagamento text, p_semanas integer DEFAULT 7)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_resultado jsonb;
begin
  perform private.maria_exigir_acesso('maria_pagamento_por_semana');
  v_empresa_id := private.empresa_id_ativa();

  if not private.perm('pdv') then
    raise exception 'Sem permissão para consultar vendas';
  end if;

  if p_forma_pagamento is null
     or length(trim(p_forma_pagamento)) < 2 then
    raise exception 'Informe a forma de pagamento';
  end if;

  p_semanas := greatest(1, least(coalesce(p_semanas, 7), 52));

  with semanas as (
    select generate_series(
      date_trunc(
        'week',
        (now() at time zone 'America/Sao_Paulo')
      ) - make_interval(weeks => p_semanas - 1),
      date_trunc(
        'week',
        (now() at time zone 'America/Sao_Paulo')
      ),
      interval '1 week'
    )::date as inicio_semana
  ),
  dados as (
    select
      date_trunc(
        'week',
        (v.criado_em at time zone 'America/Sao_Paulo')
      )::date as inicio_semana,
      sum(v.total) as total,
      count(*) as vendas
    from public.vendas v
    where v.empresa_id = v_empresa_id
      and lower(trim(coalesce(v.forma_pagamento, ''))) =
          lower(trim(p_forma_pagamento))
      and (v.criado_em at time zone 'America/Sao_Paulo') >=
          date_trunc(
            'week',
            (now() at time zone 'America/Sao_Paulo')
          ) - make_interval(weeks => p_semanas - 1)
    group by 1
  )
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into v_resultado
  from (
    select
      s.inicio_semana,
      (s.inicio_semana + 6) as fim_semana,
      coalesce(d.total, 0) as total,
      coalesce(d.vendas, 0) as vendas
    from semanas s
    left join dados d
      on d.inicio_semana = s.inicio_semana
    order by s.inicio_semana
  ) x;

  return jsonb_build_object(
    'forma_pagamento', trim(p_forma_pagamento),
    'semanas', p_semanas,
    'resultados', v_resultado
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_panorama(p_inicio date DEFAULT NULL::date, p_fim date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  p record; ts_i timestamptz; ts_f timestamptz;
  r jsonb := '{}'::jsonb; v_sec jsonb; t record;
  v_vendas boolean := private.perm_alguma(array['pdv','dashboard','financeiro','fiscal','relatorios']);
begin
  perform private.maria_exigir_acesso('maria_panorama');
  perform private.maria_exigir(null);
  select * into p from private.maria_periodo(p_inicio, p_fim);
  ts_i := p.o_ini::timestamp at time zone 'America/Sao_Paulo';
  ts_f := (p.o_fim + 1)::timestamp at time zone 'America/Sao_Paulo';
  r := jsonb_build_object('periodo', jsonb_build_object('inicio', p.o_ini, 'fim', p.o_fim));

  -- financeiro
  begin v_sec := public.maria_financeiro_resumo(p.o_ini, p.o_fim);
  exception when others then v_sec := jsonb_build_object('indisponivel', case when sqlerrm in ('MARIA_SEM_PERMISSAO','MARIA_SEM_MODULO') then 'sem_permissao' else 'erro' end); end;
  r := r || jsonb_build_object('financeiro', v_sec);

  -- produtos mais vendidos
  if v_vendas and private.perm_alguma(array['produtos','estoque','notas_entrada','fiscal','dashboard','relatorios','bar_pedidos']) then
    begin
      select jsonb_build_object('mais_vendidos', coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)) into v_sec from (
        select b.nome, b.vendido as quantidade, b.receita from private.maria_base_estoque(v_emp, ts_i) b
         where b.vendido > 0 order by b.receita desc limit 5) x;
      -- base_estoque filtra por ts_i (início); recorta o fim com consulta própria quando o fim não é hoje
      if p.o_fim < v_hoje then
        select jsonb_build_object('mais_vendidos', coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)) into v_sec from (
          select pr.nome, sum(i.quantidade) as quantidade, sum(coalesce(i.subtotal, i.quantidade * i.preco_unitario)) as receita
            from public.itens_venda i join public.vendas v on v.id = i.venda_id and v.empresa_id = i.empresa_id
            join public.produtos pr on pr.id = i.produto_id and pr.empresa_id = i.empresa_id
           where v.empresa_id = v_emp and v.cancelada_em is null and v.criado_em >= ts_i and v.criado_em < ts_f
           group by pr.nome order by 3 desc limit 5) x;
      end if;
    exception when others then v_sec := jsonb_build_object('indisponivel', 'erro'); end;
  else v_sec := jsonb_build_object('indisponivel', 'sem_permissao'); end if;
  r := r || jsonb_build_object('produtos', v_sec);

  -- estoque
  if private.perm_alguma(array['produtos','estoque','notas_entrada','fiscal','dashboard','relatorios','bar_pedidos']) then
    select count(*) filter (where p2.tipo_fiscal = 'produto' and p2.quantidade_estoque <= 0) as zerados,
           count(*) filter (where p2.tipo_fiscal = 'produto' and p2.estoque_minimo > 0 and p2.quantidade_estoque < p2.estoque_minimo) as abaixo_min,
           coalesce(sum(p2.quantidade_estoque * p2.preco_custo) filter (where p2.tipo_fiscal = 'produto' and p2.quantidade_estoque > 0 and p2.preco_custo is not null),0) as valor_custo
      into t from public.produtos p2 where p2.empresa_id = v_emp;
    v_sec := jsonb_build_object('zerados', t.zerados, 'abaixo_do_minimo', t.abaixo_min, 'valor_em_estoque_a_custo', t.valor_custo);
  else v_sec := jsonb_build_object('indisponivel', 'sem_permissao'); end if;
  r := r || jsonb_build_object('estoque', v_sec);

  -- clientes
  if private.perm_alguma(array['clientes','pdv','dashboard','financeiro','fiscal','relatorios']) and v_vendas then
    begin
      select jsonb_build_object(
        'clientes_que_compraram_no_periodo', (select count(distinct v.cliente_id) from public.vendas v
            where v.empresa_id = v_emp and v.cancelada_em is null and v.cliente_id is not null and v.criado_em >= ts_i and v.criado_em < ts_f),
        'novos_ultimos_30_dias', (select count(*) from public.clientes where empresa_id = v_emp and criado_em >= now() - interval '30 days'),
        'inativos_ha_60_dias_ou_mais', (select count(*) from (select 1 from public.vendas v where v.empresa_id = v_emp and v.cancelada_em is null
            and v.cliente_id is not null group by v.cliente_id having max(v.criado_em) < now() - interval '60 days') z),
        'melhores', coalesce((select jsonb_agg(to_jsonb(x)) from (
            select c.nome, count(*) as compras, sum(v.total) as total from public.vendas v
              join public.clientes c on c.id = v.cliente_id and c.empresa_id = v.empresa_id
             where v.empresa_id = v_emp and v.cancelada_em is null and v.criado_em >= ts_i and v.criado_em < ts_f
             group by c.nome order by sum(v.total) desc limit 3) x), '[]'::jsonb)) into v_sec;
    exception when others then v_sec := jsonb_build_object('indisponivel', 'erro'); end;
  else v_sec := jsonb_build_object('indisponivel', 'sem_permissao'); end if;
  r := r || jsonb_build_object('clientes', v_sec);

  -- PET (só se módulo + permissão)
  if private.empresa_tem_modulo('pet') and private.perm_alguma(array['agenda','pacotes','pets']) then
    begin
      select jsonb_build_object(
        'agendamentos_hoje', (select count(*) from public.agendamentos where empresa_id = v_emp and data = v_hoje and status = 'agendado'),
        'agendamentos_proximos_7_dias', (select count(*) from public.agendamentos where empresa_id = v_emp and data between v_hoje and v_hoje + 7 and status = 'agendado'),
        'pacotes_vencendo_em_15_dias', (select count(*) from public.pacotes_clientes where empresa_id = v_emp and sessoes_usadas < sessoes_totais
            and data_validade between v_hoje and v_hoje + 15)) into v_sec;
    exception when others then v_sec := jsonb_build_object('indisponivel', 'erro'); end;
    r := r || jsonb_build_object('pet', v_sec);
  end if;

  -- BAR (só se módulo + permissão)
  if private.empresa_tem_modulo('bar') and private.perm_alguma(array['bar_visualizar','bar_mesas','bar_pedidos','bar_caixa','bar_configurar']) then
    begin
      select jsonb_build_object('mesas_ocupadas', count(*) filter (where status = 'ocupada'),
        'pessoas_no_bar', coalesce(sum(pessoas_atual) filter (where status = 'ocupada'),0)) into v_sec
        from public.bar_mesas where empresa_id = v_emp;
      if private.perm_alguma(array['bar_caixa','bar_configurar','bar_estornar_pagamento','financeiro','relatorios','dashboard']) then
        v_sec := v_sec || (select jsonb_build_object('bar_recebido_no_periodo', coalesce(sum(total),0), 'bar_pagamentos', count(*))
                             from public.bar_pagamentos where empresa_id = v_emp and not estornado and criado_em >= ts_i and criado_em < ts_f);
      end if;
    exception when others then v_sec := jsonb_build_object('indisponivel', 'erro'); end;
    r := r || jsonb_build_object('bar', v_sec);
  end if;

  return r;
end $function$;

CREATE OR REPLACE FUNCTION public.maria_pet_agenda(p_inicio date DEFAULT NULL::date, p_fim date DEFAULT NULL::date, p_status text DEFAULT NULL::text, p_limite integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ini date; v_fim date; v_lim integer := private.maria_lim(p_limite, 30, 60);
  v_st text := lower(btrim(coalesce(p_status,'')));
  v_itens jsonb; v_cont jsonb;
begin
  perform private.maria_exigir_acesso('maria_pet_agenda');
  perform private.maria_exigir(array['agenda'], 'pet');
  if v_st not in ('','agendado','concluido','cancelado') then raise exception 'Situação inválida (agendado, concluido ou cancelado).'; end if;
  if p_inicio is null and p_fim is null then v_ini := v_hoje; v_fim := v_hoje + 6;
  else select o_ini, o_fim into v_ini, v_fim from private.maria_periodo(p_inicio, p_fim); end if;

  select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) into v_cont from (
    select a.status, count(*) as n from public.agendamentos a
     where a.empresa_id = v_emp and a.data between v_ini and v_fim group by a.status) c;
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_itens from (
    select a.id, a.data, to_char(a.horario, 'HH24:MI') as horario, a.servico, a.status,
           coalesce(c.nome, '(cadastro do cliente indisponível)') as cliente, pe.nome as pet, pe.especie, a.pacote_cliente_id is not null as usa_pacote
      from public.agendamentos a
      left join public.clientes c on c.id = a.cliente_id and c.empresa_id = a.empresa_id
      left join public.pets pe on pe.id = a.pet_id and pe.empresa_id = a.empresa_id
     where a.empresa_id = v_emp and a.data between v_ini and v_fim and (v_st = '' or a.status = v_st)
     order by a.data, a.horario, a.id limit v_lim) x;
  return jsonb_build_object('periodo', jsonb_build_object('inicio', v_ini, 'fim', v_fim), 'contagem_por_status', v_cont,
                            'agendamentos', v_itens);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_pet_historico(p_pet_id uuid DEFAULT NULL::uuid, p_busca text DEFAULT NULL::text, p_limite integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_pad text := private.maria_like(p_busca);
  v_lim integer := private.maria_lim(p_limite, 10, 30);
  v_ids uuid[]; v_clientes integer; v_res jsonb := '[]'::jsonb; v_id uuid; v_cand jsonb;
begin
  perform private.maria_exigir_acesso('maria_pet_historico');
  perform private.maria_exigir(array['pets','agenda','pacotes'], 'pet');
  if p_pet_id is not null then
    select array_agg(p.id) into v_ids from public.pets p where p.id = p_pet_id and p.empresa_id = v_emp;
  else
    if length(btrim(coalesce(p_busca,''))) < 2 then raise exception 'Informe o nome do pet ou do tutor.'; end if;
    select array_agg(p.id), count(distinct p.cliente_id) into v_ids, v_clientes
      from public.pets p left join public.clientes c on c.id = p.cliente_id and c.empresa_id = p.empresa_id
     where p.empresa_id = v_emp and p.ativo and (private.maria_norm(p.nome) like v_pad escape '\' or private.maria_norm(c.nome) like v_pad escape '\');
    if coalesce(array_length(v_ids,1),0) > 1 and v_clientes > 1 then
      select jsonb_agg(jsonb_build_object('id', p.id, 'pet', p.nome, 'especie', p.especie, 'tutor', c.nome)) into v_cand
        from (select * from public.pets where id = any(v_ids) order by nome limit 8) p
        left join public.clientes c on c.id = p.cliente_id and c.empresa_id = v_emp;
      return jsonb_build_object('ambiguo', true, 'mensagem', 'Há mais de um pet/tutor com esse nome. Pergunte ao usuário qual deles.', 'candidatos', v_cand);
    end if;
    if coalesce(array_length(v_ids,1),0) > 5 then v_ids := v_ids[1:5]; end if;
  end if;
  if v_ids is null then return jsonb_build_object('encontrado', false); end if;

  foreach v_id in array v_ids loop
    v_res := v_res || jsonb_build_array((
      select jsonb_build_object(
        'pet', jsonb_build_object('id', p.id, 'nome', p.nome, 'especie', p.especie, 'raca', p.raca, 'porte', p.porte,
                                  'nascimento', p.data_nascimento, 'observacoes', left(p.observacoes, 300)),
        'tutor', c.nome,
        'ultimas_visitas', coalesce((select jsonb_agg(to_jsonb(x)) from (
            select a.data, to_char(a.horario,'HH24:MI') as horario, a.servico, a.status from public.agendamentos a
             where a.empresa_id = v_emp and a.pet_id = p.id order by a.data desc, a.horario desc limit v_lim) x), '[]'::jsonb),
        'proximo_agendamento', (select to_jsonb(y) from (select a.data, to_char(a.horario,'HH24:MI') as horario, a.servico from public.agendamentos a
             where a.empresa_id = v_emp and a.pet_id = p.id and a.status = 'agendado' and a.data >= (now() at time zone 'America/Sao_Paulo')::date
             order by a.data, a.horario limit 1) y),
        'pacotes', coalesce((select jsonb_agg(to_jsonb(z)) from (
            select pc.descricao, pc.sessoes_totais, pc.sessoes_usadas, pc.data_validade from public.pacotes_clientes pc
             where pc.empresa_id = v_emp and pc.pet_id = p.id order by pc.criado_em desc limit 5) z), '[]'::jsonb))
      from public.pets p left join public.clientes c on c.id = p.cliente_id and c.empresa_id = p.empresa_id
     where p.id = v_id and p.empresa_id = v_emp));
  end loop;
  return jsonb_build_object('encontrado', true, 'pets', v_res);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_pet_pacotes(p_busca text DEFAULT NULL::text, p_situacao text DEFAULT 'ativos'::text, p_limite integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_sit text := lower(btrim(coalesce(p_situacao,'ativos')));
  v_pad text := nullif(private.maria_like(p_busca), '%%');
  v_lim integer := private.maria_lim(p_limite, 20, 50);
  v_itens jsonb; v_total integer;
begin
  perform private.maria_exigir_acesso('maria_pet_pacotes');
  perform private.maria_exigir(array['pacotes'], 'pet');
  if v_sit not in ('ativos','concluidos','vencidos','vencendo','todos') then
    raise exception 'Situação inválida (ativos, concluidos, vencidos, vencendo ou todos).';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) - 'tg'), '[]'::jsonb), coalesce(max(tg),0) into v_itens, v_total from (
    select pc.id, pc.descricao, coalesce(c.nome, '(cadastro do cliente indisponível)') as cliente, pe.nome as pet,
           pc.sessoes_totais, pc.sessoes_usadas, pc.sessoes_totais - pc.sessoes_usadas as sessoes_restantes,
           pc.data_inicio, pc.data_validade,
           case when pc.data_validade is not null then pc.data_validade - v_hoje end as dias_para_vencer,
           (select max(u.usado_em) from public.pacote_usos u where u.pacote_id = pc.id and u.empresa_id = pc.empresa_id and not u.estornado) as ultimo_uso,
           coalesce((select jsonb_agg(jsonb_build_object('uso_id', u.id, 'sessao', u.numero_sessao, 'usado_em', u.usado_em, 'observacao', left(u.observacao, 80)))
                       from (select * from public.pacote_usos u2 where u2.pacote_id = pc.id and u2.empresa_id = pc.empresa_id and not u2.estornado
                              order by u2.usado_em desc limit 3) u), '[]'::jsonb) as usos_recentes,
           count(*) over() as tg
      from public.pacotes_clientes pc
      left join public.clientes c on c.id = pc.cliente_id and c.empresa_id = pc.empresa_id
      left join public.pets pe on pe.id = pc.pet_id and pe.empresa_id = pc.empresa_id
     where pc.empresa_id = v_emp
       and (v_pad is null or private.maria_norm(c.nome) like v_pad escape '\' or private.maria_norm(pe.nome) like v_pad escape '\'
            or private.maria_norm(pc.descricao) like v_pad escape '\')
       and (case v_sit
              when 'ativos' then pc.sessoes_usadas < pc.sessoes_totais and (pc.data_validade is null or pc.data_validade >= v_hoje)
              when 'concluidos' then pc.sessoes_usadas >= pc.sessoes_totais
              when 'vencidos' then pc.sessoes_usadas < pc.sessoes_totais and pc.data_validade < v_hoje
              when 'vencendo' then pc.sessoes_usadas < pc.sessoes_totais and pc.data_validade between v_hoje and v_hoje + 15
              else true end)
     order by pc.data_validade nulls last, pc.criado_em desc limit v_lim) x;
  return jsonb_build_object('situacao', v_sit, 'total', v_total, 'exibindo', jsonb_array_length(v_itens), 'pacotes', v_itens);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_pet_retorno(p_dias integer DEFAULT 30, p_limite integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_dias integer := least(greatest(coalesce(p_dias,30),1),730);
  v_lim integer := private.maria_lim(p_limite, 20, 50);
  v_itens jsonb; v_total integer;
begin
  perform private.maria_exigir_acesso('maria_pet_retorno');
  perform private.maria_exigir(array['agenda','pets'], 'pet');
  select coalesce(jsonb_agg(to_jsonb(x) - 'tg'), '[]'::jsonb), coalesce(max(tg),0) into v_itens, v_total from (
    select pe.id as pet_id, pe.nome as pet, pe.especie, coalesce(c.nome, '(cadastro do cliente indisponível)') as tutor, c.telefone,
           u.ultima as ultima_visita, v_hoje - u.ultima as dias_sem_voltar, count(*) over() as tg
      from public.pets pe
      join (select a.pet_id, max(a.data) as ultima from public.agendamentos a
             where a.empresa_id = v_emp and a.status = 'concluido' group by a.pet_id) u on u.pet_id = pe.id
      left join public.clientes c on c.id = pe.cliente_id and c.empresa_id = pe.empresa_id
     where pe.empresa_id = v_emp and pe.ativo and u.ultima < v_hoje - v_dias
       and not exists (select 1 from public.agendamentos f where f.empresa_id = v_emp and f.pet_id = pe.id
                          and f.status = 'agendado' and f.data >= v_hoje)
     order by u.ultima asc limit v_lim) x;
  return jsonb_build_object('dias', v_dias, 'total', v_total, 'exibindo', jsonb_array_length(v_itens), 'pets', v_itens);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_produto_detalhe(p_produto_id uuid DEFAULT NULL::uuid, p_busca text DEFAULT NULL::text, p_dias integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.maria_empresa();
  v_dias integer := least(greatest(coalesce(p_dias,90),1),365);
  v_ts timestamptz := now() - make_interval(days => least(greatest(coalesce(p_dias,90),1),365));
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_id uuid; v_cand jsonb; p public.produtos%rowtype; s_q numeric := 0; s_r numeric := 0; v_ult timestamptz; v_vend boolean;
begin
  perform private.maria_exigir_acesso('maria_produto_detalhe');
  perform private.maria_exigir(array['produtos','estoque','notas_entrada','fiscal','dashboard','relatorios','bar_pedidos']);
  select o_id, o_candidatos into v_id, v_cand from private.maria_resolver_produto(v_emp, p_produto_id, p_busca);
  if v_cand is not null then return jsonb_build_object('ambiguo', true, 'mensagem', 'Há mais de um produto com esse nome. Pergunte ao usuário qual deles.', 'candidatos', v_cand); end if;
  if v_id is null then return jsonb_build_object('encontrado', false); end if;
  select * into p from public.produtos where id = v_id and empresa_id = v_emp;
  v_vend := private.perm('relatorios') and private.perm_alguma(array['pdv','dashboard','financeiro','fiscal','relatorios']);

  if v_vend then
    select coalesce(sum(i.quantidade),0) as q, coalesce(sum(coalesce(i.subtotal, i.quantidade * i.preco_unitario)),0) as r into s_q, s_r
      from public.itens_venda i join public.vendas v on v.id = i.venda_id and v.empresa_id = i.empresa_id
     where v.empresa_id = v_emp and i.produto_id = v_id and v.cancelada_em is null and v.criado_em >= v_ts;
    select max(v.criado_em) into v_ult
      from public.itens_venda i join public.vendas v on v.id = i.venda_id and v.empresa_id = i.empresa_id
     where v.empresa_id = v_emp and i.produto_id = v_id and v.cancelada_em is null;
  end if;

  return jsonb_build_object('encontrado', true,
    'produto', jsonb_build_object('id', p.id, 'nome', p.nome, 'codigo', p.codigo, 'categoria', p.categoria, 'unidade', p.unidade_comercial,
        'tipo', p.tipo_fiscal, 'preco_venda', p.preco_venda, 'preco_custo', p.preco_custo,
        'margem_percentual', case when p.preco_custo > 0 and p.preco_venda > 0 then round((p.preco_venda - p.preco_custo) / p.preco_venda * 100, 1) end,
        'estoque', p.quantidade_estoque, 'estoque_minimo', p.estoque_minimo,
        'abaixo_do_minimo', coalesce(p.estoque_minimo > 0 and p.quantidade_estoque < p.estoque_minimo, false),
        'valor_em_estoque_a_custo', case when p.preco_custo is not null then round(p.quantidade_estoque * p.preco_custo, 2) end),
    'vendas', case when v_vend then jsonb_build_object('dias', v_dias, 'quantidade_vendida', s_q, 'receita', s_r,
        'media_diaria', round(s_q / v_dias, 2),
        'cobertura_estoque_dias', case when s_q > 0 then round(p.quantidade_estoque / (s_q / v_dias), 0) end,
        'ultima_venda', v_ult,
        'dias_desde_ultima_venda', case when v_ult is not null then v_hoje - (v_ult at time zone 'America/Sao_Paulo')::date end)
      else jsonb_build_object('indisponivel', 'sem_permissao') end);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_produto_por_dia_semana(p_produto text, p_dias integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_resultado jsonb;
begin
  perform private.maria_exigir_acesso('maria_produto_por_dia_semana');
  v_empresa_id := private.empresa_id_ativa();

  if not private.perm('pdv') then
    raise exception 'Sem permissão para consultar vendas';
  end if;

  if p_produto is null or length(trim(p_produto)) < 2 then
    raise exception 'Informe o produto';
  end if;

  p_dias := greatest(1, least(coalesce(p_dias, 90), 3650));

  with dias as (
    select *
    from (
      values
        (1, 'Segunda-feira'),
        (2, 'Terça-feira'),
        (3, 'Quarta-feira'),
        (4, 'Quinta-feira'),
        (5, 'Sexta-feira'),
        (6, 'Sábado'),
        (0, 'Domingo')
    ) d(numero_dia, dia_semana)
  ),
  vendas_produto as (
    select
      extract(
        dow from (v.criado_em at time zone 'America/Sao_Paulo')
      )::integer as numero_dia,
      sum(iv.quantidade) as quantidade,
      sum(iv.subtotal) as valor,
      count(distinct v.id) as vendas
    from public.itens_venda iv
    join public.vendas v
      on v.id = iv.venda_id
     and v.empresa_id = v_empresa_id
    join public.produtos p
      on p.id = iv.produto_id
     and p.empresa_id = v_empresa_id
    where iv.empresa_id = v_empresa_id
      and p.nome ilike '%' || trim(p_produto) || '%'
      and v.criado_em >= now() - make_interval(days => p_dias)
    group by 1
  )
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into v_resultado
  from (
    select
      d.numero_dia,
      d.dia_semana,
      coalesce(vp.quantidade, 0) as quantidade_vendida,
      coalesce(vp.valor, 0) as valor_vendido,
      coalesce(vp.vendas, 0) as vendas
    from dias d
    left join vendas_produto vp
      on vp.numero_dia = d.numero_dia
    order by d.numero_dia
  ) x;

  return jsonb_build_object(
    'produto_pesquisado', trim(p_produto),
    'periodo_dias', p_dias,
    'resultados', v_resultado
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_produtos_mais_vendidos_mes(p_limite integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_resultado jsonb;
  v_inicio timestamptz;
  v_fim timestamptz;
  v_limite integer;
begin
  perform private.maria_exigir_acesso('maria_produtos_mais_vendidos_mes');
  v_empresa_id := private.empresa_id_ativa();

  if not private.perm('pdv') then
    raise exception 'Usuário sem permissão para consultar vendas.';
  end if;

  v_limite := greatest(1, least(coalesce(p_limite,10),50));

  v_inicio :=
    date_trunc('month', now() at time zone 'America/Sao_Paulo')
    at time zone 'America/Sao_Paulo';

  v_fim := v_inicio + interval '1 month';

  select coalesce(
    jsonb_agg(to_jsonb(x) order by x.quantidade_vendida desc),
    '[]'::jsonb
  )
  into v_resultado
  from (
    select
      p.id,
      p.nome,
      p.codigo,
      p.gtin,
      sum(i.quantidade) as quantidade_vendida,
      round(sum(i.subtotal),2) as total_vendido
    from public.itens_venda i
    join public.vendas v
      on v.id = i.venda_id
     and v.empresa_id = v_empresa_id
    join public.produtos p
      on p.id = i.produto_id
     and p.empresa_id = v_empresa_id
    where i.empresa_id = v_empresa_id
      and v.criado_em >= v_inicio
      and v.criado_em < v_fim
    group by p.id, p.nome, p.codigo, p.gtin
    order by sum(i.quantidade) desc
    limit v_limite
  ) x;

  return v_resultado;
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_ranking_produtos(p_dias integer DEFAULT 30, p_limite integer DEFAULT 10, p_ordem text DEFAULT 'mais'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_resultado jsonb;
begin
  perform private.maria_exigir_acesso('maria_ranking_produtos');
  v_empresa_id := private.empresa_id_ativa();

  if not private.perm('pdv') then
    raise exception 'Sem permissão para consultar vendas';
  end if;

  p_dias := greatest(1, least(coalesce(p_dias, 30), 3650));
  p_limite := greatest(1, least(coalesce(p_limite, 10), 100));

  if lower(coalesce(p_ordem, 'mais')) not in ('mais', 'menos') then
    p_ordem := 'mais';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into v_resultado
  from (
    select
      p.id as produto_id,
      p.nome as produto,
      coalesce(sum(iv.quantidade), 0) as quantidade_vendida,
      coalesce(sum(iv.subtotal), 0) as valor_vendido,
      count(distinct v.id) as vendas
    from public.itens_venda iv
    join public.vendas v
      on v.id = iv.venda_id
     and v.empresa_id = v_empresa_id
    join public.produtos p
      on p.id = iv.produto_id
     and p.empresa_id = v_empresa_id
    where iv.empresa_id = v_empresa_id
      and v.criado_em >= now() - make_interval(days => p_dias)
    group by p.id, p.nome
    order by
      case
        when lower(p_ordem) = 'menos'
        then coalesce(sum(iv.quantidade), 0)
      end asc nulls last,
      case
        when lower(p_ordem) = 'mais'
        then coalesce(sum(iv.quantidade), 0)
      end desc nulls last,
      p.nome
    limit p_limite
  ) x;

  return jsonb_build_object(
    'periodo_dias', p_dias,
    'ordem', lower(p_ordem),
    'resultados', v_resultado
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_resumo_vendas_hoje()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_total numeric := 0;
  v_quantidade bigint := 0;
  v_ticket_medio numeric := 0;
  v_inicio_dia timestamptz;
  v_fim_dia timestamptz;
begin
  perform private.maria_exigir_acesso('maria_resumo_vendas_hoje');
  v_empresa_id := private.empresa_id_ativa();

  if v_empresa_id is null then
    raise exception 'Empresa ativa não encontrada para o usuário.';
  end if;

  if not private.perm('pdv') then
    raise exception 'Usuário sem permissão para consultar vendas.';
  end if;

  -- Dia comercial no horário de Brasília
  v_inicio_dia :=
    date_trunc(
      'day',
      now() at time zone 'America/Sao_Paulo'
    ) at time zone 'America/Sao_Paulo';

  v_fim_dia := v_inicio_dia + interval '1 day';

  select
    coalesce(sum(v.total), 0),
    count(*)
  into
    v_total,
    v_quantidade
  from public.vendas v
  where v.empresa_id = v_empresa_id
    and v.criado_em >= v_inicio_dia
    and v.criado_em < v_fim_dia;

  if v_quantidade > 0 then
    v_ticket_medio := v_total / v_quantidade;
  end if;

  return jsonb_build_object(
    'total_vendido', round(v_total, 2),
    'quantidade_vendas', v_quantidade,
    'ticket_medio', round(v_ticket_medio, 2),
    'data', (now() at time zone 'America/Sao_Paulo')::date
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_resumo_vendas_mes()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_total numeric := 0;
  v_quantidade bigint := 0;
  v_ticket numeric := 0;
  v_inicio timestamptz;
  v_fim timestamptz;
begin
  perform private.maria_exigir_acesso('maria_resumo_vendas_mes');
  v_empresa_id := private.empresa_id_ativa();

  if not private.perm('pdv') then
    raise exception 'Usuário sem permissão para consultar vendas.';
  end if;

  v_inicio :=
    date_trunc('month', now() at time zone 'America/Sao_Paulo')
    at time zone 'America/Sao_Paulo';

  v_fim := v_inicio + interval '1 month';

  select coalesce(sum(total),0), count(*)
  into v_total, v_quantidade
  from public.vendas
  where empresa_id = v_empresa_id
    and criado_em >= v_inicio
    and criado_em < v_fim;

  if v_quantidade > 0 then
    v_ticket := v_total / v_quantidade;
  end if;

  return jsonb_build_object(
    'total_vendido', round(v_total,2),
    'quantidade_vendas', v_quantidade,
    'ticket_medio', round(v_ticket,2),
    'mes', to_char(
      now() at time zone 'America/Sao_Paulo',
      'YYYY-MM'
    )
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_resumo_vendas_ontem()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_total numeric := 0;
  v_quantidade bigint := 0;
  v_ticket numeric := 0;
  v_inicio timestamptz;
  v_fim timestamptz;
begin
  perform private.maria_exigir_acesso('maria_resumo_vendas_ontem');
  v_empresa_id := private.empresa_id_ativa();

  if not private.perm('pdv') then
    raise exception 'Usuário sem permissão para consultar vendas.';
  end if;

  v_fim :=
    date_trunc('day', now() at time zone 'America/Sao_Paulo')
    at time zone 'America/Sao_Paulo';

  v_inicio := v_fim - interval '1 day';

  select coalesce(sum(total),0), count(*)
  into v_total, v_quantidade
  from public.vendas
  where empresa_id = v_empresa_id
    and criado_em >= v_inicio
    and criado_em < v_fim;

  if v_quantidade > 0 then
    v_ticket := v_total / v_quantidade;
  end if;

  return jsonb_build_object(
    'total_vendido', round(v_total,2),
    'quantidade_vendas', v_quantidade,
    'ticket_medio', round(v_ticket,2)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_ultimas_vendas(p_limite integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_empresa_id uuid;
  v_resultado jsonb;
  v_limite integer;
begin
  perform private.maria_exigir_acesso('maria_ultimas_vendas');
  v_empresa_id := private.empresa_id_ativa();

  if not private.perm('pdv') then
    raise exception 'Usuário sem permissão para consultar vendas.';
  end if;

  v_limite := greatest(1, least(coalesce(p_limite,10),50));

  select coalesce(
    jsonb_agg(to_jsonb(x) order by x.criado_em desc),
    '[]'::jsonb
  )
  into v_resultado
  from (
    select
      numero_venda,
      total,
      forma_pagamento,
      criado_em
    from public.vendas
    where empresa_id = v_empresa_id
    order by criado_em desc
    limit v_limite
  ) x;

  return v_resultado;
end;
$function$;

CREATE OR REPLACE FUNCTION public.maria_uso_atual()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_emp uuid := private.exigir_empresa_ativa();
  v_cfg jsonb := private.maria_config_efetiva(v_emp);
  v_mes date := private.maria_mes_ref();
  u public.maria_uso_mensal%rowtype;
  v_li integer := nullif(v_cfg->>'limite_interacoes_mes','')::integer;
  v_lt bigint  := nullif(v_cfg->>'limite_tokens_mes','')::bigint;
  v_lc numeric := nullif(v_cfg->>'limite_custo_usd_mes','')::numeric;
  v_pct numeric;
begin
  perform private.maria_exigir_acesso('maria_uso_atual');
  select * into u from public.maria_uso_mensal where empresa_id = v_emp and mes_ref = v_mes;
  v_pct := greatest(
     case when v_li > 0 then coalesce(u.interacoes,0)::numeric / v_li else 0 end,
     case when v_lt > 0 then coalesce(u.tokens_total,0)::numeric / v_lt else 0 end,
     case when v_lc > 0 then coalesce(u.custo_usd,0) / v_lc else 0 end);
  return jsonb_build_object(
    'ativa', (v_cfg->>'ativa')::boolean, 'plano', v_cfg->>'plano_nome',
    'interacoes', coalesce(u.interacoes,0), 'limite_interacoes', v_li,
    'tokens_total', coalesce(u.tokens_total,0), 'limite_tokens', v_lt,
    'percentual_usado', case when v_li is null and v_lt is null and v_lc is null then null else round(least(v_pct,9.99)*100, 1) end,
    'ultimo_uso', u.ultimo_uso);
end $function$;

CREATE OR REPLACE FUNCTION public.maria_uso_iniciar(p_interacao_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_emp    uuid;
  v_uid    uuid := auth.uid();
  v_cfg    jsonb;
  v_mes    date := private.maria_mes_ref();
  v_uso    public.maria_uso_mensal%rowtype;
  v_glob   public.maria_config_global%rowtype;
  v_preco  public.maria_precos_modelo%rowtype;
  v_res_n  integer; v_res_tok bigint; v_res_custo numeric;
  v_reserva_tok bigint; v_reserva_custo numeric;
  v_lim_i  integer; v_lim_t bigint; v_lim_c numeric;
  v_motivo text;
  v_pend   jsonb;
begin
  perform private.maria_exigir_acesso('maria_uso_iniciar');
  perform private.maria_exigir_servidor();
  v_emp := private.exigir_empresa_ativa();
  if p_interacao_id is null then raise exception 'Identificador da interação é obrigatório.'; end if;

  select * into v_glob from public.maria_config_global where id;
  v_cfg := private.maria_config_efetiva(v_emp);
  v_preco := private.maria_preco_vigente(v_glob.modelo_padrao);
  v_reserva_tok := v_glob.reserva_tokens;
  -- reserva de custo: pior caso (tudo cobrado como saída) — conservadora e barata de calcular.
  v_reserva_custo := round(v_reserva_tok * v_preco.usd_milhao_saida / 1000000.0, 8);

  -- Linha do mês + trava (serializa o pré-check da empresa).
  insert into public.maria_uso_mensal (empresa_id, mes_ref) values (v_emp, v_mes) on conflict do nothing;
  select * into v_uso from public.maria_uso_mensal where empresa_id = v_emp and mes_ref = v_mes for update;

  -- Reservas vencidas = a Edge Function não conseguiu finalizar (queda, timeout, JWT expirado no meio).
  -- O consumo real é desconhecido, então são DEBITADAS (1 interação + tokens reservados) em vez de sumirem:
  -- ninguém consegue "uso grátis" interrompendo a requisição. Fica registrado como erro 'reserva_expirada'.
  with exp as (
    update public.maria_interacoes set status = 'erro', erro_codigo = 'reserva_expirada', finalizado_em = now(),
           tokens_total = tokens_reservados
     where empresa_id = v_emp and status = 'reservada'
       and criado_em <= now() - make_interval(secs => v_glob.reserva_ttl_segundos)
    returning mes_ref, tokens_reservados),
  ag as (select mes_ref, count(*) as n, sum(tokens_reservados) as t from exp group by mes_ref)
  update public.maria_uso_mensal u set interacoes = u.interacoes + ag.n, tokens_total = u.tokens_total + ag.t, atualizado_em = now()
    from ag where u.empresa_id = v_emp and u.mes_ref = ag.mes_ref;
  select * into v_uso from public.maria_uso_mensal where empresa_id = v_emp and mes_ref = v_mes;

  if not (v_cfg->>'ativa')::boolean then
    v_motivo := 'desativada';
  else
    select count(*), coalesce(sum(tokens_reservados),0), coalesce(sum(custo_reservado),0)
      into v_res_n, v_res_tok, v_res_custo
      from public.maria_interacoes
     where empresa_id = v_emp and status = 'reservada'
       and criado_em > now() - make_interval(secs => v_glob.reserva_ttl_segundos);

    v_lim_i := nullif(v_cfg->>'limite_interacoes_mes','')::integer;
    v_lim_t := nullif(v_cfg->>'limite_tokens_mes','')::bigint;
    v_lim_c := nullif(v_cfg->>'limite_custo_usd_mes','')::numeric;

    if v_lim_i is not null and v_uso.interacoes + v_res_n >= v_lim_i then v_motivo := 'limite_interacoes';
    elsif v_lim_t is not null and v_uso.tokens_total + v_res_tok >= v_lim_t then v_motivo := 'limite_tokens';
    elsif v_lim_c is not null and v_uso.custo_usd + v_res_custo >= v_lim_c then v_motivo := 'limite_custo';
    end if;
  end if;

  -- Anti-abuso: no máximo 3 consultas simultâneas por usuário (protege a chave compartilhada da Groq).
  if v_motivo is null and (select count(*) from public.maria_interacoes
        where empresa_id = v_emp and user_id = v_uid and status = 'reservada'
          and criado_em > now() - make_interval(secs => v_glob.reserva_ttl_segundos)) >= 3 then
    return jsonb_build_object('permitido', false, 'motivo', 'muitas_simultaneas',
      'mensagem', 'A MARIA está recebendo muitas consultas neste momento. Aguarde alguns segundos e tente novamente.');
  end if;

  if v_motivo is not null then
    insert into public.maria_interacoes (id, empresa_id, user_id, mes_ref, status, operacao, erro_codigo, finalizado_em)
    values (p_interacao_id, v_emp, v_uid, v_mes, 'bloqueada', 'bloqueio', v_motivo, now())
    on conflict (id) do nothing;
    update public.maria_uso_mensal set bloqueios = bloqueios + 1, atualizado_em = now()
     where empresa_id = v_emp and mes_ref = v_mes;
    return jsonb_build_object('permitido', false, 'motivo', v_motivo,
      'mensagem', case when v_motivo = 'desativada'
        then 'A MARIA não está ativa para a sua empresa. Entre em contato com a Florest Sistemas.'
        else 'Seu limite mensal da MARIA foi atingido. Entre em contato com a Florest Sistemas para continuar utilizando o recurso.' end);
  end if;

  insert into public.maria_interacoes (id, empresa_id, user_id, mes_ref, status, tokens_reservados, custo_reservado, modelo)
  values (p_interacao_id, v_emp, v_uid, v_mes, 'reservada', v_reserva_tok, v_reserva_custo, v_glob.modelo_padrao);

  select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'resumo', a.resumo, 'reforcada', a.reforcada, 'expira_em', a.expira_em)
    into v_pend
    from public.maria_acoes_pendentes a
   where a.empresa_id = v_emp and a.user_id = v_uid and a.status = 'pendente' and a.expira_em > now();

  return jsonb_build_object(
    'permitido', true,
    'plano', v_cfg->>'plano',
    'modelo', v_glob.modelo_padrao,
    'consultoria', (v_cfg->>'permite_consultoria')::boolean,
    'acoes', (v_cfg->>'permite_acoes')::boolean,
    'modulos', jsonb_build_object('pet', private.empresa_tem_modulo('pet'), 'bar', private.empresa_tem_modulo('bar')),
    'permissoes', jsonb_build_object(
        'financeiro', private.perm_alguma(array['financeiro','relatorios']),
        'vendas',     private.perm_alguma(array['pdv','dashboard','financeiro','fiscal','relatorios']),
        'clientes',   private.perm_alguma(array['clientes','pdv','dashboard','financeiro','fiscal','relatorios']),
        'produtos',   private.perm_alguma(array['produtos','estoque','notas_entrada','fiscal','dashboard','relatorios','bar_pedidos']),
        'pet',        private.perm_alguma(array['pets','agenda','pacotes']),
        'bar',        private.perm_alguma(array['bar_visualizar','bar_mesas','bar_pedidos','bar_caixa','bar_portaria','bar_configurar'])),
    'acoes_permitidas', private.maria_acoes_permitidas(),
    'acao_pendente', v_pend
  );
end $function$;
COMMIT;

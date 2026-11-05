-- SOMENTE LEITURA. Execute no SQL Editor do projeto correto e exporte o resultado.
-- Não lê cadastros, vendas, usuários, credenciais fiscais ou dados de clientes.
-- Recupera contratos atuais antes de escrever uma migração de PDV Móvel.
select jsonb_pretty(jsonb_build_object(
  'versao_postgres', current_setting('server_version'),
  'colunas', (select jsonb_agg(to_jsonb(c) - 'column_default' order by c.table_schema,c.table_name,c.ordinal_position)
    from information_schema.columns c where c.table_schema in ('public','private')
    and c.table_name in ('vendas','itens_venda','vendas_pagamentos','caixas','caixa_movimentos','contas_receber','contas_receber_pagamentos','produtos','perfis','configuracoes_empresa','contadores_venda','documentos_fiscais','taxas_pagamentos')),
  'defaults', (select jsonb_agg(jsonb_build_object('tabela',c.table_name,'coluna',c.column_name,'expressao',c.column_default))
    from information_schema.columns c where c.table_schema='public' and c.table_name in ('vendas','itens_venda','vendas_pagamentos','caixas','contas_receber') and c.column_default is not null),
  'restricoes', (select jsonb_agg(jsonb_build_object('schema',n.nspname,'tabela',r.relname,'nome',c.conname,'tipo',c.contype,'definicao',pg_get_constraintdef(c.oid)))
    from pg_constraint c join pg_class r on r.oid=c.conrelid join pg_namespace n on n.oid=r.relnamespace
    where n.nspname='public' and r.relname in ('vendas','itens_venda','vendas_pagamentos','caixas','contas_receber','produtos')),
  'indices', (select jsonb_agg(to_jsonb(i)) from pg_indexes i where i.schemaname='public' and i.tablename in ('vendas','itens_venda','vendas_pagamentos','caixas','contas_receber')),
  'politicas', (select jsonb_agg(to_jsonb(p)) from pg_policies p where p.schemaname='public' and p.tablename in ('vendas','itens_venda','vendas_pagamentos','caixas','contas_receber','produtos','perfis','clientes')),
  'triggers', (select jsonb_agg(jsonb_build_object('tabela',c.relname,'definicao',pg_get_triggerdef(t.oid),'funcao',pg_get_functiondef(t.tgfoid)))
    from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
    where not t.tgisinternal and n.nspname='public' and c.relname in ('vendas','itens_venda','vendas_pagamentos','caixas','contas_receber','produtos')),
  'funcoes', (select jsonb_agg(jsonb_build_object('schema',n.nspname,'nome',p.proname,'argumentos',pg_get_function_identity_arguments(p.oid),'definicao',pg_get_functiondef(p.oid)))
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','private') and p.prokind='f'
      and (p.proname in ('registrar_venda','registrar_venda_mista','registrar_venda_prazo','venda_mista_validar_pagamentos','caixa_exigir_aberto','caixa_atual','caixa_abrir','caixa_fechar','caixa_detalhe','caixa_listar','caixa_json','exigir_empresa_ativa','perm','pdv_historico_listar','pdv_historico_detalhar','pdv_hoje','ultimo_dia_do_mes','taxas_registrar','taxas_pagamento_obter','pdv_produtos_consultar')
      or p.proname like 'pdv_movel_%' or p.proname like 'caixa_%' or p.proname like '%venda%estoque%'))
)) as esquema_pdv_sem_dados;

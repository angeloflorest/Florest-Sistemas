-- =====================================================================
-- 003_politicas_rls.sql
-- Florest ERP (Supabase / PostgreSQL) — políticas RLS do schema public
-- Gerado exclusivamente a partir do CSV de políticas (nomes, comandos, roles,
-- USING e WITH CHECK preservados exatamente). Sem FORCE ROW LEVEL SECURITY.
-- Somente RLS: sem tabelas, funções, triggers, dados ou segredos.
--
-- Pré-requisito: executar antes 001_estrutura_banco.sql e 002_funcoes_banco.sql
-- (as políticas usam private.empresa_id_ativa(), private.empresa_id_do_usuario(),
-- private.eh_proprietario(), private.perm(), private.perm_alguma() e auth.uid()).
-- Ordem: 1 ENABLE ROW LEVEL SECURITY | 2 políticas por tabela.
-- =====================================================================

set search_path = public;

-- =====================================================================
-- 1. ENABLE ROW LEVEL SECURITY (tabelas que possuem políticas)
-- =====================================================================
alter table public.clientes enable row level security;
alter table public.configuracoes_empresa enable row level security;
alter table public.configuracoes_fiscais enable row level security;
alter table public.contadores_fiscais enable row level security;
alter table public.despesas enable row level security;
alter table public.documentos_fiscais enable row level security;
alter table public.documentos_fiscais_eventos enable row level security;
alter table public.empresas enable row level security;
alter table public.fornecedores enable row level security;
alter table public.itens_venda enable row level security;
alter table public.notas_entrada enable row level security;
alter table public.notas_entrada_itens enable row level security;
alter table public.pdv_atalhos enable row level security;
alter table public.pdv_atalhos_produtos enable row level security;
alter table public.perfis enable row level security;
alter table public.produtos enable row level security;
alter table public.vendas enable row level security;

-- =====================================================================
-- 2. POLÍTICAS
-- =====================================================================

-- clientes
create policy "clientes_insert" on public.clientes
  as permissive
  for insert
  to authenticated
  with check ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "clientes_select" on public.clientes
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "clientes_update" on public.clientes
  as permissive
  for update
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)))
  with check ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_clientes_insert" on public.clientes
  as restrictive
  for insert
  to authenticated
  with check (( SELECT private.perm_alguma(ARRAY['clientes'::text]) AS perm_alguma));
create policy "rbac_clientes_select" on public.clientes
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['clientes'::text, 'pdv'::text, 'dashboard'::text, 'financeiro'::text, 'fiscal'::text, 'relatorios'::text]) AS perm_alguma));
create policy "rbac_clientes_update" on public.clientes
  as restrictive
  for update
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['clientes'::text]) AS perm_alguma))
  with check (( SELECT private.perm_alguma(ARRAY['clientes'::text]) AS perm_alguma));

-- configuracoes_empresa
create policy "configuracoes_empresa_select" on public.configuracoes_empresa
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));

-- configuracoes_fiscais
create policy "config_fiscal_insert" on public.configuracoes_fiscais
  as permissive
  for insert
  to authenticated
  with check ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "config_fiscal_select" on public.configuracoes_fiscais
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "config_fiscal_update" on public.configuracoes_fiscais
  as permissive
  for update
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)))
  with check ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_configuracoes_fiscais_insert" on public.configuracoes_fiscais
  as restrictive
  for insert
  to authenticated
  with check (( SELECT private.perm_alguma(ARRAY['configuracoes'::text]) AS perm_alguma));
create policy "rbac_configuracoes_fiscais_select" on public.configuracoes_fiscais
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['configuracoes'::text, 'fiscal'::text, 'pdv'::text]) AS perm_alguma));
create policy "rbac_configuracoes_fiscais_update" on public.configuracoes_fiscais
  as restrictive
  for update
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['configuracoes'::text]) AS perm_alguma))
  with check (( SELECT private.perm_alguma(ARRAY['configuracoes'::text]) AS perm_alguma));

-- contadores_fiscais
create policy "contadores_fiscais_select" on public.contadores_fiscais
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_contadores_fiscais_select" on public.contadores_fiscais
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['configuracoes'::text, 'fiscal'::text]) AS perm_alguma));

-- despesas
create policy "despesas_delete" on public.despesas
  as permissive
  for delete
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "despesas_insert" on public.despesas
  as permissive
  for insert
  to authenticated
  with check ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "despesas_select" on public.despesas
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "despesas_update" on public.despesas
  as permissive
  for update
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)))
  with check ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_despesas_delete" on public.despesas
  as restrictive
  for delete
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['financeiro'::text]) AS perm_alguma));
create policy "rbac_despesas_insert" on public.despesas
  as restrictive
  for insert
  to authenticated
  with check (( SELECT private.perm_alguma(ARRAY['financeiro'::text]) AS perm_alguma));
create policy "rbac_despesas_select" on public.despesas
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['financeiro'::text, 'relatorios'::text]) AS perm_alguma));
create policy "rbac_despesas_update" on public.despesas
  as restrictive
  for update
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['financeiro'::text]) AS perm_alguma))
  with check (( SELECT private.perm_alguma(ARRAY['financeiro'::text]) AS perm_alguma));

-- documentos_fiscais
create policy "documentos_fiscais_select" on public.documentos_fiscais
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_documentos_fiscais_select" on public.documentos_fiscais
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['fiscal'::text, 'pdv'::text]) AS perm_alguma));

-- documentos_fiscais_eventos
create policy "doc_eventos_select" on public.documentos_fiscais_eventos
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_documentos_fiscais_eventos_select" on public.documentos_fiscais_eventos
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['fiscal'::text, 'pdv'::text]) AS perm_alguma));

-- empresas
create policy "empresas_select_propria" on public.empresas
  as permissive
  for select
  to authenticated
  using ((id = ( SELECT private.empresa_id_do_usuario() AS empresa_id_do_usuario)));

-- fornecedores
create policy "fornecedores_insert" on public.fornecedores
  as permissive
  for insert
  to authenticated
  with check ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "fornecedores_select" on public.fornecedores
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "fornecedores_update" on public.fornecedores
  as permissive
  for update
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)))
  with check ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_fornecedores_insert" on public.fornecedores
  as restrictive
  for insert
  to authenticated
  with check (( SELECT private.perm_alguma(ARRAY['fornecedores'::text]) AS perm_alguma));
create policy "rbac_fornecedores_select" on public.fornecedores
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['fornecedores'::text, 'notas_entrada'::text, 'financeiro'::text, 'relatorios'::text]) AS perm_alguma));
create policy "rbac_fornecedores_update" on public.fornecedores
  as restrictive
  for update
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['fornecedores'::text]) AS perm_alguma))
  with check (( SELECT private.perm_alguma(ARRAY['fornecedores'::text]) AS perm_alguma));

-- itens_venda
create policy "itens_venda_select" on public.itens_venda
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_itens_venda_select" on public.itens_venda
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['pdv'::text, 'dashboard'::text, 'financeiro'::text, 'fiscal'::text, 'relatorios'::text]) AS perm_alguma));

-- notas_entrada
create policy "notas_entrada_select" on public.notas_entrada
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_notas_entrada_select" on public.notas_entrada
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['notas_entrada'::text, 'relatorios'::text]) AS perm_alguma));

-- notas_entrada_itens
create policy "ne_itens_select" on public.notas_entrada_itens
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_notas_entrada_itens_select" on public.notas_entrada_itens
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['notas_entrada'::text, 'relatorios'::text]) AS perm_alguma));

-- pdv_atalhos
create policy "pdv_atalhos_delete" on public.pdv_atalhos
  as permissive
  for delete
  to authenticated
  using (((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)) AND ( SELECT private.eh_proprietario() AS eh_proprietario)));
create policy "pdv_atalhos_insert" on public.pdv_atalhos
  as permissive
  for insert
  to authenticated
  with check (((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)) AND ( SELECT private.eh_proprietario() AS eh_proprietario)));
create policy "pdv_atalhos_select" on public.pdv_atalhos
  as permissive
  for select
  to authenticated
  using (((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)) AND ( SELECT private.perm('pdv'::text) AS perm)));
create policy "pdv_atalhos_update" on public.pdv_atalhos
  as permissive
  for update
  to authenticated
  using (((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)) AND ( SELECT private.eh_proprietario() AS eh_proprietario)))
  with check (((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)) AND ( SELECT private.eh_proprietario() AS eh_proprietario)));

-- pdv_atalhos_produtos
create policy "pdv_atalhos_produtos_delete" on public.pdv_atalhos_produtos
  as permissive
  for delete
  to authenticated
  using (((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)) AND ( SELECT private.eh_proprietario() AS eh_proprietario)));
create policy "pdv_atalhos_produtos_insert" on public.pdv_atalhos_produtos
  as permissive
  for insert
  to authenticated
  with check (((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)) AND ( SELECT private.eh_proprietario() AS eh_proprietario)));
create policy "pdv_atalhos_produtos_select" on public.pdv_atalhos_produtos
  as permissive
  for select
  to authenticated
  using (((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)) AND ( SELECT private.perm('pdv'::text) AS perm)));
create policy "pdv_atalhos_produtos_update" on public.pdv_atalhos_produtos
  as permissive
  for update
  to authenticated
  using (((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)) AND ( SELECT private.eh_proprietario() AS eh_proprietario)))
  with check (((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)) AND ( SELECT private.eh_proprietario() AS eh_proprietario)));

-- perfis
create policy "perfis_select_proprio" on public.perfis
  as permissive
  for select
  to authenticated
  using ((id = ( SELECT auth.uid() AS uid)));

-- produtos
create policy "produtos_insert" on public.produtos
  as permissive
  for insert
  to authenticated
  with check ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "produtos_select" on public.produtos
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "produtos_update" on public.produtos
  as permissive
  for update
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)))
  with check ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_produtos_insert" on public.produtos
  as restrictive
  for insert
  to authenticated
  with check (( SELECT private.perm_alguma(ARRAY['produtos'::text]) AS perm_alguma));
create policy "rbac_produtos_select" on public.produtos
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['produtos'::text, 'estoque'::text, 'notas_entrada'::text, 'fiscal'::text, 'dashboard'::text, 'relatorios'::text]) AS perm_alguma));
create policy "rbac_produtos_update" on public.produtos
  as restrictive
  for update
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['produtos'::text, 'estoque'::text]) AS perm_alguma))
  with check (( SELECT private.perm_alguma(ARRAY['produtos'::text, 'estoque'::text]) AS perm_alguma));

-- vendas
create policy "vendas_select" on public.vendas
  as permissive
  for select
  to authenticated
  using ((empresa_id = ( SELECT private.empresa_id_ativa() AS empresa_id_ativa)));
create policy "rbac_vendas_select" on public.vendas
  as restrictive
  for select
  to authenticated
  using (( SELECT private.perm_alguma(ARRAY['pdv'::text, 'dashboard'::text, 'financeiro'::text, 'fiscal'::text, 'relatorios'::text]) AS perm_alguma));

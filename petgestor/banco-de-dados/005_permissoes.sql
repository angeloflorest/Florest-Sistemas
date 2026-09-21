-- ==========================================================
-- 005_permissoes.sql
-- PetGestor / ERP PETSHOP — Permissões de execução das funções (Supabase)
--
-- Arquivo OFICIAL e ISOLADO de permissões do backup. Reconstrói fielmente
-- o GRANT/REVOKE de EXECUTE das 30 funções (private + public), extraído
-- diretamente do Supabase em produção.
--
-- As funções em si estão em 002_funcoes_banco.sql, que atualmente também
-- contém sua própria cópia deste GRANT/REVOKE ao final. Este arquivo é o
-- destino futuro único das permissões — quando o GRANT/REVOKE for removido
-- de 002, este 005 passa a ser a única fonte, sem mudar o estado atual do
-- banco (o conteúdo é idêntico ao que já está aplicado).
--
-- Não inclui tabelas, definições de função, policies, triggers, cron ou dados.
-- ==========================================================

-- ---------- schema: private ----------

revoke all on function private.florest_cnpj_valido(p_cnpj text) from public, anon, authenticated, service_role;

revoke all on function private.florest_criar_cadastro_remoto(p_sis uuid, p_ref text, p_dados jsonb) from public, anon, authenticated, service_role;

revoke all on function private.florest_normalizar_cadastro(p_dados jsonb, p_modo text) from public, anon, authenticated, service_role;

revoke all on function private.florest_set_atualizado_em() from public, anon, authenticated, service_role;

revoke all on function private.florest_sistema_remoto(p_slug text, p_exigir_ativo boolean) from public, anon, authenticated, service_role;

-- ---------- schema: public ----------

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

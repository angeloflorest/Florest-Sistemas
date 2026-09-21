-- =====================================================================
-- 005_permissoes.sql
-- Florest ERP (Supabase / PostgreSQL) — permissões EXECUTE das funções/RPCs
-- dos schemas private e public.
-- Gerado exclusivamente a partir do CSV de permissões (ACL atual).
-- Somente REVOKE/GRANT: sem tabelas, funções, políticas RLS, triggers, dados
-- ou segredos.
--
-- Pré-requisito: executar antes 001_estrutura_banco.sql e 002_funcoes_banco.sql.
--
-- Método por função: REVOKE ALL de PUBLIC, anon, authenticated e service_role
-- (zera os privilégios padrão do Supabase) e, em seguida, GRANT EXECUTE apenas
-- aos grantees listados no CSV. "=X/postgres" no CSV = PUBLIC.
-- O privilégio do dono (postgres) é implícito e não é repetido aqui.
-- Argumentos OUT constam na assinatura exatamente como no CSV.
-- =====================================================================


-- =====================================================================
-- FUNÇÕES DO SCHEMA PRIVATE
-- =====================================================================

-- private.eh_proprietario()   ACL: {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
revoke all on function private.eh_proprietario() from public, anon, authenticated, service_role;
grant execute on function private.eh_proprietario() to authenticated;
grant execute on function private.eh_proprietario() to service_role;

-- private.empresa_id_ativa()   ACL: {=X/postgres,postgres=X/postgres,authenticated=X/postgres}
revoke all on function private.empresa_id_ativa() from public, anon, authenticated, service_role;
grant execute on function private.empresa_id_ativa() to public;
grant execute on function private.empresa_id_ativa() to authenticated;

-- private.empresa_id_do_usuario()   ACL: {=X/postgres,postgres=X/postgres,authenticated=X/postgres}
revoke all on function private.empresa_id_do_usuario() from public, anon, authenticated, service_role;
grant execute on function private.empresa_id_do_usuario() to public;
grant execute on function private.empresa_id_do_usuario() to authenticated;

-- private.empresas_regras()   ACL: {postgres=X/postgres}
revoke all on function private.empresas_regras() from public, anon, authenticated, service_role;

-- private.exigir_empresa_ativa()   ACL: {postgres=X/postgres}
revoke all on function private.exigir_empresa_ativa() from public, anon, authenticated, service_role;

-- private.fiscal_emitir_nota(p_venda_id uuid)   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function private.fiscal_emitir_nota(p_venda_id uuid) from public, anon, authenticated, service_role;
grant execute on function private.fiscal_emitir_nota(p_venda_id uuid) to service_role;

-- private.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero integer)   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function private.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero integer) from public, anon, authenticated, service_role;
grant execute on function private.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero integer) to service_role;

-- private.florest_cnpj_valido(p_cnpj text)   ACL: {postgres=X/postgres}
revoke all on function private.florest_cnpj_valido(p_cnpj text) from public, anon, authenticated, service_role;

-- private.florest_empresas_outbox()   ACL: {postgres=X/postgres}
revoke all on function private.florest_empresas_outbox() from public, anon, authenticated, service_role;

-- private.florest_normalizar_cadastro(p_dados jsonb, p_modo text)   ACL: {postgres=X/postgres}
revoke all on function private.florest_normalizar_cadastro(p_dados jsonb, p_modo text) from public, anon, authenticated, service_role;

-- private.notas_entrada_confirmar(p_nota jsonb)   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function private.notas_entrada_confirmar(p_nota jsonb) from public, anon, authenticated, service_role;
grant execute on function private.notas_entrada_confirmar(p_nota jsonb) to service_role;

-- private.perm(p_modulo text)   ACL: {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
revoke all on function private.perm(p_modulo text) from public, anon, authenticated, service_role;
grant execute on function private.perm(p_modulo text) to authenticated;
grant execute on function private.perm(p_modulo text) to service_role;

-- private.perm_alguma(p_modulos text[])   ACL: {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
revoke all on function private.perm_alguma(p_modulos text[]) from public, anon, authenticated, service_role;
grant execute on function private.perm_alguma(p_modulos text[]) to authenticated;
grant execute on function private.perm_alguma(p_modulos text[]) to service_role;

-- private.produtos_proteger_colunas()   ACL: {postgres=X/postgres}
revoke all on function private.produtos_proteger_colunas() from public, anon, authenticated, service_role;

-- private.proteger_config_fiscal()   ACL: {postgres=X/postgres}
revoke all on function private.proteger_config_fiscal() from public, anon, authenticated, service_role;

-- private.set_atualizado_em()   ACL: {postgres=X/postgres}
revoke all on function private.set_atualizado_em() from public, anon, authenticated, service_role;

-- private.usuarios_alvo(p_ator uuid, p_alvo uuid, OUT o_empresa uuid, OUT o_papel_ator text, OUT o_perm_ator text[])   ACL: {postgres=X/postgres}
revoke all on function private.usuarios_alvo(p_ator uuid, p_alvo uuid, OUT o_empresa uuid, OUT o_papel_ator text, OUT o_perm_ator text[]) from public, anon, authenticated, service_role;

-- private.usuarios_ator(p_ator uuid, OUT o_empresa uuid, OUT o_papel text, OUT o_permissoes text[])   ACL: {postgres=X/postgres}
revoke all on function private.usuarios_ator(p_ator uuid, OUT o_empresa uuid, OUT o_papel text, OUT o_permissoes text[]) from public, anon, authenticated, service_role;

-- private.usuarios_modulos()   ACL: {postgres=X/postgres}
revoke all on function private.usuarios_modulos() from public, anon, authenticated, service_role;

-- private.usuarios_normalizar_permissoes(p_perm text[], p_ator_papel text, p_ator_perm text[])   ACL: {postgres=X/postgres}
revoke all on function private.usuarios_normalizar_permissoes(p_perm text[], p_ator_papel text, p_ator_perm text[]) from public, anon, authenticated, service_role;

-- =====================================================================
-- FUNÇÕES DO SCHEMA PUBLIC
-- =====================================================================

-- public.configuracao_venda_sem_estoque_definir(p_permitir boolean)   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.configuracao_venda_sem_estoque_definir(p_permitir boolean) from public, anon, authenticated, service_role;
grant execute on function public.configuracao_venda_sem_estoque_definir(p_permitir boolean) to service_role;
grant execute on function public.configuracao_venda_sem_estoque_definir(p_permitir boolean) to authenticated;

-- public.fiscal_emitir_nota(p_venda_id uuid)   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.fiscal_emitir_nota(p_venda_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.fiscal_emitir_nota(p_venda_id uuid) to service_role;
grant execute on function public.fiscal_emitir_nota(p_venda_id uuid) to authenticated;

-- public.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero integer)   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero integer) from public, anon, authenticated, service_role;
grant execute on function public.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero integer) to service_role;
grant execute on function public.fiscal_inicializar_contador(p_tipo_documento text, p_serie text, p_ultimo_numero integer) to authenticated;

-- public.florest_aplicar_assinatura(p_empresa_id uuid, p_assinatura_id uuid, p_revisao bigint, p_status_conta text, p_vencimento date, p_motivo text, p_ator text)   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function public.florest_aplicar_assinatura(p_empresa_id uuid, p_assinatura_id uuid, p_revisao bigint, p_status_conta text, p_vencimento date, p_motivo text, p_ator text) from public, anon, authenticated, service_role;
grant execute on function public.florest_aplicar_assinatura(p_empresa_id uuid, p_assinatura_id uuid, p_revisao bigint, p_status_conta text, p_vencimento date, p_motivo text, p_ator text) to service_role;

-- public.florest_listar_empresas(p_apos_atualizado timestamp with time zone, p_apos_id uuid, p_limite integer)   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function public.florest_listar_empresas(p_apos_atualizado timestamp with time zone, p_apos_id uuid, p_limite integer) from public, anon, authenticated, service_role;
grant execute on function public.florest_listar_empresas(p_apos_atualizado timestamp with time zone, p_apos_id uuid, p_limite integer) to service_role;

-- public.florest_obter_empresa(p_empresa_id uuid)   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function public.florest_obter_empresa(p_empresa_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.florest_obter_empresa(p_empresa_id uuid) to service_role;

-- public.florest_outbox_concluir(p_id bigint, p_ok boolean, p_erro text)   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function public.florest_outbox_concluir(p_id bigint, p_ok boolean, p_erro text) from public, anon, authenticated, service_role;
grant execute on function public.florest_outbox_concluir(p_id bigint, p_ok boolean, p_erro text) to service_role;

-- public.florest_outbox_reenfileirar(p_event_id uuid)   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function public.florest_outbox_reenfileirar(p_event_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.florest_outbox_reenfileirar(p_event_id uuid) to service_role;

-- public.florest_outbox_reservar(p_limite integer, p_lease_segundos integer, p_empresa_id uuid)   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function public.florest_outbox_reservar(p_limite integer, p_lease_segundos integer, p_empresa_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.florest_outbox_reservar(p_limite integer, p_lease_segundos integer, p_empresa_id uuid) to service_role;

-- public.notas_entrada_confirmar(p_nota jsonb)   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.notas_entrada_confirmar(p_nota jsonb) from public, anon, authenticated, service_role;
grant execute on function public.notas_entrada_confirmar(p_nota jsonb) to service_role;
grant execute on function public.notas_entrada_confirmar(p_nota jsonb) to authenticated;

-- public.pdv_atalhos_listar()   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.pdv_atalhos_listar() from public, anon, authenticated, service_role;
grant execute on function public.pdv_atalhos_listar() to service_role;
grant execute on function public.pdv_atalhos_listar() to authenticated;

-- public.pdv_atalhos_salvar(p_atalhos jsonb)   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.pdv_atalhos_salvar(p_atalhos jsonb) from public, anon, authenticated, service_role;
grant execute on function public.pdv_atalhos_salvar(p_atalhos jsonb) to service_role;
grant execute on function public.pdv_atalhos_salvar(p_atalhos jsonb) to authenticated;

-- public.pdv_produtos_consultar(p_ids uuid[], p_gtins text[], p_codigo text, p_busca text, p_limite integer)   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.pdv_produtos_consultar(p_ids uuid[], p_gtins text[], p_codigo text, p_busca text, p_limite integer) from public, anon, authenticated, service_role;
grant execute on function public.pdv_produtos_consultar(p_ids uuid[], p_gtins text[], p_codigo text, p_busca text, p_limite integer) to service_role;
grant execute on function public.pdv_produtos_consultar(p_ids uuid[], p_gtins text[], p_codigo text, p_busca text, p_limite integer) to authenticated;

-- public.registrar_empresa(nome_empresa text, nome_responsavel text)   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.registrar_empresa(nome_empresa text, nome_responsavel text) from public, anon, authenticated, service_role;
grant execute on function public.registrar_empresa(nome_empresa text, nome_responsavel text) to service_role;
grant execute on function public.registrar_empresa(nome_empresa text, nome_responsavel text) to authenticated;

-- public.registrar_empresa_completa(p_dados jsonb)   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.registrar_empresa_completa(p_dados jsonb) from public, anon, authenticated, service_role;
grant execute on function public.registrar_empresa_completa(p_dados jsonb) to service_role;
grant execute on function public.registrar_empresa_completa(p_dados jsonb) to authenticated;

-- public.registrar_venda(p_cliente_id uuid, p_forma_pagamento text, p_itens jsonb)   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.registrar_venda(p_cliente_id uuid, p_forma_pagamento text, p_itens jsonb) from public, anon, authenticated, service_role;
grant execute on function public.registrar_venda(p_cliente_id uuid, p_forma_pagamento text, p_itens jsonb) to service_role;
grant execute on function public.registrar_venda(p_cliente_id uuid, p_forma_pagamento text, p_itens jsonb) to authenticated;

-- public.usuarios_atualizar(p_id uuid, p_nome text, p_ativo boolean, p_permissoes text[])   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.usuarios_atualizar(p_id uuid, p_nome text, p_ativo boolean, p_permissoes text[]) from public, anon, authenticated, service_role;
grant execute on function public.usuarios_atualizar(p_id uuid, p_nome text, p_ativo boolean, p_permissoes text[]) to service_role;
grant execute on function public.usuarios_atualizar(p_id uuid, p_nome text, p_ativo boolean, p_permissoes text[]) to authenticated;

-- public.usuarios_autorizar_alvo(p_ator uuid, p_alvo uuid)   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function public.usuarios_autorizar_alvo(p_ator uuid, p_alvo uuid) from public, anon, authenticated, service_role;
grant execute on function public.usuarios_autorizar_alvo(p_ator uuid, p_alvo uuid) to service_role;

-- public.usuarios_listar()   ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.usuarios_listar() from public, anon, authenticated, service_role;
grant execute on function public.usuarios_listar() to service_role;
grant execute on function public.usuarios_listar() to authenticated;

-- public.usuarios_preparar_criacao(p_ator uuid, p_permissoes text[])   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function public.usuarios_preparar_criacao(p_ator uuid, p_permissoes text[]) from public, anon, authenticated, service_role;
grant execute on function public.usuarios_preparar_criacao(p_ator uuid, p_permissoes text[]) to service_role;

-- public.usuarios_vincular(p_ator uuid, p_user_id uuid, p_nome text, p_permissoes text[])   ACL: {postgres=X/postgres,service_role=X/postgres}
revoke all on function public.usuarios_vincular(p_ator uuid, p_user_id uuid, p_nome text, p_permissoes text[]) from public, anon, authenticated, service_role;
grant execute on function public.usuarios_vincular(p_ator uuid, p_user_id uuid, p_nome text, p_permissoes text[]) to service_role;

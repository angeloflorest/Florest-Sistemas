-- =====================================================================
-- 004_triggers_cron.sql
-- Florest ERP (Supabase / PostgreSQL) — triggers do schema public
-- Gerado exclusivamente a partir do CSV de triggers (nomes, tabelas e
-- definições preservados exatamente). Somente triggers: sem tabelas,
-- funções, políticas RLS, dados ou segredos.
--
-- Pré-requisito: executar antes 001_estrutura_banco.sql e 002_funcoes_banco.sql
-- (as funções de trigger estão no schema private).
--
-- CRON: nenhum agendamento cron foi identificado no banco atual
-- (cron.job não disponível). Nenhum job foi criado neste arquivo.
-- =====================================================================

set search_path = public;

-- =====================================================================
-- TRIGGERS
-- =====================================================================

-- clientes
CREATE TRIGGER clientes_atualizado BEFORE UPDATE ON clientes FOR EACH ROW EXECUTE FUNCTION private.set_atualizado_em();

-- configuracoes_empresa
CREATE TRIGGER configuracoes_empresa_atualizado BEFORE UPDATE ON configuracoes_empresa FOR EACH ROW EXECUTE FUNCTION private.set_atualizado_em();

-- configuracoes_fiscais
CREATE TRIGGER configuracoes_fiscais_protecao BEFORE INSERT OR UPDATE ON configuracoes_fiscais FOR EACH ROW EXECUTE FUNCTION private.proteger_config_fiscal();

-- empresas
CREATE TRIGGER empresas_atualizado BEFORE UPDATE ON empresas FOR EACH ROW EXECUTE FUNCTION private.set_atualizado_em();
CREATE TRIGGER empresas_regras BEFORE INSERT OR UPDATE ON empresas FOR EACH ROW EXECUTE FUNCTION private.empresas_regras();
CREATE TRIGGER florest_empresas_outbox AFTER INSERT ON empresas FOR EACH ROW EXECUTE FUNCTION private.florest_empresas_outbox();

-- fornecedores
CREATE TRIGGER fornecedores_atualizado BEFORE UPDATE ON fornecedores FOR EACH ROW EXECUTE FUNCTION private.set_atualizado_em();

-- pdv_atalhos
CREATE TRIGGER pdv_atalhos_atualizado BEFORE UPDATE ON pdv_atalhos FOR EACH ROW EXECUTE FUNCTION private.set_atualizado_em();

-- produtos
CREATE TRIGGER produtos_atualizado BEFORE UPDATE ON produtos FOR EACH ROW EXECUTE FUNCTION private.set_atualizado_em();
CREATE TRIGGER produtos_proteger_colunas BEFORE UPDATE ON produtos FOR EACH ROW EXECUTE FUNCTION private.produtos_proteger_colunas();

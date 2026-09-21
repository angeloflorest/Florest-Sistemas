-- ==========================================================
-- 004_triggers_cron.sql
-- PetGestor / ERP PETSHOP — Triggers e Cron Jobs (Supabase)
--
-- Reconstrução fiel do estado atual, extraída diretamente do Supabase
-- em produção: 1 trigger + 1 cron job ativo.
--
-- A função executada pelo trigger (private.florest_set_atualizado_em)
-- já está em 002_funcoes_banco.sql e NÃO é recriada aqui.
-- ==========================================================


-- ==========================================================
-- TRIGGER
-- ==========================================================

-- Tabela: florest_assinaturas
-- Evento: UPDATE | Momento: BEFORE
-- Ação:   EXECUTE FUNCTION private.florest_set_atualizado_em()
--
-- Observação: FOR EACH ROW é a única orientação fisicamente válida aqui,
-- já que a função referencia NEW (só existe em triggers de linha) — não
-- capturado como coluna própria pela consulta original, mas decorrente
-- diretamente do corpo da função já registrado em 002_funcoes_banco.sql.

drop trigger if exists florest_assinaturas_atualizado_em on public.florest_assinaturas;

create trigger florest_assinaturas_atualizado_em
before update on public.florest_assinaturas
for each row
execute function private.florest_set_atualizado_em();


-- ==========================================================
-- CRON JOB
-- ==========================================================

-- jobname:  bloquear-vencidos-diario
-- schedule: 0 6 * * *
-- command:  select public.bloquear_vencidos();
-- active:   true
--
-- Remove um agendamento anterior com o mesmo nome, se existir, antes de
-- recriar — evita duplicar o job ao reexecutar este arquivo.

select cron.unschedule(jobid)
from cron.job
where jobname = 'bloquear-vencidos-diario';

select cron.schedule(
  'bloquear-vencidos-diario',
  '0 6 * * *',
  'select public.bloquear_vencidos();'
);

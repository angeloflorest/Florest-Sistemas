-- Desativação autorizada da replicação externa AWS. Não remove dados do ERP.
-- Realtime e infraestrutura gerenciada do Supabase não fazem parte desta remoção.
DO $guard$
BEGIN
 IF EXISTS(SELECT 1 FROM pg_shdepend WHERE refclassid='pg_authid'::regclass AND refobjid=(SELECT oid FROM pg_roles WHERE rolname='florest_reserva_repl') AND deptype='o') THEN
  RAISE EXCEPTION 'O usuário de reserva possui objetos; reavaliar sem excluir dados.';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_publication WHERE pubname='florest_reserva_publication_20261108' AND pg_get_userbyid(pubowner)<>'postgres') THEN
  RAISE EXCEPTION 'Proprietário da publicação de reserva mudou. Reavaliar.';
 END IF;
END $guard$;
DO $disable$
BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='florest_reserva_repl') THEN
  ALTER ROLE florest_reserva_repl NOLOGIN;
  PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='florest_reserva_repl' AND pid<>pg_backend_pid();
 END IF;
END $disable$;
DO $slot$
BEGIN
 IF EXISTS(SELECT 1 FROM pg_replication_slots WHERE slot_name='florest_reserva_slot_20261108') THEN
  PERFORM pg_drop_replication_slot('florest_reserva_slot_20261108');
 END IF;
END $slot$;
DROP PUBLICATION IF EXISTS florest_reserva_publication_20261108;
DO $revoke$
DECLARE obj record;
BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='florest_reserva_repl') THEN
  REVOKE pg_read_all_data FROM florest_reserva_repl;
  -- Revoga somente concessões explícitas ao usuário exclusivo da reserva.
  FOR obj IN SELECT n.nspname,c.relname,c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE EXISTS(SELECT 1 FROM aclexplode(c.relacl) a WHERE a.grantee=(SELECT oid FROM pg_roles WHERE rolname='florest_reserva_repl')) LOOP
   EXECUTE format('REVOKE ALL PRIVILEGES ON %s %I.%I FROM florest_reserva_repl',CASE WHEN obj.relkind='S' THEN 'SEQUENCE' ELSE 'TABLE' END,obj.nspname,obj.relname);
  END LOOP;
  FOR obj IN SELECT nspname FROM pg_namespace WHERE EXISTS(SELECT 1 FROM aclexplode(nspacl) a WHERE a.grantee=(SELECT oid FROM pg_roles WHERE rolname='florest_reserva_repl')) LOOP
   EXECUTE format('REVOKE ALL PRIVILEGES ON SCHEMA %I FROM florest_reserva_repl',obj.nspname);
  END LOOP;
  DROP ROLE florest_reserva_repl;
 END IF;
END $revoke$;

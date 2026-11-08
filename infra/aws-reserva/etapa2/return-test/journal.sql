BEGIN;
CREATE SCHEMA IF NOT EXISTS contingencia_journal;
REVOKE ALL ON SCHEMA contingencia_journal FROM PUBLIC,anon,authenticated,service_role;
CREATE TABLE IF NOT EXISTS contingencia_journal.instance (
 id boolean PRIMARY KEY DEFAULT true CHECK(id), instance_id uuid NOT NULL DEFAULT gen_random_uuid(), purpose text NOT NULL DEFAULT 'AWS sandbox'
);
INSERT INTO contingencia_journal.instance(id)VALUES(true)ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS contingencia_journal.event (
 seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 event_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
 origin uuid NOT NULL, tx bigint NOT NULL,
 schema_name text NOT NULL, table_name text NOT NULL, operation text NOT NULL CHECK(operation IN('INSERT','UPDATE','DELETE')),
 old_row jsonb, new_row jsonb, created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS event_transaction ON contingencia_journal.event(origin,tx,seq);
CREATE TABLE IF NOT EXISTS contingencia_journal.delivery (
 origin uuid NOT NULL,event_id uuid NOT NULL,target uuid NOT NULL,acked_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(origin,event_id,target)
);
CREATE TABLE IF NOT EXISTS contingencia_journal.applied (
 origin uuid NOT NULL,event_id uuid NOT NULL,applied_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(origin,event_id)
);
REVOKE ALL ON ALL TABLES IN SCHEMA contingencia_journal FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA contingencia_journal FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION contingencia_journal.capture()RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $fn$
BEGIN
 IF TG_TABLE_SCHEMA NOT IN('public','private','auth','storage','contingencia_journal')THEN RAISE EXCEPTION 'Unexpected journal schema';END IF;
 INSERT INTO contingencia_journal.event(origin,tx,schema_name,table_name,operation,old_row,new_row)
 SELECT instance_id,txid_current(),TG_TABLE_SCHEMA,TG_TABLE_NAME,TG_OP,
 CASE WHEN TG_OP IN('UPDATE','DELETE')THEN to_jsonb(OLD)ELSE NULL END,
 CASE WHEN TG_OP IN('INSERT','UPDATE')THEN to_jsonb(NEW)ELSE NULL END FROM contingencia_journal.instance WHERE id;
 RETURN CASE WHEN TG_OP='DELETE'THEN OLD ELSE NEW END;
END $fn$;
REVOKE ALL ON FUNCTION contingencia_journal.capture()FROM PUBLIC,anon,authenticated,service_role;
DO $block$ DECLARE t record;BEGIN
 IF current_database()<>'florest_backend_teste_20261108'THEN RAISE EXCEPTION 'Only the isolated AWS test database is permitted';END IF;
 FOR t IN SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN('public','private','auth','storage')AND c.relkind IN('r','p')AND NOT c.relispartition LOOP
  IF NOT EXISTS(SELECT FROM pg_trigger WHERE tgrelid=format('%I.%I',t.nspname,t.relname)::regclass AND tgname='florest_sandbox_journal')THEN
   EXECUTE format('CREATE TRIGGER florest_sandbox_journal AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION contingencia_journal.capture()',t.nspname,t.relname);
  END IF;
 END LOOP;
END $block$;
COMMIT;

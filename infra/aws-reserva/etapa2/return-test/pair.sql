BEGIN;
SET LOCAL lock_timeout='3s';
DO $$BEGIN IF current_database()NOT IN('florest_backend_teste_20261108','florest_retorno_teste_20261108')THEN RAISE EXCEPTION 'Sandbox databases only';END IF;END$$;
CREATE TABLE IF NOT EXISTS contingencia_journal.writer_control(id boolean PRIMARY KEY DEFAULT true CHECK(id),writable boolean NOT NULL DEFAULT false);
INSERT INTO contingencia_journal.writer_control(id,writable)VALUES(true,current_database()='florest_backend_teste_20261108')ON CONFLICT DO NOTHING;
REVOKE ALL ON contingencia_journal.writer_control FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION contingencia_journal.require_writer()RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $fn$
BEGIN
 IF TG_OP='TRUNCATE'THEN RAISE EXCEPTION USING ERRCODE='0A000',MESSAGE='Limpeza integral bloqueada no laboratório; as alterações devem passar pelo diário.';END IF;
 PERFORM 1 FROM contingencia_journal.writer_control WHERE id AND writable FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Banco de teste em espera. Aguarde a troca e consulte o histórico antes de repetir uma operação.';END IF;
 RETURN CASE WHEN TG_OP='DELETE'THEN OLD ELSE NEW END;
END $fn$;
REVOKE ALL ON FUNCTION contingencia_journal.require_writer()FROM PUBLIC,anon,authenticated,service_role;
DO $block$ DECLARE t record;BEGIN
 FOR t IN SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN('public','private','storage')AND c.relkind IN('r','p')AND NOT c.relispartition LOOP
  IF NOT EXISTS(SELECT FROM pg_trigger WHERE tgrelid=format('%I.%I',t.nspname,t.relname)::regclass AND tgname='florest_sandbox_writer')THEN EXECUTE format('CREATE TRIGGER florest_sandbox_writer BEFORE INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION contingencia_journal.require_writer()',t.nspname,t.relname);END IF;
  IF NOT EXISTS(SELECT FROM pg_trigger WHERE tgrelid=format('%I.%I',t.nspname,t.relname)::regclass AND tgname='florest_sandbox_no_truncate')THEN EXECUTE format('CREATE TRIGGER florest_sandbox_no_truncate BEFORE TRUNCATE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION contingencia_journal.require_writer()',t.nspname,t.relname);END IF;
 END LOOP;
END $block$;
CREATE TABLE IF NOT EXISTS contingencia_journal.operation(
 id uuid NOT NULL,actor uuid NOT NULL,request_hash text NOT NULL,response jsonb,created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(id,actor)
);
REVOKE ALL ON contingencia_journal.operation FROM PUBLIC,anon,authenticated,service_role;
DO $$BEGIN IF NOT EXISTS(SELECT FROM pg_trigger WHERE tgrelid='contingencia_journal.operation'::regclass AND tgname='operation_journal')THEN CREATE TRIGGER operation_journal AFTER INSERT OR UPDATE OR DELETE ON contingencia_journal.operation FOR EACH ROW EXECUTE FUNCTION contingencia_journal.capture();END IF;END$$;
CREATE OR REPLACE FUNCTION public.florest_sandbox_registrar_venda_mista(p_operacao uuid,p_args jsonb)RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $fn$
DECLARE v_actor uuid:=auth.uid();v_hash text;v_op contingencia_journal.operation%ROWTYPE;v_response jsonb;
BEGIN
 IF current_database()NOT IN('florest_backend_teste_20261108','florest_retorno_teste_20261108')OR v_actor IS NULL THEN RAISE EXCEPTION 'Only authenticated sandbox sales';END IF;
 IF NOT EXISTS(SELECT FROM pg_proc WHERE oid='public.registrar_venda_mista(uuid,jsonb,jsonb,text)'::regprocedure AND prosecdef AND has_function_privilege('authenticated',oid,'EXECUTE'))THEN RAISE EXCEPTION 'Original sale permissions differ; sandbox wrapper refused';END IF;
 PERFORM 1 FROM contingencia_journal.writer_control WHERE id AND writable FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Troca do banco de teste em andamento. Consulte o histórico antes de repetir.';END IF;
 v_hash:=encode(extensions.digest(p_args::text,'sha256'),'hex');
 INSERT INTO contingencia_journal.operation(id,actor,request_hash)VALUES(p_operacao,v_actor,v_hash)ON CONFLICT DO NOTHING;
 SELECT * INTO STRICT v_op FROM contingencia_journal.operation WHERE id=p_operacao AND actor=v_actor FOR UPDATE;
 IF v_op.request_hash<>v_hash THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='A tentativa anterior tem outros dados. Consulte o histórico antes de alterar a venda.';END IF;
 IF v_op.response IS NOT NULL THEN RETURN v_op.response;END IF;
 SELECT jsonb_agg(to_jsonb(x))INTO v_response FROM public.registrar_venda_mista(p_cliente_id:=(p_args->>'p_cliente_id')::uuid,p_itens:=p_args->'p_itens',p_pagamentos:=p_args->'p_pagamentos',p_cpf_nota:=p_args->>'p_cpf_nota')x;
 IF v_response IS NULL OR jsonb_array_length(v_response)<>1 OR v_response->0->>'venda_id'IS NULL THEN RAISE EXCEPTION 'Sale response not confirmed';END IF;
 UPDATE contingencia_journal.operation SET response=v_response WHERE id=p_operacao AND actor=v_actor;
 RETURN v_response;
END $fn$;
REVOKE ALL ON FUNCTION public.florest_sandbox_registrar_venda_mista(uuid,jsonb)FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.florest_sandbox_registrar_venda_mista(uuid,jsonb)TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;

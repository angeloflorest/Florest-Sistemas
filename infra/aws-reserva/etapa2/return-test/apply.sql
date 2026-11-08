BEGIN;
DO $$BEGIN IF current_database()NOT IN('florest_backend_teste_20261108','florest_retorno_teste_20261108')THEN RAISE EXCEPTION 'Only isolated return-test target permitted';END IF;END$$;
CREATE OR REPLACE FUNCTION contingencia_journal.apply(p_event jsonb)RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $fn$
DECLARE
 v_schema text:=p_event->>'schema_name';v_table text:=p_event->>'table_name';v_op text:=p_event->>'operation';
 v_old jsonb:=p_event->'old_row';v_new jsonb:=p_event->'new_row';v_origin uuid:=(p_event->>'origin')::uuid;v_event uuid:=(p_event->>'event_id')::uuid;
 v_relation regclass;v_pk text[];v_columns text[];v_condition text;v_col_list text;v_set_list text;v_current jsonb;v_key jsonb;v_count bigint;v_previous_mode text;
BEGIN
 IF current_database()NOT IN('florest_backend_teste_20261108','florest_retorno_teste_20261108')THEN RAISE EXCEPTION 'Return test only';END IF;
 IF EXISTS(SELECT FROM contingencia_journal.applied WHERE origin=v_origin AND event_id=v_event)THEN RETURN false;END IF;
 IF v_schema NOT IN('public','private','auth','storage','contingencia_journal')OR v_op NOT IN('INSERT','UPDATE','DELETE')THEN RAISE EXCEPTION 'Unexpected change';END IF;
 IF v_schema='contingencia_journal'AND v_table NOT IN('fixture','operation')THEN RAISE EXCEPTION 'Metadata writes are not replayed';END IF;
 v_relation:=to_regclass(format('%I.%I',v_schema,v_table));IF v_relation IS NULL THEN RAISE EXCEPTION 'Target relation missing';END IF;
 SELECT array_agg(a.attname ORDER BY k.ord)INTO v_pk FROM pg_index i CROSS JOIN LATERAL unnest(i.indkey)WITH ORDINALITY k(attnum,ord)JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum WHERE i.indrelid=v_relation AND i.indisprimary;
 IF v_pk IS NULL THEN RAISE EXCEPTION 'Primary key required';END IF;
 v_key:=CASE WHEN v_op='INSERT'THEN v_new ELSE v_old END;
 SELECT string_agg(format('t.%1$I IS NOT DISTINCT FROM k.%1$I',x),' AND ')INTO v_condition FROM unnest(v_pk)x;
 EXECUTE format('SELECT to_jsonb(t) FROM %s t CROSS JOIN jsonb_populate_record(NULL::%s,$1) k WHERE %s FOR UPDATE OF t',v_relation,v_relation,v_condition)INTO v_current USING v_key;
 IF v_op='INSERT'AND v_current IS NOT NULL THEN
  IF v_current=v_new THEN INSERT INTO contingencia_journal.applied(origin,event_id)VALUES(v_origin,v_event);RETURN false;ELSE RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Insert conflict';END IF;
 END IF;
 IF v_op IN('UPDATE','DELETE')AND(v_current IS NULL OR v_current IS DISTINCT FROM v_old)THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Before-image conflict';END IF;
 SELECT array_agg(a.attname ORDER BY a.attnum)INTO v_columns FROM pg_attribute a WHERE a.attrelid=v_relation AND a.attnum>0 AND NOT a.attisdropped AND a.attgenerated='' AND(v_new?a.attname);
 IF v_op IN('INSERT','UPDATE')AND EXISTS(SELECT FROM jsonb_object_keys(v_new)k WHERE NOT EXISTS(SELECT FROM pg_attribute a WHERE a.attrelid=v_relation AND a.attnum>0 AND NOT a.attisdropped AND a.attname=k))THEN RAISE EXCEPTION 'Schema differs';END IF;
 SELECT string_agg(format('%I',x),','),string_agg(format('%1$I=r.%1$I',x),',')INTO v_col_list,v_set_list FROM unnest(v_columns)x;
 v_previous_mode:=current_setting('session_replication_role');PERFORM set_config('session_replication_role','replica',true);
 IF v_op='INSERT'THEN
  EXECUTE format('INSERT INTO %s (%s) OVERRIDING SYSTEM VALUE SELECT %s FROM jsonb_populate_record(NULL::%s,$1) r',v_relation,v_col_list,v_col_list,v_relation)USING v_new;
 ELSIF v_op='UPDATE'THEN
  EXECUTE format('UPDATE %s t SET %s FROM jsonb_populate_record(NULL::%s,$1) r CROSS JOIN jsonb_populate_record(NULL::%s,$2) k WHERE %s',v_relation,v_set_list,v_relation,v_relation,v_condition)USING v_new,v_old;
 ELSE
  EXECUTE format('DELETE FROM %s t USING jsonb_populate_record(NULL::%s,$1) k WHERE %s',v_relation,v_relation,v_condition)USING v_old;
 END IF;
 GET DIAGNOSTICS v_count=ROW_COUNT;
 IF v_count<>1 THEN RAISE EXCEPTION 'Expected exactly one changed row';END IF;
 PERFORM set_config('session_replication_role',v_previous_mode,true);
 INSERT INTO contingencia_journal.applied(origin,event_id)VALUES(v_origin,v_event);
 RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION contingencia_journal.apply(jsonb)FROM PUBLIC,anon,authenticated,service_role;
COMMIT;

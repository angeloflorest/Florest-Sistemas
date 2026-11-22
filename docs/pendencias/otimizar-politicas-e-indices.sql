-- Somente avaliação de auth.uid e cópias comprovadamente idênticas de índices.
-- Nenhuma regra, papel, coluna, venda ou log é removido.
SET LOCAL lock_timeout='2s';
DO $policies$ DECLARE p record; q text; c text; stmt text; n integer:=0; BEGIN
 IF (SELECT provolatile FROM pg_proc WHERE oid='auth.uid()'::regprocedure)<>'s' THEN
  RAISE EXCEPTION 'auth.uid deixou de ser STABLE; não alterar avaliação.';
 END IF;
 FOR p IN SELECT * FROM pg_policies WHERE schemaname='public' AND policyname IN
 ('pdv_movel_caixas_ler','fiscal_contadores_sel','fiscal_contadores_ins','fiscal_contadores_upd','fiscal_pacotes_xml_sel') LOOP
 q:=replace(p.qual,'auth.uid()','(SELECT auth.uid())');
 c:=replace(p.with_check,'auth.uid()','(SELECT auth.uid())');
 stmt:=format('ALTER POLICY %I ON %I.%I',p.policyname,p.schemaname,p.tablename);
 IF q IS NOT NULL THEN stmt:=stmt||' USING ('||q||')'; END IF;
 IF c IS NOT NULL THEN stmt:=stmt||' WITH CHECK ('||c||')'; END IF;
 EXECUTE stmt;
 n:=n+1;
 END LOOP;
 IF n<>5 THEN RAISE EXCEPTION 'As cinco políticas esperadas não estão presentes.'; END IF;
END $policies$;
DO $indexes$ DECLARE pair text[]; a record; b record; BEGIN
 FOREACH pair SLICE 1 IN ARRAY ARRAY[
 ARRAY['public.uq_empresa_modulos_empresa_modulo','public.empresa_modulos_empresa_modulo_key'],
 ARRAY['public.idx_empresas_status_conta','public.empresas_status_idx']] LOOP
 SELECT indrelid,indkey,indclass,indcollation,indoption,indexprs,indpred,indisunique,indisvalid,indisready INTO a FROM pg_index WHERE indexrelid=pair[1]::regclass;
 SELECT indrelid,indkey,indclass,indcollation,indoption,indexprs,indpred,indisunique,indisvalid,indisready INTO b FROM pg_index WHERE indexrelid=pair[2]::regclass;
 IF a IS DISTINCT FROM b OR a.indisvalid IS DISTINCT FROM true OR a.indisready IS DISTINCT FROM true THEN
  RAISE EXCEPTION 'Índices não são cópias válidas idênticas: %',pair;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_constraint WHERE conindid=pair[1]::regclass) THEN
  RAISE EXCEPTION 'A cópia está vinculada a uma restrição; não remover.';
 END IF;
 EXECUTE format('DROP INDEX %s',pair[1]::regclass);
 END LOOP;
END $indexes$;

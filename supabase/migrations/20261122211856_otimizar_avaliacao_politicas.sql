-- Avalia auth.uid uma vez por consulta, preservando todas as condições das cinco políticas.
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

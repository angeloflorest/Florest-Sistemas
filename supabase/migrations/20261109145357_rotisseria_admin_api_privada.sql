BEGIN;
-- Privileged authorization stays private; the exposed endpoint runs as its caller.
CREATE FUNCTION private.admin_listar_rotisseria_modulos()
RETURNS TABLE(empresa_id uuid,ativo boolean) LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.florest_eh_admin() THEN RAISE EXCEPTION 'Acesso negado.' USING errcode='42501'; END IF;
 RETURN QUERY SELECT m.empresa_id,m.ativo FROM public.empresa_modulos m WHERE m.modulo='rotisseria';
END $$;
REVOKE ALL ON FUNCTION private.admin_listar_rotisseria_modulos() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.admin_listar_rotisseria_modulos() TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_listar_rotisseria_modulos()
RETURNS TABLE(empresa_id uuid,ativo boolean) LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM private.admin_listar_rotisseria_modulos();
$$;
REVOKE ALL ON FUNCTION public.admin_listar_rotisseria_modulos() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_listar_rotisseria_modulos() TO authenticated;
COMMIT;

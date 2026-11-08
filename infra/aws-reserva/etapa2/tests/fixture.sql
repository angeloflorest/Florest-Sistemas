CREATE ROLE florest_data_owner NOLOGIN;
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN INHERIT;
CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD '__REST_PASSWORD__';
CREATE ROLE supabase_auth_admin LOGIN NOINHERIT PASSWORD '__AUTH_PASSWORD__';
GRANT florest_data_owner TO postgres;
GRANT florest_data_owner TO service_role;
GRANT anon,authenticated,service_role TO authenticator;
CREATE SCHEMA auth AUTHORIZATION supabase_auth_admin;
CREATE SCHEMA extensions;
CREATE SCHEMA private AUTHORIZATION florest_data_owner;
CREATE EXTENSION pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION "uuid-ossp" WITH SCHEMA extensions;
ALTER ROLE supabase_auth_admin SET search_path=auth,public,extensions;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT nullif(coalesce(current_setting('request.jwt.claim.sub',true),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub'),'')::uuid
$$;
ALTER FUNCTION auth.uid() OWNER TO supabase_auth_admin;
GRANT USAGE ON SCHEMA auth,extensions TO anon,authenticated,service_role,supabase_auth_admin;
GRANT USAGE ON SCHEMA public,private TO authenticated,service_role;
CREATE TABLE public.empresas(id uuid PRIMARY KEY,nome text NOT NULL,email text NOT NULL,status_conta text NOT NULL,bloqueado boolean NOT NULL DEFAULT false,vencimento date);
CREATE UNIQUE INDEX empresas_email_ci_uk ON public.empresas(lower(email));
CREATE TABLE public.perfis(id uuid PRIMARY KEY,empresa_id uuid REFERENCES public.empresas(id),nome text NOT NULL,usuario text NOT NULL,papel text NOT NULL,permissoes jsonb NOT NULL DEFAULT '[]',ativo boolean NOT NULL DEFAULT true,tipo_acesso text NOT NULL DEFAULT 'erp');
CREATE UNIQUE INDEX perfis_usuario_empresa_ci_uk ON public.perfis(empresa_id,lower(usuario));
CREATE TABLE public.vendas(id uuid PRIMARY KEY,empresa_id uuid NOT NULL REFERENCES public.empresas(id),numero_venda bigint NOT NULL,total numeric(12,2) NOT NULL);
ALTER TABLE public.empresas OWNER TO florest_data_owner;
ALTER TABLE public.perfis OWNER TO florest_data_owner;
ALTER TABLE public.vendas OWNER TO florest_data_owner;
CREATE FUNCTION private.empresa_id_ativa() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT p.empresa_id FROM public.perfis p JOIN public.empresas e ON e.id=p.empresa_id
 WHERE p.id=(SELECT auth.uid()) AND p.ativo AND e.status_conta='aprovado' AND NOT e.bloqueado
$$;
ALTER FUNCTION private.empresa_id_ativa() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.empresa_id_ativa() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.empresa_id_ativa() TO authenticated;
ALTER TABLE public.empresas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.perfis ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendas ENABLE ROW LEVEL SECURITY;
CREATE POLICY empresas_empresa ON public.empresas FOR SELECT TO authenticated USING(id=private.empresa_id_ativa());
CREATE POLICY perfis_empresa ON public.perfis FOR SELECT TO authenticated USING(empresa_id=private.empresa_id_ativa());
CREATE POLICY vendas_empresa ON public.vendas FOR SELECT TO authenticated USING(empresa_id=private.empresa_id_ativa());
GRANT SELECT ON public.empresas,public.perfis,public.vendas TO authenticated;
CREATE FUNCTION public.contexto() RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT jsonb_build_object('empresa_id',private.empresa_id_ativa()) $$;
REVOKE ALL ON FUNCTION public.contexto() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.contexto() TO authenticated;

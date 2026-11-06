-- Banco LOCAL descartável. Estrutura baseada no catálogo; somente dados sintéticos.
create schema auth;create schema private;create schema vault;
create role anon;create role authenticated;create role service_role bypassrls;
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create table empresas(id uuid primary key,status_conta text default 'aprovado',bloqueado boolean default false);
create table perfis(id uuid primary key,empresa_id uuid,ativo boolean default true,permissoes text[]);
create table clientes(id uuid primary key,empresa_id uuid,nome text,cpf text,logradouro text,numero text,bairro text,cidade text,uf text,cep text);
create table public.configuracoes_fiscais(id uuid,empresa_id uuid,razao_social text,nome_fantasia text,cnpj text,telefone text,regime_tributario text,crt text,inscricao_estadual text,inscricao_municipal text,cep text,municipio text,uf text,codigo_ibge text,endereco text,numero text,complemento text,bairro text,nfce_serie text,nfce_ambiente text,nfce_csc text,nfce_id_csc text,nfce_versao_qrcode text,nfse_inscricao_municipal text,nfse_municipio text,certificado_status text,certificado_razao_social text,certificado_cnpj text,certificado_validade date,certificado_certificadora text,certificado_numero_serie text,dadosjah_usuario_criado boolean,emitente_registrado boolean,criado_em timestamp with time zone,atualizado_em timestamp with time zone,status_configuracao text,emite_nota_fiscal boolean);
create table public.documentos_fiscais(id uuid,empresa_id uuid,venda_id uuid,tipo_documento text,status text,numero text,serie text,valor numeric,chave_acesso text,protocolo text,ambiente text,mensagem_rejeicao text,pdf_conteudo text,pdf_url text,xml_conteudo text,xml_url text,provedor_id text,retorno_provedor jsonb,created_at timestamp with time zone,atualizado_em timestamp with time zone,id_dfe text,tp_ambiente text,dh_emissao timestamp with time zone,dh_recebimento timestamp with time zone,c_stat text,situation text,situation_dfe text,referencia_api text,referencia_externa text);
create table public.produtos(id uuid,empresa_id uuid,codigo text,nome text,gtin text,unidade_comercial text,preco_venda numeric,preco_custo numeric,quantidade_estoque numeric,estoque_minimo numeric,tipo_fiscal text,ncm text,cest text,cfop text,origem_mercadoria text,cst_csosn text,aliquota_icms numeric,cst_pis text,cst_cofins text,codigo_servico text,codigo_tributacao_municipal text,municipio_incidencia text,iss numeric,criado_em timestamp with time zone,atualizado_em timestamp with time zone,categoria text,vendavel_pacote boolean,pacote_qtd integer,pacote_preco numeric,venda_granel boolean,ativo boolean,inativado_em timestamp with time zone,inativado_por uuid,inativacao_motivo text,reativado_em timestamp with time zone,reativado_por uuid,referencia text);
create table public.vendas(id uuid,empresa_id uuid,numero_venda bigint,cliente_id uuid,forma_pagamento text,total numeric,criado_por uuid,criado_em timestamp with time zone,tipo text,cancelada_em timestamp with time zone,cancelada_por uuid,motivo_cancelamento text,cpf_nota text,caixa_id uuid,pdv_prazo_chave uuid,pdv_prazo_pedido jsonb,gastronomia_canal text,pdv_movel_caixa_id uuid,pdv_movel_ajustes jsonb);
create table public.itens_venda(id bigint,empresa_id uuid,venda_id uuid,produto_id uuid,quantidade numeric,preco_unitario numeric,subtotal numeric,pacote_cliente_id uuid);
alter table vendas add unique(empresa_id,id);
create table contadores_fiscais(empresa_id uuid,tipo_documento text,serie text,ultimo_numero bigint,atualizado_em timestamptz,unique(empresa_id,tipo_documento,serie));
create table fiscal_credenciais(empresa_id uuid,dadosjah_email text,dadosjah_password_secret_id uuid,dadosjah_token text,dadosjah_token_expires_at timestamptz);
create table vault.decrypted_secrets(id uuid,decrypted_secret text);
create function private.perm_alguma(text[]) returns boolean language sql stable security definer set search_path='' as $$select coalesce((select permissoes && $1 from public.perfis where id=auth.uid()),false)$$;
CREATE OR REPLACE FUNCTION private.empresa_id_ativa()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select e.id
    from public.perfis p
    join public.empresas e on e.id = p.empresa_id
   where p.id = (select auth.uid())
     and p.ativo
     and e.status_conta = 'aprovado'
     and e.bloqueado = false;
$function$
;
CREATE OR REPLACE FUNCTION private.exigir_empresa_ativa()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid    uuid := (select auth.uid());
  v_emp    uuid;
  v_status text;
  v_bloq   boolean;
  v_ativo  boolean;
begin
  if v_uid is null then
    raise exception 'Sessão expirada. Faça login novamente.' using errcode = '28000';
  end if;
  select e.id, e.status_conta, e.bloqueado, p.ativo into v_emp, v_status, v_bloq, v_ativo
    from public.perfis p join public.empresas e on e.id = p.empresa_id
   where p.id = v_uid;
  if v_emp is null then
    raise exception 'Usuário sem empresa vinculada.' using errcode = '42501';
  end if;
  if v_status = 'pendente' then
    raise exception 'Sua conta ainda está em análise.' using errcode = '42501';
  end if;
  if v_status <> 'aprovado' or v_bloq then
    raise exception 'Seu acesso está bloqueado. Entre em contato com seu revendedor.' using errcode = '42501';
  end if;
  if not v_ativo then
    raise exception 'Seu usuário está desativado. Fale com o administrador da empresa.' using errcode = '42501';
  end if;
  return v_emp;
end;
$function$
;
grant usage on schema auth,private to authenticated;grant execute on all functions in schema auth,private to authenticated;

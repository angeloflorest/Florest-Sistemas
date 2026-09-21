-- =====================================================================
-- 001_estrutura_banco.sql
-- Florest ERP (Supabase / PostgreSQL) — estrutura do schema public
-- Gerado exclusivamente a partir dos CSVs de catálogo (colunas, constraints,
-- índices e extensões). Somente estrutura: sem dados, sem funções/RPCs,
-- sem políticas RLS, sem triggers, sem grants e sem conteúdo do Vault.
--
-- Ordem: 1 extensões | 2 tabelas | 3 PRIMARY KEY | 4 UNIQUE | 5 CHECK |
--        6 FOREIGN KEY | 7 índices | 8 DEFAULTs que dependem de função
-- Observações:
--   * Tipos conforme information_schema (precisão/escala de numeric não
--     constam nos CSVs e não foram inventadas).
--   * FOREIGN KEY de perfis.id referencia auth.users (schema auth do Supabase).
--   * ON DELETE SET NULL (coluna) requer PostgreSQL 15+.
--   * Os índices criados por PRIMARY KEY / UNIQUE não são repetidos na
--     seção 7 (já nascem com as constraints).
-- =====================================================================

set search_path = public;

-- =====================================================================
-- 1. EXTENSÕES
-- =====================================================================
create extension if not exists "pgcrypto" with schema extensions;   -- versão no backup: 1.3
create extension if not exists "uuid-ossp" with schema extensions;   -- versão no backup: 1.1
-- Extensões presentes no projeto, gerenciadas pelo Supabase (não são necessárias para a estrutura abaixo):
--   pg_stat_statements 1.11 (schema extensions)
--   supabase_vault 0.3.1 (schema vault)
--   plpgsql 1.0 (schema pg_catalog)

-- =====================================================================
-- 2. TABELAS (colunas, tipos, NULL/NOT NULL, DEFAULT, identity)
-- =====================================================================

create table public.clientes (
  id uuid default gen_random_uuid() not null,
  empresa_id uuid not null,
  nome text not null,
  telefone text,
  email text,
  cpf text,
  cep text,
  logradouro text,
  numero text,
  complemento text,
  bairro text,
  cidade text,
  uf text,
  criado_em timestamp with time zone default now() not null,
  atualizado_em timestamp with time zone default now() not null
);

create table public.configuracoes_empresa (
  empresa_id uuid not null,
  permitir_venda_sem_estoque boolean default false not null,
  atualizado_em timestamp with time zone default now() not null,
  atualizado_por uuid
);

create table public.configuracoes_fiscais (
  id uuid default gen_random_uuid() not null,
  empresa_id uuid not null,
  razao_social text,
  nome_fantasia text,
  cnpj text,
  telefone text,
  regime_tributario text,
  crt text,
  inscricao_estadual text,
  inscricao_municipal text,
  cep text,
  municipio text,
  uf text,
  codigo_ibge text,
  endereco text,
  numero text,
  complemento text,
  bairro text,
  nfce_serie text,
  nfce_ambiente text default 'homologacao'::text not null,
  nfce_csc text,
  nfce_id_csc text,
  nfce_versao_qrcode text,
  nfse_inscricao_municipal text,
  nfse_municipio text,
  certificado_status text default 'nao_configurado'::text not null,
  certificado_razao_social text,
  certificado_cnpj text,
  certificado_validade date,
  certificado_certificadora text,
  certificado_numero_serie text,
  dadosjah_usuario_criado boolean default false not null,
  emitente_registrado boolean default false not null,
  criado_em timestamp with time zone default now() not null,
  atualizado_em timestamp with time zone default now() not null
);

create table public.contadores_fiscais (
  id uuid default gen_random_uuid() not null,
  empresa_id uuid not null,
  tipo_documento text not null,
  serie text not null,
  ultimo_numero integer default 0 not null,
  atualizado_em timestamp with time zone default now() not null
);

create table public.contadores_venda (
  empresa_id uuid not null,
  ultimo_numero integer default 0 not null
);

create table public.despesas (
  id uuid default gen_random_uuid() not null,
  empresa_id uuid not null,
  descricao text not null,
  categoria text,
  valor numeric not null,
  data date default ((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date not null,
  vencimento date,
  status text default 'pendente'::text not null,
  pago_em date,
  nota_entrada_id uuid,
  criado_em timestamp with time zone default now() not null
);

create table public.documentos_fiscais (
  id uuid default gen_random_uuid() not null,
  empresa_id uuid not null,
  venda_id uuid not null,
  tipo_documento text not null,
  status text default 'nao_emitida'::text not null,
  numero text,
  serie text,
  valor numeric default 0 not null,
  chave_acesso text,
  protocolo text,
  ambiente text,
  mensagem_rejeicao text,
  pdf_conteudo text,
  pdf_url text,
  xml_conteudo text,
  xml_url text,
  provedor_id text,
  retorno_provedor jsonb,
  created_at timestamp with time zone default now() not null,
  atualizado_em timestamp with time zone default now() not null
);

create table public.documentos_fiscais_eventos (
  id bigint generated always as identity not null,
  empresa_id uuid not null,
  documento_fiscal_id uuid not null,
  tipo_evento text not null,
  status text,
  mensagem text,
  payload jsonb,
  created_at timestamp with time zone default now() not null
);

create table public.empresas (
  id uuid default gen_random_uuid() not null,
  nome text not null,
  status_conta text default 'pendente'::text not null,
  bloqueado boolean default true not null,
  vencimento date,
  assinatura_id uuid,
  aprovado_em timestamp with time zone,
  aprovado_por text,
  bloqueado_em timestamp with time zone,
  bloqueado_motivo text,
  criado_em timestamp with time zone default now() not null,
  atualizado_em timestamp with time zone default now() not null,
  florest_revisao bigint default 0 not null,
  florest_sync_em timestamp with time zone,
  razao_social text,
  cnpj text,
  telefone text,
  cep text,
  logradouro text,
  numero text,
  complemento text,
  bairro text,
  cidade text,
  uf text
);

create table public.fiscal_credenciais (
  empresa_id uuid not null,
  certificado_ref text,
  certificado_senha_ref text,
  dadosjah_ref text,
  atualizado_em timestamp with time zone default now() not null
);

create table public.florest_outbox (
  id bigint generated always as identity not null,
  event_id uuid default gen_random_uuid() not null,
  tipo text not null,
  empresa_id uuid not null,
  status text default 'pendente'::text not null,
  tentativas integer default 0 not null,
  proxima_tentativa_em timestamp with time zone default now() not null,
  reservado_ate timestamp with time zone,
  ultimo_erro text,
  criado_em timestamp with time zone default now() not null,
  enviado_em timestamp with time zone
);

create table public.fornecedores (
  id uuid default gen_random_uuid() not null,
  empresa_id uuid not null,
  cnpj text not null,
  razao_social text not null,
  nome_fantasia text,
  inscricao_estadual text,
  telefone text,
  cep text,
  endereco text,
  numero text,
  complemento text,
  bairro text,
  municipio text,
  uf text,
  criado_em timestamp with time zone default now() not null,
  atualizado_em timestamp with time zone default now() not null
);

create table public.itens_venda (
  id bigint generated always as identity not null,
  empresa_id uuid not null,
  venda_id uuid not null,
  produto_id uuid not null,
  quantidade numeric not null,
  preco_unitario numeric not null,
  subtotal numeric
);

create table public.notas_entrada (
  id uuid default gen_random_uuid() not null,
  empresa_id uuid not null,
  fornecedor_id uuid not null,
  chave_acesso text not null,
  numero text,
  serie text,
  data_emissao date,
  data_entrada date default ((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date not null,
  valor_produtos numeric default 0 not null,
  valor_desconto numeric default 0 not null,
  valor_frete numeric default 0 not null,
  valor_outras_despesas numeric default 0 not null,
  valor_total numeric not null,
  forma_pagamento text not null,
  status text default 'confirmada'::text not null,
  xml_conteudo text,
  criado_por uuid,
  criado_em timestamp with time zone default now() not null
);

create table public.notas_entrada_itens (
  id bigint generated always as identity not null,
  empresa_id uuid not null,
  nota_entrada_id uuid not null,
  produto_id uuid not null,
  codigo_fornecedor text,
  gtin text,
  descricao text not null,
  ncm text,
  cest text,
  cfop text,
  unidade_comercial text,
  quantidade numeric not null,
  valor_unitario numeric default 0 not null,
  valor_total numeric default 0 not null,
  origem_mercadoria text,
  cst_csosn text,
  cst_pis text,
  cst_cofins text,
  quantidade_estoque_anterior numeric not null,
  quantidade_estoque_nova numeric not null
);

create table public.pdv_atalhos (
  id uuid default gen_random_uuid() not null,
  empresa_id uuid not null,
  nome text not null,
  imagem text,
  ordem integer default 0 not null,
  criado_em timestamp with time zone default now() not null,
  atualizado_em timestamp with time zone default now() not null,
  atualizado_por uuid
);

create table public.pdv_atalhos_produtos (
  atalho_id uuid not null,
  empresa_id uuid not null,
  produto_id uuid not null,
  ordem integer default 0 not null,
  imagem text
);

create table public.perfis (
  id uuid not null,
  empresa_id uuid not null,
  nome text not null,
  criado_em timestamp with time zone default now() not null,
  papel text default 'proprietario'::text not null,
  permissoes text[] default '{}'::text[] not null,
  ativo boolean default true not null,
  criado_por uuid
);

create table public.produtos (
  id uuid default gen_random_uuid() not null,
  empresa_id uuid not null,
  codigo text,
  nome text not null,
  gtin text,
  unidade_comercial text,
  preco_venda numeric not null,
  preco_custo numeric,
  quantidade_estoque numeric default 0 not null,
  estoque_minimo numeric,
  tipo_fiscal text default 'produto'::text not null,
  ncm text,
  cest text,
  cfop text,
  origem_mercadoria text,
  cst_csosn text,
  aliquota_icms numeric,
  cst_pis text,
  cst_cofins text,
  codigo_servico text,
  codigo_tributacao_municipal text,
  municipio_incidencia text,
  iss numeric,
  criado_em timestamp with time zone default now() not null,
  atualizado_em timestamp with time zone default now() not null,
  categoria text
);

create table public.vendas (
  id uuid default gen_random_uuid() not null,
  empresa_id uuid not null,
  numero_venda integer not null,
  cliente_id uuid,
  forma_pagamento text not null,
  total numeric not null,
  criado_por uuid,
  criado_em timestamp with time zone default now() not null
);

-- =====================================================================
-- 3. PRIMARY KEY
-- =====================================================================
alter table public.clientes add constraint clientes_pkey
  PRIMARY KEY (id);
alter table public.configuracoes_empresa add constraint configuracoes_empresa_pkey
  PRIMARY KEY (empresa_id);
alter table public.configuracoes_fiscais add constraint configuracoes_fiscais_pkey
  PRIMARY KEY (id);
alter table public.contadores_fiscais add constraint contadores_fiscais_pkey
  PRIMARY KEY (id);
alter table public.contadores_venda add constraint contadores_venda_pkey
  PRIMARY KEY (empresa_id);
alter table public.despesas add constraint despesas_pkey
  PRIMARY KEY (id);
alter table public.documentos_fiscais add constraint documentos_fiscais_pkey
  PRIMARY KEY (id);
alter table public.documentos_fiscais_eventos add constraint documentos_fiscais_eventos_pkey
  PRIMARY KEY (id);
alter table public.empresas add constraint empresas_pkey
  PRIMARY KEY (id);
alter table public.fiscal_credenciais add constraint fiscal_credenciais_pkey
  PRIMARY KEY (empresa_id);
alter table public.florest_outbox add constraint florest_outbox_pkey
  PRIMARY KEY (id);
alter table public.fornecedores add constraint fornecedores_pkey
  PRIMARY KEY (id);
alter table public.itens_venda add constraint itens_venda_pkey
  PRIMARY KEY (id);
alter table public.notas_entrada add constraint notas_entrada_pkey
  PRIMARY KEY (id);
alter table public.notas_entrada_itens add constraint notas_entrada_itens_pkey
  PRIMARY KEY (id);
alter table public.pdv_atalhos add constraint pdv_atalhos_pkey
  PRIMARY KEY (id);
alter table public.pdv_atalhos_produtos add constraint pdv_atalhos_produtos_pkey
  PRIMARY KEY (atalho_id, produto_id);
alter table public.perfis add constraint perfis_pkey
  PRIMARY KEY (id);
alter table public.produtos add constraint produtos_pkey
  PRIMARY KEY (id);
alter table public.vendas add constraint vendas_pkey
  PRIMARY KEY (id);

-- =====================================================================
-- 4. UNIQUE
-- =====================================================================
alter table public.clientes add constraint clientes_empresa_id_id_key
  UNIQUE (empresa_id, id);
alter table public.configuracoes_fiscais add constraint configuracoes_fiscais_empresa_id_key
  UNIQUE (empresa_id);
alter table public.contadores_fiscais add constraint contadores_fiscais_empresa_id_tipo_documento_serie_key
  UNIQUE (empresa_id, tipo_documento, serie);
alter table public.documentos_fiscais add constraint documentos_fiscais_empresa_id_id_key
  UNIQUE (empresa_id, id);
alter table public.florest_outbox add constraint florest_outbox_event_id_key
  UNIQUE (event_id);
alter table public.fornecedores add constraint fornecedores_empresa_id_cnpj_key
  UNIQUE (empresa_id, cnpj);
alter table public.fornecedores add constraint fornecedores_empresa_id_id_key
  UNIQUE (empresa_id, id);
alter table public.notas_entrada add constraint notas_entrada_empresa_id_chave_acesso_key
  UNIQUE (empresa_id, chave_acesso);
alter table public.notas_entrada add constraint notas_entrada_empresa_id_id_key
  UNIQUE (empresa_id, id);
alter table public.pdv_atalhos add constraint pdv_atalhos_empresa_id_id_key
  UNIQUE (empresa_id, id);
alter table public.produtos add constraint produtos_empresa_id_id_key
  UNIQUE (empresa_id, id);
alter table public.vendas add constraint vendas_empresa_id_id_key
  UNIQUE (empresa_id, id);
alter table public.vendas add constraint vendas_empresa_id_numero_venda_key
  UNIQUE (empresa_id, numero_venda);

-- =====================================================================
-- 5. CHECK
-- =====================================================================
alter table public.clientes add constraint clientes_nome_check
  CHECK ((length(btrim(nome)) > 0));
alter table public.configuracoes_fiscais add constraint configuracoes_fiscais_nfce_ambiente_check
  CHECK ((nfce_ambiente = ANY (ARRAY['homologacao'::text, 'producao'::text])));
alter table public.contadores_fiscais add constraint contadores_fiscais_tipo_documento_check
  CHECK ((tipo_documento = ANY (ARRAY['nfce'::text, 'nfse'::text, 'nfe'::text])));
alter table public.contadores_fiscais add constraint contadores_fiscais_ultimo_numero_check
  CHECK ((ultimo_numero >= 0));
alter table public.contadores_venda add constraint contadores_venda_ultimo_numero_check
  CHECK ((ultimo_numero >= 0));
alter table public.despesas add constraint despesas_descricao_check
  CHECK ((length(btrim(descricao)) > 0));
alter table public.despesas add constraint despesas_status_check
  CHECK ((status = ANY (ARRAY['pendente'::text, 'pago'::text])));
alter table public.despesas add constraint despesas_valor_check
  CHECK ((valor >= (0)::numeric));
alter table public.documentos_fiscais add constraint documentos_fiscais_tipo_documento_check
  CHECK ((tipo_documento = ANY (ARRAY['nfce'::text, 'nfse'::text, 'nfe'::text])));
alter table public.empresas add constraint empresas_bloqueio_coerente
  CHECK ((bloqueado = (status_conta <> 'aprovado'::text)));
alter table public.empresas add constraint empresas_dados_cadastrais_ck
  CHECK ((((razao_social IS NULL) OR ((char_length(btrim(razao_social)) >= 2) AND (char_length(btrim(razao_social)) <= 200))) AND ((cnpj IS NULL) OR (cnpj ~ '^\d{14}$'::text)) AND ((telefone IS NULL) OR (telefone ~ '^\d{10,11}$'::text)) AND ((cep IS NULL) OR (cep ~ '^\d{8}$'::text)) AND ((logradouro IS NULL) OR ((char_length(btrim(logradouro)) >= 2) AND (char_length(btrim(logradouro)) <= 200))) AND ((numero IS NULL) OR ((char_length(btrim(numero)) >= 1) AND (char_length(btrim(numero)) <= 20))) AND ((complemento IS NULL) OR ((char_length(btrim(complemento)) >= 1) AND (char_length(btrim(complemento)) <= 100))) AND ((bairro IS NULL) OR ((char_length(btrim(bairro)) >= 2) AND (char_length(btrim(bairro)) <= 100))) AND ((cidade IS NULL) OR ((char_length(btrim(cidade)) >= 2) AND (char_length(btrim(cidade)) <= 100))) AND ((uf IS NULL) OR (uf = ANY (ARRAY['AC'::text, 'AL'::text, 'AP'::text, 'AM'::text, 'BA'::text, 'CE'::text, 'DF'::text, 'ES'::text, 'GO'::text, 'MA'::text, 'MT'::text, 'MS'::text, 'MG'::text, 'PA'::text, 'PB'::text, 'PR'::text, 'PE'::text, 'PI'::text, 'RJ'::text, 'RN'::text, 'RS'::text, 'RO'::text, 'RR'::text, 'SC'::text, 'SP'::text, 'SE'::text, 'TO'::text])))));
alter table public.empresas add constraint empresas_florest_revisao_check
  CHECK ((florest_revisao >= 0));
alter table public.empresas add constraint empresas_nome_check
  CHECK (((length(btrim(nome)) >= 2) AND (length(btrim(nome)) <= 200)));
alter table public.empresas add constraint empresas_status_conta_check
  CHECK ((status_conta = ANY (ARRAY['pendente'::text, 'aprovado'::text, 'bloqueado'::text])));
alter table public.florest_outbox add constraint florest_outbox_status_check
  CHECK ((status = ANY (ARRAY['pendente'::text, 'enviando'::text, 'enviado'::text, 'falhou'::text])));
alter table public.florest_outbox add constraint florest_outbox_tentativas_check
  CHECK ((tentativas >= 0));
alter table public.florest_outbox add constraint florest_outbox_tipo_check
  CHECK ((tipo = 'cadastro_criado'::text));
alter table public.fornecedores add constraint fornecedores_cnpj_check
  CHECK ((cnpj ~ '^([0-9]{11}|[0-9]{14})$'::text));
alter table public.fornecedores add constraint fornecedores_razao_social_check
  CHECK ((length(btrim(razao_social)) > 0));
alter table public.itens_venda add constraint itens_venda_preco_unitario_check
  CHECK ((preco_unitario >= (0)::numeric));
alter table public.itens_venda add constraint itens_venda_quantidade_check
  CHECK ((quantidade > (0)::numeric));
alter table public.notas_entrada add constraint notas_entrada_chave_acesso_check
  CHECK ((chave_acesso ~ '^[0-9]{44}$'::text));
alter table public.notas_entrada add constraint notas_entrada_forma_pagamento_check
  CHECK ((forma_pagamento = ANY (ARRAY['a_vista'::text, 'a_prazo'::text])));
alter table public.notas_entrada add constraint notas_entrada_status_check
  CHECK ((status = ANY (ARRAY['em_conferencia'::text, 'confirmada'::text, 'cancelada'::text])));
alter table public.notas_entrada add constraint notas_entrada_valor_total_check
  CHECK ((valor_total >= (0)::numeric));
alter table public.notas_entrada_itens add constraint notas_entrada_itens_quantidade_check
  CHECK ((quantidade > (0)::numeric));
alter table public.pdv_atalhos add constraint pdv_atalhos_imagem_check
  CHECK (((imagem IS NULL) OR ((length(imagem) <= 200000) AND ((imagem ~ '^data:image/(png|jpeg|jpg|webp|svg\+xml);base64,'::text) OR (imagem ~* '^(/|\./|[a-z0-9_-]+/)[a-z0-9_./-]*\.(png|jpe?g|webp|svg)$'::text)))));
alter table public.pdv_atalhos add constraint pdv_atalhos_nome_check
  CHECK (((length(btrim(nome)) >= 1) AND (length(btrim(nome)) <= 40)));
alter table public.pdv_atalhos_produtos add constraint pdv_atalhos_produtos_imagem_check
  CHECK (((imagem IS NULL) OR ((length(imagem) <= 200000) AND ((imagem ~ '^data:image/(png|jpeg|jpg|webp|svg\+xml);base64,'::text) OR (imagem ~* '^(/|\./|[a-z0-9_-]+/)[a-z0-9_./-]*\.(png|jpe?g|webp|svg)$'::text)))));
alter table public.perfis add constraint perfis_papel_ck
  CHECK ((papel = ANY (ARRAY['proprietario'::text, 'funcionario'::text])));
alter table public.perfis add constraint perfis_permissoes_ck
  CHECK ((permissoes <@ ARRAY['dashboard'::text, 'clientes'::text, 'produtos'::text, 'estoque'::text, 'pdv'::text, 'fornecedores'::text, 'notas_entrada'::text, 'financeiro'::text, 'fiscal'::text, 'relatorios'::text, 'configuracoes'::text, 'usuarios'::text]));
alter table public.perfis add constraint perfis_proprietario_ativo_ck
  CHECK (((papel <> 'proprietario'::text) OR ativo));
alter table public.produtos add constraint produtos_categoria_check
  CHECK (((categoria IS NULL) OR ((length(btrim(categoria)) >= 1) AND (length(btrim(categoria)) <= 80))));
alter table public.produtos add constraint produtos_estoque_minimo_check
  CHECK (((estoque_minimo IS NULL) OR (estoque_minimo >= (0)::numeric)));
alter table public.produtos add constraint produtos_nome_check
  CHECK ((length(btrim(nome)) > 0));
alter table public.produtos add constraint produtos_preco_custo_check
  CHECK (((preco_custo IS NULL) OR (preco_custo >= (0)::numeric)));
alter table public.produtos add constraint produtos_preco_venda_check
  CHECK ((preco_venda >= (0)::numeric));
alter table public.produtos add constraint produtos_tipo_fiscal_check
  CHECK ((tipo_fiscal = ANY (ARRAY['produto'::text, 'servico'::text])));
alter table public.vendas add constraint vendas_forma_pagamento_check
  CHECK ((length(btrim(forma_pagamento)) > 0));
alter table public.vendas add constraint vendas_total_check
  CHECK ((total >= (0)::numeric));

-- =====================================================================
-- 6. FOREIGN KEY
-- =====================================================================
alter table public.clientes add constraint clientes_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.configuracoes_empresa add constraint configuracoes_empresa_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.configuracoes_fiscais add constraint configuracoes_fiscais_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.contadores_fiscais add constraint contadores_fiscais_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.contadores_venda add constraint contadores_venda_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.despesas add constraint despesas_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.despesas add constraint despesas_nota_fk
  FOREIGN KEY (empresa_id, nota_entrada_id) REFERENCES notas_entrada(empresa_id, id) ON DELETE SET NULL (nota_entrada_id);
alter table public.documentos_fiscais add constraint documentos_fiscais_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.documentos_fiscais add constraint documentos_fiscais_venda_fk
  FOREIGN KEY (empresa_id, venda_id) REFERENCES vendas(empresa_id, id) ON DELETE RESTRICT;
alter table public.documentos_fiscais_eventos add constraint doc_eventos_doc_fk
  FOREIGN KEY (empresa_id, documento_fiscal_id) REFERENCES documentos_fiscais(empresa_id, id) ON DELETE CASCADE;
alter table public.documentos_fiscais_eventos add constraint documentos_fiscais_eventos_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.fiscal_credenciais add constraint fiscal_credenciais_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.florest_outbox add constraint florest_outbox_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.fornecedores add constraint fornecedores_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.itens_venda add constraint itens_venda_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.itens_venda add constraint itens_venda_produto_fk
  FOREIGN KEY (empresa_id, produto_id) REFERENCES produtos(empresa_id, id) ON DELETE RESTRICT;
alter table public.itens_venda add constraint itens_venda_venda_fk
  FOREIGN KEY (empresa_id, venda_id) REFERENCES vendas(empresa_id, id) ON DELETE CASCADE;
alter table public.notas_entrada add constraint notas_entrada_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.notas_entrada add constraint notas_entrada_fornecedor_fk
  FOREIGN KEY (empresa_id, fornecedor_id) REFERENCES fornecedores(empresa_id, id) ON DELETE RESTRICT;
alter table public.notas_entrada_itens add constraint ne_itens_nota_fk
  FOREIGN KEY (empresa_id, nota_entrada_id) REFERENCES notas_entrada(empresa_id, id) ON DELETE CASCADE;
alter table public.notas_entrada_itens add constraint ne_itens_produto_fk
  FOREIGN KEY (empresa_id, produto_id) REFERENCES produtos(empresa_id, id) ON DELETE RESTRICT;
alter table public.notas_entrada_itens add constraint notas_entrada_itens_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.pdv_atalhos add constraint pdv_atalhos_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.pdv_atalhos_produtos add constraint pdv_atalhos_produtos_empresa_id_atalho_id_fkey
  FOREIGN KEY (empresa_id, atalho_id) REFERENCES pdv_atalhos(empresa_id, id) ON DELETE CASCADE;
alter table public.pdv_atalhos_produtos add constraint pdv_atalhos_produtos_empresa_id_produto_id_fkey
  FOREIGN KEY (empresa_id, produto_id) REFERENCES produtos(empresa_id, id) ON DELETE CASCADE;
alter table public.perfis add constraint perfis_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.perfis add constraint perfis_id_fkey
  FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.produtos add constraint produtos_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;
alter table public.vendas add constraint vendas_cliente_fk
  FOREIGN KEY (empresa_id, cliente_id) REFERENCES clientes(empresa_id, id) ON DELETE SET NULL (cliente_id);
alter table public.vendas add constraint vendas_empresa_id_fkey
  FOREIGN KEY (empresa_id) REFERENCES empresas(id) ON DELETE CASCADE;

-- =====================================================================
-- 7. ÍNDICES (exceto os já criados por PRIMARY KEY / UNIQUE)
-- =====================================================================
CREATE INDEX clientes_empresa_nome_idx ON public.clientes USING btree (empresa_id, nome, id);
CREATE INDEX despesas_empresa_data_idx ON public.despesas USING btree (empresa_id, data);
CREATE INDEX despesas_nota_idx ON public.despesas USING btree (nota_entrada_id) WHERE (nota_entrada_id IS NOT NULL);
CREATE INDEX despesas_pendentes_idx ON public.despesas USING btree (empresa_id, vencimento) WHERE (status <> 'pago'::text);
CREATE INDEX documentos_fiscais_empresa_idx ON public.documentos_fiscais USING btree (empresa_id, created_at DESC);
CREATE INDEX documentos_fiscais_venda_idx ON public.documentos_fiscais USING btree (venda_id);
CREATE UNIQUE INDEX documentos_fiscais_venda_tipo_uk ON public.documentos_fiscais USING btree (venda_id, tipo_documento) WHERE (status <> ALL (ARRAY['cancelada'::text, 'rejeitada'::text]));
CREATE INDEX doc_eventos_doc_idx ON public.documentos_fiscais_eventos USING btree (documento_fiscal_id);
CREATE UNIQUE INDEX empresas_assinatura_uk ON public.empresas USING btree (assinatura_id) WHERE (assinatura_id IS NOT NULL);
CREATE INDEX empresas_status_idx ON public.empresas USING btree (status_conta);
CREATE UNIQUE INDEX florest_outbox_cadastro_uk ON public.florest_outbox USING btree (empresa_id) WHERE (tipo = 'cadastro_criado'::text);
CREATE INDEX florest_outbox_fila_idx ON public.florest_outbox USING btree (proxima_tentativa_em, id) WHERE (status = ANY (ARRAY['pendente'::text, 'enviando'::text]));
CREATE INDEX fornecedores_empresa_razao_idx ON public.fornecedores USING btree (empresa_id, razao_social, id);
CREATE INDEX itens_venda_produto_idx ON public.itens_venda USING btree (produto_id);
CREATE INDEX itens_venda_venda_idx ON public.itens_venda USING btree (venda_id);
CREATE INDEX notas_entrada_criado_idx ON public.notas_entrada USING btree (empresa_id, criado_em DESC);
CREATE INDEX notas_entrada_emissao_idx ON public.notas_entrada USING btree (empresa_id, data_emissao);
CREATE INDEX notas_entrada_fornecedor_idx ON public.notas_entrada USING btree (fornecedor_id);
CREATE INDEX ne_itens_nota_idx ON public.notas_entrada_itens USING btree (nota_entrada_id);
CREATE INDEX ne_itens_produto_idx ON public.notas_entrada_itens USING btree (produto_id);
CREATE INDEX pdv_atalhos_empresa_ordem_ix ON public.pdv_atalhos USING btree (empresa_id, ordem);
CREATE INDEX pdv_atalhos_produtos_ordem_ix ON public.pdv_atalhos_produtos USING btree (atalho_id, ordem);
CREATE INDEX perfis_empresa_idx ON public.perfis USING btree (empresa_id);
CREATE UNIQUE INDEX perfis_um_proprietario_uk ON public.perfis USING btree (empresa_id) WHERE (papel = 'proprietario'::text);
CREATE UNIQUE INDEX produtos_empresa_codigo_uk ON public.produtos USING btree (empresa_id, codigo) WHERE (codigo IS NOT NULL);
CREATE INDEX produtos_empresa_estoque_idx ON public.produtos USING btree (empresa_id, quantidade_estoque);
CREATE INDEX produtos_empresa_gtin_idx ON public.produtos USING btree (empresa_id, gtin) WHERE (gtin IS NOT NULL);
CREATE UNIQUE INDEX produtos_empresa_gtin_norm_uk ON public.produtos USING btree (empresa_id, NULLIF(ltrim(gtin, '0'::text), ''::text)) WHERE (gtin IS NOT NULL);
CREATE INDEX produtos_empresa_nome_idx ON public.produtos USING btree (empresa_id, nome, id);
CREATE INDEX vendas_cliente_idx ON public.vendas USING btree (empresa_id, cliente_id) WHERE (cliente_id IS NOT NULL);
CREATE INDEX vendas_empresa_criado_idx ON public.vendas USING btree (empresa_id, criado_em DESC);

-- =====================================================================
-- 8. DEFAULTs que dependem da função private.empresa_id_ativa()
--    (funções não fazem parte deste arquivo; restaure-as antes desta seção.
--     Se a função ainda não existir, nada é alterado e é emitido um WARNING.)
-- =====================================================================
do $$
begin
  if to_regprocedure('private.empresa_id_ativa()') is null then
    raise warning 'private.empresa_id_ativa() nao existe: DEFAULTs da secao 8 NAO foram aplicados. Restaure as funcoes e execute esta secao novamente.';
  else
    alter table public.clientes alter column empresa_id set default private.empresa_id_ativa();
    alter table public.configuracoes_fiscais alter column empresa_id set default private.empresa_id_ativa();
    alter table public.despesas alter column empresa_id set default private.empresa_id_ativa();
    alter table public.fornecedores alter column empresa_id set default private.empresa_id_ativa();
    alter table public.produtos alter column empresa_id set default private.empresa_id_ativa();
  end if;
end
$$;

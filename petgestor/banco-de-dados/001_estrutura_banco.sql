-- ==========================================================
-- 001_estrutura_banco.sql
-- PetGestor / ERP PETSHOP — Estrutura base do banco (Supabase)
--
-- Gerado a partir de extração direta do banco em produção (CSVs), refletindo
-- o ESTADO ATUAL. Não inclui funções/RPCs, policies RLS, triggers, cron jobs
-- ou dados — esses itens ficam em arquivos separados.
--
-- Escopo deste arquivo:
--   - extensões e schemas
--   - 26 tabelas, colunas, tipos, defaults, IDENTITY
--   - PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK
--   - índices
--   - habilitação de RLS (sem as policies)
-- ==========================================================


-- ==========================================================
-- 1) EXTENSÕES
-- ==========================================================
create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;
create extension if not exists pg_cron;
create extension if not exists pg_stat_statements;
create extension if not exists supabase_vault;
create extension if not exists plpgsql;


-- ==========================================================
-- 2) SCHEMAS
-- ==========================================================
-- "public" já existe por padrão.
-- "cron" é criado automaticamente pela extensão pg_cron.
create schema if not exists private;


-- ==========================================================
-- 3) TABELAS
-- ==========================================================

-- ---------- Plataforma Florest Sistemas ----------

create table public.florest_sistemas (
  id uuid not null default gen_random_uuid(),
  slug text not null,
  nome text not null,
  criado_em timestamp with time zone not null default now(),
  ativo boolean not null default true,
  modo_sync text not null default 'local'::text,
  sync_url text,
  tolerancia_dias integer not null default 2,
  bloqueio_automatico boolean not null default true,
  marcar_atrasado_ao_bloquear boolean not null default true,
  constraint florest_sistemas_pkey primary key (id),
  constraint florest_sistemas_slug_key unique (slug),
  constraint florest_sistemas_modo_sync_check check ((modo_sync = any (array['local'::text, 'remoto'::text]))),
  constraint florest_sistemas_slug_formato_check check ((slug ~ '^[a-z][a-z0-9_]{1,31}$'::text)),
  constraint florest_sistemas_sync_url_check check (((sync_url is null) or ((modo_sync = 'remoto'::text) and (sync_url ~ '^https://[a-z0-9]{20}\.supabase\.co/functions/v1/florest-sync$'::text)))),
  constraint florest_sistemas_tolerancia_check check (((tolerancia_dias >= 0) and (tolerancia_dias <= 30)))
);

create table public.florest_clientes (
  id uuid not null default gen_random_uuid(),
  nome_empresa text not null,
  responsavel text,
  telefone text,
  email text,
  cnpj text,
  observacoes text,
  criado_em timestamp with time zone not null default now(),
  razao_social text,
  cep text,
  logradouro text,
  numero text,
  complemento text,
  bairro text,
  cidade text,
  uf text,
  constraint florest_clientes_pkey primary key (id),
  constraint florest_clientes_dados_cadastrais_ck check (
    (((razao_social is null) or ((char_length(btrim(razao_social)) >= 2) and (char_length(btrim(razao_social)) <= 200)))
     and ((cep is null) or (cep ~ '^\d{8}$'::text))
     and ((logradouro is null) or ((char_length(btrim(logradouro)) >= 2) and (char_length(btrim(logradouro)) <= 200)))
     and ((numero is null) or ((char_length(btrim(numero)) >= 1) and (char_length(btrim(numero)) <= 20)))
     and ((complemento is null) or ((char_length(btrim(complemento)) >= 1) and (char_length(btrim(complemento)) <= 100)))
     and ((bairro is null) or ((char_length(btrim(bairro)) >= 2) and (char_length(btrim(bairro)) <= 100)))
     and ((cidade is null) or ((char_length(btrim(cidade)) >= 2) and (char_length(btrim(cidade)) <= 100)))
     and ((uf is null) or (uf = any (array['AC'::text,'AL'::text,'AP'::text,'AM'::text,'BA'::text,'CE'::text,'DF'::text,'ES'::text,'GO'::text,'MA'::text,'MT'::text,'MS'::text,'MG'::text,'PA'::text,'PB'::text,'PR'::text,'PE'::text,'PI'::text,'RJ'::text,'RN'::text,'RS'::text,'RO'::text,'RR'::text,'SC'::text,'SP'::text,'SE'::text,'TO'::text]))))
  )
);

create table public.florest_assinaturas (
  id uuid not null default gen_random_uuid(),
  cliente_id uuid not null,
  sistema_id uuid not null,
  status_conta text not null default 'pendente'::text,
  status_pagamento text not null default 'em_dia'::text,
  vencimento date,
  valor_mensal numeric,
  criado_em timestamp with time zone not null default now(),
  ref_externa text,
  revisao bigint not null default 0,
  sync_status text,
  sync_erro text,
  sync_em timestamp with time zone,
  atualizado_em timestamp with time zone not null default now(),
  constraint florest_assinaturas_pkey primary key (id),
  constraint florest_assinaturas_ref_externa_check check (((ref_externa is null) or (ref_externa ~ '^[A-Za-z0-9_.:-]{1,100}$'::text))),
  constraint florest_assinaturas_revisao_check check ((revisao >= 0)),
  constraint florest_assinaturas_status_conta_check check ((status_conta = any (array['pendente'::text, 'aprovado'::text, 'bloqueado'::text]))),
  constraint florest_assinaturas_status_pagamento_check check ((status_pagamento = any (array['em_dia'::text, 'atrasado'::text]))),
  constraint florest_assinaturas_sync_texto_check check ((((sync_status is null) or (char_length(sync_status) <= 30)) and ((sync_erro is null) or (char_length(sync_erro) <= 200))))
);

create table public.florest_cadastros_pendentes (
  id uuid not null default gen_random_uuid(),
  sistema_id uuid not null,
  ref_externa text not null,
  dados jsonb not null,
  candidatos jsonb not null default '[]'::jsonb,
  estado text not null default 'aguardando_decisao'::text,
  criado_em timestamp with time zone not null default now(),
  atualizado_em timestamp with time zone not null default now(),
  constraint florest_cadastros_pendentes_pkey primary key (id),
  constraint florest_cadastros_pendentes_uk unique (sistema_id, ref_externa),
  constraint florest_cadastros_pendentes_cand_ck check (((jsonb_typeof(candidatos) = 'array'::text) and (jsonb_array_length(candidatos) <= 10))),
  constraint florest_cadastros_pendentes_dados_ck check (((jsonb_typeof(dados) = 'object'::text) and (char_length((dados)::text) <= 4000))),
  constraint florest_cadastros_pendentes_estado_ck check ((estado = any (array['aguardando_decisao'::text, 'vinculado'::text, 'criado_novo'::text, 'descartado'::text]))),
  constraint florest_cadastros_pendentes_ref_ck check ((ref_externa ~ '^[A-Za-z0-9_.:-]{1,100}$'::text))
);

create table public.florest_eventos_recebidos (
  id bigint generated always as identity,
  sistema_id uuid not null,
  event_id uuid not null,
  tipo text not null,
  ref_externa text not null,
  estado text not null default 'processando'::text,
  resultado jsonb,
  erro text,
  tentativas integer not null default 1,
  criado_em timestamp with time zone not null default now(),
  atualizado_em timestamp with time zone not null default now(),
  constraint florest_eventos_recebidos_pkey primary key (id),
  constraint florest_eventos_recebidos_uk unique (sistema_id, event_id),
  constraint florest_eventos_recebidos_erro_ck check (((erro is null) or (char_length(erro) <= 100))),
  constraint florest_eventos_recebidos_estado_ck check ((estado = any (array['processando'::text, 'processado'::text, 'descartado'::text, 'erro'::text]))),
  constraint florest_eventos_recebidos_ref_ck check ((ref_externa ~ '^[A-Za-z0-9_.:-]{1,100}$'::text)),
  constraint florest_eventos_recebidos_res_ck check (((resultado is null) or ((jsonb_typeof(resultado) = 'object'::text) and (char_length((resultado)::text) <= 2000)))),
  constraint florest_eventos_recebidos_tipo_ck check ((tipo ~ '^[a-z][a-z0-9_]{1,49}$'::text))
);

-- ---------- Núcleo PetGestor ----------

create table public.empresas (
  id uuid not null default gen_random_uuid(),
  nome text not null,
  criado_em timestamp with time zone not null default now(),
  vencimento date not null default (current_date + '30 days'::interval),
  bloqueado boolean not null default false,
  assinatura_id uuid,
  status_conta text not null default 'aprovado'::text,
  constraint empresas_pkey primary key (id)
);

create table public.admins (
  id uuid not null,
  criado_em timestamp with time zone not null default now(),
  constraint admins_pkey primary key (id)
);

create table public.perfis (
  id uuid not null,
  empresa_id uuid not null,
  nome text not null,
  criado_em timestamp with time zone not null default now(),
  constraint perfis_pkey primary key (id)
);

create table public.clientes (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  nome text not null,
  telefone text not null,
  email text,
  cpf text,
  cep text,
  logradouro text,
  numero text,
  complemento text,
  bairro text,
  cidade text,
  uf text,
  criado_em timestamp with time zone not null default now(),
  constraint clientes_pkey primary key (id)
);

create table public.pets (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  cliente_id uuid not null,
  nome text not null,
  especie text,
  raca text,
  observacoes text,
  criado_em timestamp with time zone not null default now(),
  constraint pets_pkey primary key (id)
);

create table public.agendamentos (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  cliente_id uuid not null,
  pet_id uuid not null,
  servico text not null,
  data date not null,
  horario time without time zone not null,
  observacao text,
  status text not null default 'agendado'::text,
  criado_em timestamp with time zone not null default now(),
  constraint agendamentos_pkey primary key (id),
  constraint agendamentos_status_check check ((status = any (array['agendado'::text, 'concluido'::text, 'cancelado'::text])))
);

create table public.produtos (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  nome text not null,
  preco_venda numeric not null,
  preco_custo numeric,
  ncm text,
  cst_csosn text,
  cfop text,
  aliquota_icms numeric,
  criado_em timestamp with time zone not null default now(),
  quantidade_estoque numeric not null default 0,
  codigo text,
  vendavel_pacote boolean not null default false,
  pacote_qtd integer,
  pacote_preco numeric,
  tipo_fiscal text not null default 'produto'::text,
  gtin text,
  cest text,
  origem_mercadoria text,
  unidade_comercial text,
  cst_pis text,
  cst_cofins text,
  codigo_servico text,
  codigo_tributacao_municipal text,
  municipio_incidencia text,
  iss numeric,
  constraint produtos_pkey primary key (id),
  constraint produtos_tipo_fiscal_check check ((tipo_fiscal = any (array['produto'::text, 'servico'::text])))
);

create table public.pacotes_clientes (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  cliente_id uuid not null,
  produto_id uuid not null,
  sessoes_totais integer not null,
  sessoes_usadas integer not null default 0,
  criado_em timestamp with time zone not null default now(),
  constraint pacotes_clientes_pkey primary key (id)
);

create table public.pacote_usos (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  pacote_id uuid not null,
  usado_em timestamp with time zone not null default now(),
  constraint pacote_usos_pkey primary key (id)
);

create table public.contadores_venda (
  empresa_id uuid not null,
  ultimo_numero bigint not null default 0,
  constraint contadores_venda_pkey primary key (empresa_id)
);

create table public.vendas (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  cliente_id uuid,
  forma_pagamento text not null,
  total numeric not null,
  criado_em timestamp with time zone not null default now(),
  tipo text not null default 'produto'::text,
  numero_venda bigint,
  constraint vendas_pkey primary key (id),
  constraint vendas_empresa_numero_unique unique (empresa_id, numero_venda)
);

create table public.itens_venda (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  venda_id uuid not null,
  produto_id uuid not null,
  quantidade integer not null,
  preco_unitario numeric not null,
  subtotal numeric not null,
  pacote_cliente_id uuid,
  constraint itens_venda_pkey primary key (id)
);

-- ---------- Fornecedores e Notas de Entrada ----------

create table public.fornecedores (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  cnpj text not null,
  razao_social text not null,
  nome_fantasia text,
  inscricao_estadual text,
  endereco text,
  numero text,
  complemento text,
  bairro text,
  municipio text,
  uf text,
  cep text,
  telefone text,
  criado_em timestamp with time zone not null default now(),
  constraint fornecedores_pkey primary key (id),
  constraint fornecedores_empresa_id_cnpj_key unique (empresa_id, cnpj)
);

create table public.notas_entrada (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  fornecedor_id uuid,
  chave_acesso text not null,
  numero text,
  serie text,
  data_emissao timestamp with time zone,
  data_entrada date not null default current_date,
  valor_produtos numeric,
  valor_desconto numeric default 0,
  valor_frete numeric default 0,
  valor_outras_despesas numeric default 0,
  valor_total numeric not null,
  forma_pagamento text,
  status text not null default 'confirmada'::text,
  xml_conteudo text,
  criado_em timestamp with time zone not null default now(),
  confirmado_em timestamp with time zone,
  constraint notas_entrada_pkey primary key (id),
  constraint notas_entrada_empresa_id_chave_acesso_key unique (empresa_id, chave_acesso),
  constraint notas_entrada_chave_acesso_check check ((chave_acesso ~ '^[0-9]{44}$'::text)),
  constraint notas_entrada_forma_pagamento_check check ((forma_pagamento = any (array['a_vista'::text, 'a_prazo'::text]))),
  constraint notas_entrada_status_check check ((status = any (array['em_conferencia'::text, 'confirmada'::text, 'cancelada'::text])))
);

create table public.notas_entrada_itens (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  nota_entrada_id uuid not null,
  produto_id uuid,
  codigo_fornecedor text,
  gtin text,
  descricao text not null,
  ncm text,
  cest text,
  cfop text,
  unidade_comercial text,
  quantidade numeric not null,
  valor_unitario numeric not null,
  valor_total numeric not null,
  origem_mercadoria text,
  cst_csosn text,
  cst_pis text,
  cst_cofins text,
  quantidade_estoque_anterior numeric,
  quantidade_estoque_nova numeric,
  constraint notas_entrada_itens_pkey primary key (id)
);

create table public.despesas (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  descricao text not null,
  categoria text,
  valor numeric not null,
  data date not null default current_date,
  criado_em timestamp with time zone not null default now(),
  status text not null default 'pago'::text,
  vencimento date,
  fornecedor_id uuid,
  nota_entrada_id uuid,
  pago_em timestamp with time zone,
  constraint despesas_pkey primary key (id),
  constraint despesas_status_check check ((status = any (array['pago'::text, 'pendente'::text])))
);

-- ---------- Fiscal (NFC-e / Dados Jah) ----------

create table public.contadores_fiscais (
  empresa_id uuid not null,
  tipo_documento text not null,
  serie text not null,
  ultimo_numero bigint not null default 0,
  constraint contadores_fiscais_pkey primary key (empresa_id, tipo_documento, serie)
);

create table public.configuracoes_fiscais (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  razao_social text,
  nome_fantasia text,
  cnpj text,
  inscricao_estadual text,
  inscricao_municipal text,
  regime_tributario text,
  cep text,
  endereco text,
  numero text,
  complemento text,
  bairro text,
  municipio text,
  uf text,
  codigo_ibge text,
  nfce_serie text,
  nfce_csc text,
  nfce_id_csc text,
  nfce_ambiente text not null default 'homologacao'::text,
  nfse_inscricao_municipal text,
  nfse_municipio text,
  certificado_status text not null default 'nao_configurado'::text,
  status_configuracao text not null default 'incompleta'::text,
  criado_em timestamp with time zone not null default now(),
  atualizado_em timestamp with time zone not null default now(),
  telefone text,
  crt text,
  nfce_versao_qrcode text,
  dadosjah_usuario_criado boolean not null default false,
  emitente_registrado boolean not null default false,
  certificado_numero_serie text,
  certificado_razao_social text,
  certificado_cnpj text,
  certificado_validade date,
  certificado_certificadora text,
  constraint configuracoes_fiscais_pkey primary key (id),
  constraint configuracoes_fiscais_empresa_id_key unique (empresa_id),
  constraint configuracoes_fiscais_nfce_ambiente_check check ((nfce_ambiente = any (array['homologacao'::text, 'producao'::text])))
);

create table public.documentos_fiscais (
  id uuid not null default gen_random_uuid(),
  empresa_id uuid not null,
  venda_id uuid not null,
  tipo_documento text not null,
  referencia_externa text,
  numero text,
  serie text,
  chave_acesso text,
  protocolo text,
  status text not null default 'nao_emitida'::text,
  valor numeric,
  mensagem_rejeicao text,
  referencia_api text,
  xml_url text,
  pdf_url text,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  id_dfe text,
  tp_ambiente text,
  dh_emissao timestamp with time zone,
  dh_recebimento timestamp with time zone,
  c_stat text,
  situation text,
  situation_dfe text,
  xml_conteudo text,
  pdf_conteudo text,
  constraint documentos_fiscais_pkey primary key (id),
  constraint documentos_fiscais_status_check check ((status = any (array['nao_emitida'::text, 'processando'::text, 'autorizada'::text, 'rejeitada'::text, 'cancelada'::text]))),
  constraint documentos_fiscais_tipo_documento_check check ((tipo_documento = any (array['nfce'::text, 'nfse'::text, 'nfe'::text])))
);

create table public.documentos_fiscais_eventos (
  id uuid not null default gen_random_uuid(),
  documento_fiscal_id uuid not null,
  empresa_id uuid not null,
  status text not null,
  c_stat text,
  x_motivo text,
  criado_em timestamp with time zone not null default now(),
  constraint documentos_fiscais_eventos_pkey primary key (id)
);

create table public.dadosjah_credenciais (
  empresa_id uuid not null,
  dadosjah_email text not null,
  dadosjah_password_secret_id uuid not null,
  dadosjah_token text,
  dadosjah_token_expires_at timestamp with time zone,
  criado_em timestamp with time zone not null default now(),
  constraint dadosjah_credenciais_pkey primary key (empresa_id)
);


-- ==========================================================
-- 4) FOREIGN KEYS
-- ==========================================================

alter table public.admins
  add constraint admins_id_fkey foreign key (id) references auth.users(id) on delete cascade;

alter table public.perfis
  add constraint perfis_id_fkey foreign key (id) references auth.users(id) on delete cascade,
  add constraint perfis_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade;

alter table public.empresas
  add constraint empresas_assinatura_id_fkey foreign key (assinatura_id) references public.florest_assinaturas(id);

alter table public.florest_assinaturas
  add constraint florest_assinaturas_cliente_id_fkey foreign key (cliente_id) references public.florest_clientes(id) on delete cascade,
  add constraint florest_assinaturas_sistema_id_fkey foreign key (sistema_id) references public.florest_sistemas(id);

alter table public.florest_cadastros_pendentes
  add constraint florest_cadastros_pendentes_sistema_id_fkey foreign key (sistema_id) references public.florest_sistemas(id);

alter table public.florest_eventos_recebidos
  add constraint florest_eventos_recebidos_sistema_id_fkey foreign key (sistema_id) references public.florest_sistemas(id);

alter table public.clientes
  add constraint clientes_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade;

alter table public.pets
  add constraint pets_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade,
  add constraint pets_cliente_id_fkey foreign key (cliente_id) references public.clientes(id) on delete cascade;

alter table public.agendamentos
  add constraint agendamentos_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade,
  add constraint agendamentos_cliente_id_fkey foreign key (cliente_id) references public.clientes(id) on delete cascade,
  add constraint agendamentos_pet_id_fkey foreign key (pet_id) references public.pets(id) on delete cascade;

alter table public.produtos
  add constraint produtos_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade;

alter table public.pacotes_clientes
  add constraint pacotes_clientes_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade,
  add constraint pacotes_clientes_cliente_id_fkey foreign key (cliente_id) references public.clientes(id) on delete cascade,
  add constraint pacotes_clientes_produto_id_fkey foreign key (produto_id) references public.produtos(id);

alter table public.pacote_usos
  add constraint pacote_usos_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade,
  add constraint pacote_usos_pacote_id_fkey foreign key (pacote_id) references public.pacotes_clientes(id) on delete cascade;

alter table public.contadores_venda
  add constraint contadores_venda_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade;

alter table public.vendas
  add constraint vendas_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade,
  add constraint vendas_cliente_id_fkey foreign key (cliente_id) references public.clientes(id) on delete set null;

alter table public.itens_venda
  add constraint itens_venda_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade,
  add constraint itens_venda_venda_id_fkey foreign key (venda_id) references public.vendas(id) on delete cascade,
  add constraint itens_venda_produto_id_fkey foreign key (produto_id) references public.produtos(id),
  add constraint itens_venda_pacote_cliente_id_fkey foreign key (pacote_cliente_id) references public.pacotes_clientes(id);

alter table public.fornecedores
  add constraint fornecedores_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade;

alter table public.notas_entrada
  add constraint notas_entrada_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade,
  add constraint notas_entrada_fornecedor_id_fkey foreign key (fornecedor_id) references public.fornecedores(id);

alter table public.notas_entrada_itens
  add constraint notas_entrada_itens_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade,
  add constraint notas_entrada_itens_nota_entrada_id_fkey foreign key (nota_entrada_id) references public.notas_entrada(id) on delete cascade,
  add constraint notas_entrada_itens_produto_id_fkey foreign key (produto_id) references public.produtos(id);

alter table public.despesas
  add constraint despesas_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade,
  add constraint despesas_fornecedor_id_fkey foreign key (fornecedor_id) references public.fornecedores(id),
  add constraint despesas_nota_entrada_id_fkey foreign key (nota_entrada_id) references public.notas_entrada(id);

alter table public.contadores_fiscais
  add constraint contadores_fiscais_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade;

alter table public.configuracoes_fiscais
  add constraint configuracoes_fiscais_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade;

alter table public.documentos_fiscais
  add constraint documentos_fiscais_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade,
  add constraint documentos_fiscais_venda_id_fkey foreign key (venda_id) references public.vendas(id) on delete cascade;

alter table public.documentos_fiscais_eventos
  add constraint documentos_fiscais_eventos_documento_fiscal_id_fkey foreign key (documento_fiscal_id) references public.documentos_fiscais(id) on delete cascade,
  add constraint documentos_fiscais_eventos_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade;

alter table public.dadosjah_credenciais
  add constraint dadosjah_credenciais_empresa_id_fkey foreign key (empresa_id) references public.empresas(id) on delete cascade;


-- ==========================================================
-- 5) ÍNDICES ADICIONAIS
-- (PKs e UNIQUEs acima já criam seus índices automaticamente;
--  aqui só os índices que não vêm de nenhuma constraint de tabela)
-- ==========================================================

create unique index florest_assinaturas_sistema_ref_uk
  on public.florest_assinaturas using btree (sistema_id, ref_externa)
  where (ref_externa is not null);

create index florest_cadastros_pendentes_estado_idx
  on public.florest_cadastros_pendentes using btree (estado, criado_em);

create index florest_eventos_recebidos_ref_idx
  on public.florest_eventos_recebidos using btree (sistema_id, ref_externa);

create unique index produtos_codigo_empresa_key
  on public.produtos using btree (empresa_id, codigo)
  where (codigo is not null);


-- ==========================================================
-- 6) ROW LEVEL SECURITY (habilitação — policies ficam em arquivo separado)
-- ==========================================================

alter table public.admins enable row level security;
alter table public.agendamentos enable row level security;
alter table public.clientes enable row level security;
alter table public.configuracoes_fiscais enable row level security;
alter table public.contadores_fiscais enable row level security;
alter table public.contadores_venda enable row level security;
alter table public.dadosjah_credenciais enable row level security;
alter table public.despesas enable row level security;
alter table public.documentos_fiscais enable row level security;
alter table public.documentos_fiscais_eventos enable row level security;
alter table public.empresas enable row level security;
alter table public.florest_assinaturas enable row level security;
alter table public.florest_cadastros_pendentes enable row level security;
alter table public.florest_clientes enable row level security;
alter table public.florest_eventos_recebidos enable row level security;
alter table public.florest_sistemas enable row level security;
alter table public.fornecedores enable row level security;
alter table public.itens_venda enable row level security;
alter table public.notas_entrada enable row level security;
alter table public.notas_entrada_itens enable row level security;
alter table public.pacote_usos enable row level security;
alter table public.pacotes_clientes enable row level security;
alter table public.perfis enable row level security;
alter table public.pets enable row level security;
alter table public.produtos enable row level security;
alter table public.vendas enable row level security;

# PetGestor --- Configuração e Reconstrução

Este documento acompanha o backup atual do PetGestor no repositório
**Florest-Sistemas**. Nenhum valor sensível deve ser armazenado aqui ou
no GitHub.

## 1. Estrutura atual no GitHub

``` text
petgestor/
├── README.md
├── CONFIGURACAO.md
├── banco-de-dados/
│   ├── README.md
│   ├── 001_estrutura_banco.sql
│   ├── 002_funcoes_banco.sql
│   ├── 003_politicas_rls.sql
│   ├── 004_triggers_cron.sql
│   └── 005_permissoes.sql
├── funcoes-supabase/
│   ├── README.md
│   ├── fiscal-configurar-emitente/
│   ├── fiscal-emitir-documento/
│   ├── fiscal-upload-certificado/
│   ├── florest-admin-assinatura/
│   ├── florest-admin-usuarios/
│   ├── florest-receber-evento/
│   └── petgestor-usuarios/
└── sistema/
    ├── README.md
    └── index.html
```

A pasta `petgestor-usuarios` possui somente documentação/README no
backup atual. Essa função não está publicada no Supabase atual.

## 2. Arquitetura

-   **Frontend:** `sistema/index.html`.
-   **Backend:** Supabase.
-   **Banco:** PostgreSQL.
-   **Autenticação:** Supabase Auth.
-   **Segurança:** Row Level Security (RLS).
-   **Multiempresa:** isolamento dos dados por `empresa_id`.
-   **Server-side:** Supabase Edge Functions.
-   **Fiscal:** integração com Dados Jah pelas Edge Functions fiscais.

## 3. Edge Functions atualmente publicadas

### Fiscais

1.  `fiscal-configurar-emitente`
2.  `fiscal-emitir-documento`
3.  `fiscal-upload-certificado`

As funções fiscais usam o auxiliar `dadosjah.ts`, salvo junto do código
correspondente no backup.

### Administrativas / integração Florest

4.  `florest-admin-assinatura`
5.  `florest-admin-usuarios`
6.  `florest-receber-evento`

Essas três funções são administrativas/de integração e não fazem parte
das três funções fiscais.

## 4. Configuração pública do frontend

O `sistema/index.html` precisa da URL do projeto Supabase e da chave
pública/anônima/publicável. Essas informações são próprias para uso no
navegador.

**Nunca colocar `service_role`, secret key ou outro segredo
administrativo no HTML.**

## 5. Secrets e credenciais

Nomes de Secrets usados pela integração fiscal:

-   `DADOSJAH_SYSTEM_EMAIL`
-   `DADOSJAH_SYSTEM_PASSWORD`
-   `RESPTEC_CNPJ`
-   `RESPTEC_CONTATO`
-   `RESPTEC_EMAIL`
-   `RESPTEC_FONE`

O Supabase também fornece variáveis próprias às Edge Functions, como URL
e chaves do projeto.

As Edge Functions administrativas/de integração podem depender de
Secrets próprios. Na reconstrução, os nomes efetivamente usados devem
ser conferidos no código salvo das Edge Functions e no painel do
Supabase. **Os valores nunca devem ser copiados para o GitHub.**

## 6. O que nunca deve ir para o GitHub

Nunca versionar:

-   `service_role` ou secret key;
-   senhas;
-   tokens de acesso;
-   valores de Secrets;
-   certificado digital A1;
-   senha do certificado A1;
-   credenciais da Dados Jah;
-   dados reais e sensíveis de clientes;
-   conteúdo sensível do Supabase Vault.

## 7. Banco de dados

O backup atual está dividido em:

1.  `001_estrutura_banco.sql` --- extensões, schemas, tabelas,
    constraints, índices e RLS.
2.  `002_funcoes_banco.sql` --- funções e RPCs.
3.  `003_politicas_rls.sql` --- policies de RLS.
4.  `004_triggers_cron.sql` --- trigger e cron job.
5.  `005_permissoes.sql` --- permissões das funções.

Esses arquivos são de **backup/reconstrução**. Não devem ser executados
no banco de produção atual apenas para testar o backup.

## 8. Ordem geral de reconstrução

1.  Criar/configurar um projeto Supabase.
2.  Aplicar `001_estrutura_banco.sql`.
3.  Aplicar `002_funcoes_banco.sql`.
4.  Aplicar `003_politicas_rls.sql`.
5.  Aplicar `004_triggers_cron.sql`.
6.  Aplicar `005_permissoes.sql`.
7.  Criar/publicar as Edge Functions de `funcoes-supabase/`.
8.  Configurar os Secrets necessários no Supabase.
9.  Configurar no frontend a URL e a chave pública do projeto.
10. Publicar `sistema/index.html`.
11. Testar autenticação, isolamento multiempresa, PDV, fiscal e demais
    módulos antes da produção.

## 9. Multiempresa

O PetGestor atende várias empresas no mesmo backend. O isolamento
utiliza `empresa_id` e policies de RLS. Alterações futuras em tabelas,
funções ou policies devem preservar esse isolamento.

## 10. Portal Administrativo

O Portal Administrativo da **Florest Sistemas** é separado do frontend
do PetGestor. Ele se relaciona com funções administrativas presentes
neste backup, mas deve ser versionado separadamente no repositório, fora
de `petgestor/sistema/`.

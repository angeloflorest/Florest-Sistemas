# Painel Administrativo — Florest Sistemas

Painel central para gerenciamento dos clientes e sistemas da Florest Sistemas.

## Dados complementares dos clientes

Em **Clientes → Editar → Dados complementares do cliente**, o administrador salva os dados documentais da empresa, endereço completo, representante/CPF, e-mail de boletos, telefones e datas de cobrança. A mensalidade e os demais dados comerciais existentes continuam no mesmo formulário. Dados complementares não substituem a razão social/CNPJ operacionais do ERP.

- Interface: `sistema/cadastro-documental.mjs` (integrada por `sistema/index.html`).
- Banco: migração `20261118213619_admin_cadastro_documental.sql`.
- Leitura protegida: `admin_ler_cadastro_documental`.
- Gravação comercial/documental atômica: `admin_salvar_cadastro_documental`.
- Dados da Florest: tabela privada `private.admin_prestador_documental`; não incluir dados pessoais reais no código-fonte ou em migrações.
- Permissão: autenticação e `florest_eh_admin()` obrigatórias; tabelas privadas sem acesso direto de clientes autenticados.
- Abrir ou cancelar a edição não grava dados. Falha de carregamento impede sobrescrita acidental.

**Escopo desta entrega:** cadastro e consulta dos dados. A geração do contrato/PDF não está implementada e nenhum botão de emissão é apresentado.

Testes de navegador em `tests/cadastro-documental.browser.cjs` (Playwright) e PostgreSQL isolado em `tests/cadastro-documental.db.cjs` (PGlite). Os testes usam somente dados fictícios.

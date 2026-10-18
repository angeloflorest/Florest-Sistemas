# Etapa 1 — Permissão independente da MARIA

**Estado: correção preparada e testada localmente. Não publicada. Aguardar aprovação.**

Branch local: `correcao-permissoes-maria`. Base da `main`: `adbe1899fdc09517a03c433371665d1d6d5f366e`. O commit final e a relação completa dos arquivos acompanham a entrega externa. Não houve merge, deploy, migration em produção ou concessão real de permissão.

## Problema e solução

A MARIA era uma exceção explícita da navegação: não exigia permissão de módulo. Ocultar seu menu não resolveria chamadas diretas. A correção usa a chave independente **`maria`**, adicionada ao catálogo de permissões e ao Controle de Usuários. Bar, PDV, Produtos e demais permissões não concedem essa chave a funcionários.

O frontend controla menu, atalho, abertura e envio. A Edge valida o JWT e consulta `maria_autorizar` **antes** de tratar ações pendentes, reservar consumo ou chamar a IA. Erro, resposta inesperada ou negação resultam em 403. A empresa é resolvida pelo contexto existente do usuário, nunca por parâmetro da interface. Perfil/empresa bloqueados são recusados pelo helper existente.

No banco, 37 funções públicas de leitura, ações e consulta de uso da MARIA recebem a verificação comum, além dos seus gates originais. Isso impede contornar a Edge chamando diretamente uma RPC. `maria_uso_finalizar` é deliberadamente preservada: só finaliza uma reserva do mesmo usuário/empresa com segredo de servidor, permitindo contabilizar consumo já iniciado mesmo se a permissão for revogada. Não é ferramenta de consulta do modelo.

As funções novas são **SECURITY INVOKER**, com `search_path` fixo e EXECUTE apenas para authenticated/service_role. Reutilizam `private.maria_empresa`, que já valida o contexto de empresa ativa. Modos INVOKER/DEFINER e ACLs das funções existentes são preservados. Não há mudança de política RLS nem de grants de tabelas.

## Permissão de entrada não concede dados

A lista completa das ferramentas e os gates estão em `MATRIZ_FERRAMENTAS.md` e na migration. Além das validações originais:

- Resumos/rankings de vendas, comparativos, rankings/situação de clientes e panorama gerencial exigem `relatorios`. As exigências originais, inclusive `pdv` nas funções legadas, continuam cumulativas.
- Histórico agregado de compras nas buscas/detalhes de cliente e nas informações de produto fica condicionado também a `relatorios`. Cadastro básico continua sujeito aos gates originais.
- Detalhe de produto, que contém custo/margem, exige `produtos` ou `relatorios`. `bar_pedidos` e `estoque` isolados não autorizam esse detalhe sensível na MARIA.
- Análise de estoque exige uma permissão do domínio, excluindo a operação Bar isolada. Focos além de `abaixo_minimo` exigem também `relatorios`.
- Análise Bar em foco `agora` conserva leitura operacional. Demais focos exigem `relatorios` ou `financeiro`, além do módulo comercial e dos gates específicos originais.
- Financeiro continua exigindo `financeiro` ou `relatorios`. Pet mantém contrato comercial e permissões originais. As 16 ações conservam autorização por operação e confirmação do usuário; a nova permissão é uma condição adicional.

Esses recortes se aplicam **somente à MARIA**. Não foram alteradas as operações, tabelas ou políticas de Produtos/Estoque, Bar, PDV, emissão fiscal, Dados Jah, Florest Garçom ou Print Agent. As exposições por APIs operacionais/tabelas identificadas na auditoria anterior continuam pendentes de etapas próprias; não se declara corrigida a leitura REST direta de custo de produto por `bar_pedidos`.

## Usuários existentes — regra proposta, pendente de aprovação

Não há UPDATE de permissões de perfis na migration, nem concessão automática para funcionários. Cadastros existentes mantêm seus arrays. Funcionário com todos os módulos antigos **não** recebe IA por consequência.

Proposta administrativa: manter a herança padrão do papel `proprietario`, por `private.perm('maria')`, assim como nos outros módulos. Essa regra está preparada no código, mas sua adoção depende da aprovação desta entrega. Ela preservaria proprietários ativos das empresas aprovadas, sem editar perfis. Se o proprietário quiser opt-in também para o papel proprietário, esta regra precisa ser revista antes de publicar: o editor atual trata proprietário como herdeiro de todas as permissões.

Na coleta anterior, os sete perfis proprietários eram U01, U02, U04, U07, U08, U14 e U16. Os delegados U03 e U11 tinham `usuarios` e amplas permissões antigas: são **candidatos a análise**, não pessoas já aprovadas para IA. Não foi inferida autorização por nome, cargo ou array antigo, nem consultada novamente a identidade pessoal deles. Essas referências são anônimas e históricas; confirmar com o proprietário quem precisa continuar usando antes da publicação.

O botão “Marcar todos” não concede IA automaticamente; a caixa própria deve ser marcada explicitamente para funcionário. “Somente PDV” e “Limpar” também não concedem MARIA. Um delegado só pode conceder o que ele próprio possui, conforme a normalização existente. Não foi ampliada sua autorização de administrar usuários.

## Versões e publicação automática conferidas

Foram relidos o catálogo de Edge Functions e as definições SQL relacionadas à MARIA. As fontes recuperadas de `maria-chat` v14 e `distgestor-usuarios` v23 foram preservadas como baseline de testes. As versões continuavam 14 e 23 ao final da preparação; `verify_jwt=true` em ambas. As outras funções publicadas foram inventariadas, sem alteração. A lista e hashes estão em `BASELINE.json` e na entrega externa.

O GitHub possuía o frontend atual, mas o arquivo legado `funcoes-supabase/distgestor-usuarios/index.ts` não correspondia ao publicado. Ele foi **preservado sem alteração**. As fontes canônicas desta proposta ficam em `supabase/functions/`: versão publicada integral mais somente o gate novo da MARIA e uma chave na whitelist de cadastro. Testes comparam o restante das duas fontes com a baseline.

A Vercel foi conferida em sessão autenticada, sem alterar configurações:

- [ERP — Production](https://vercel.com/florest-sistemas/erp_florest/settings/environments/production): Branch Tracking `main`.
- [Petgestor — Production](https://vercel.com/florest-sistemas/petgestor/settings/environments/production): Branch Tracking `main`.
- [Admin — Production](https://vercel.com/florest-sistemas/florest_admin/settings/environments/production): Branch Tracking `main`.

Os três informavam que cada commit enviado a `main` cria Production Deployment, com atribuição automática dos domínios habilitada. O deployment atual do ERP indicava a base acima e `erp.florestsistemas.com.br`. A árvore não contém GitHub Actions nem configuração de deploy versionada. Uma branch de trabalho diferente não é a branch de produção conferida; previews automáticos ainda podem ocorrer. Nenhum preview foi aberto contra o banco de produção e nenhum deploy foi solicitado.

A tentativa autorizada de criar a branch remota falhou: **GitHub API error 403: `Resource not accessible by integration`**, endpoint de criação de referência. Não houve branch remota ou push. Falta permissão de escrita do conector para publicar a branch; o pacote permite revisar/aplicar a alteração sem essa integração. Nenhuma credencial foi solicitada ou incorporada ao código.

## SQL versionado e impacto

Migration: `supabase/migrations/20261018232136_maria_acesso_independente.sql`, criada pelo comando `supabase migration new` (CLI 2.121.0), sem link de projeto ou execução remota.

Altera apenas `perfis_permissoes_ck`, `private.usuarios_modulos`, cria os dois gates e acrescenta validações às 37 funções MARIA existentes. Reutiliza as definições recuperadas do projeto, não os SQLs antigos do GitHub. O tamanho da migration decorre de versionar as definições completas, mantendo assinaturas, modo de segurança e lógica existente. Três funções também restringem `v_vend` ao direito de relatórios.

DDL usa transação, `lock_timeout=5s` e `statement_timeout=30s`. A alteração de constraint pode exigir lock e validação de perfis; isso precisa de janela aprovada e nova verificação do catálogo na data da execução. Não há transformação de usuários ou alteração de configuração comercial. Não mudar a constraint isoladamente nem publicar apenas o frontend.

## Testes reais e limitações

Comando: `npm ci` e `npm test` em `florest-erp/testes/maria` com Node 24. A única dependência de teste, PGlite 0.5.10, está fixada e tem lockfile; não é dependência do ERP publicado. A CLI foi instalada somente como ferramenta local. A fonte TypeScript da Edge foi executada em sandbox com Supabase/Groq simulados, nunca com rede ou credenciais reais. Não houve atualização das bibliotecas de produção.

**56 testes passaram, 0 falhas.** Incluem:

- Aplicação da migration em PostgreSQL em memória e negação direta nas 37 funções.
- Proprietário pela regra proposta; funcionário com concessão explícita; funcionário e garçom sem concessão.
- Perfil inativo, empresa bloqueada e revogação sem refresh do JWT.
- Financeiro/relatórios/custos/margens negados a Bar, e foco operacional Bar permitido em dados fictícios.
- Cumulatividade de `relatorios` e gates originais; isolamento de consultas entre duas empresas fictícias.
- Políticas SELECT reais do snapshot em cinco tabelas, incluindo isolamento RLS de vendas.
- Edge sem permissão não chama consumo, ferramentas, ações ou Groq; JWT inválido é recusado; conversa autorizada usa Groq simulado.
- Whitelist impede o modelo de ampliar ferramentas; nova chave aceita no cadastro.
- Guardas de rota/envio/atalho no frontend; código do Bar preservado por hash após normalização dos finais de linha.
- Corpos/modos das 37 funções preservados fora dos gates e do recorte de histórico.
- Rollback recusa remover chave em uso; rollback sem concessões restaura a baseline local.

**Não validados:** ambiente completo Supabase de homologação (Auth/PostgREST/Edge real), diálogo visual completo do ERP, fluxo real de criação/edição de usuário, chamadas reais Groq, consumo/cobrança reais, confirmações de todas as 16 ações e regressão ponta a ponta de pedidos/mesas/comandas/PDV/fiscal/Garçom/Print Agent. Não existia stack separado configurado; não foi criado projeto cobrável nem usado cliente real. Hash de código preservado não substitui teste funcional do Bar. Os testes usam tabelas estruturais e fixtures fictícias, não uma réplica integral de produção ou todos os triggers/grants.

## Plano de publicação futura — exige nova autorização

1. Aprovar a matriz de ferramentas, herança dos proprietários e quais delegados devem receber a chave. Não fazer concessões em lote por possuir `usuarios`.
2. Identificar um Supabase de homologação isolado e repetir o ciclo completo com perfis de teste, inclusive as ações e as operações Bar. Não usar previews que apontem para produção para testes de escrita.
3. Revalidar `main`, versão/hash das Edge e definições SQL; se houver divergência, interromper e reconciliar a baseline. Backup e plano de retorno revisados com responsável pela produção.
4. Com autorização expressa e janela: aplicar primeiro o SQL de backend; depois publicar as duas Edge a partir das fontes canônicas conferidas, preservando secrets e `verify_jwt`; finalmente atualizar o frontend. Alterar `main` publicará automaticamente na Vercel: merge é parte da publicação, não uma tarefa preparatória.
5. Conceder `maria` somente aos funcionários previamente aprovados, em operação separada e auditável. Verificar negações, contexto empresarial e ausência de regressão antes de encerrar a janela.

Nenhuma etapa dessa publicação foi executada.

## Reversão

Preferir reverter somente frontend/Edge, **mantendo o bloqueio SQL**. Isso preserva a correção de acesso mesmo com menu antigo visível. Conferir dependências antes de reverter a nova whitelist de cadastro.

O arquivo `supabase/rollback/maria_acesso_independente.sql` restaura as definições originais e foi testado localmente. Ele **recusa** remover o catálogo se algum perfil já contiver `maria`, para não apagar concessões silenciosamente. Qualquer tratamento de perfis exige aprovação adicional. Uma reversão integral reintroduz o acesso antigo indevido à IA; exige decisão explícita e não deve ser uma reação automática a problema visual. Não alterar módulos operacionais para compensar erro de publicação.

**Ponto de parada: preparação encerrada; aguardar revisão e aprovação do proprietário. Produção permaneceu inalterada pelas ações desta etapa.**

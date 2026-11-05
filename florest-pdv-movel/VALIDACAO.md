# Validação 0.3.0 — migração aplicada — 05/11/2026

## Resultado real

O novo token permitiu escrita como postgres. Permissão de CREATE e DDL temporário com
rollback foram confirmados antes de aplicar qualquer objeto permanente.
Migração `backend/migrations/20261105_pdv_movel.sql` aplicada com sucesso no projeto
`etulhyboogqhyyevpnlo`, após passarem as guardas dos contratos inspecionados.
Hash SHA-256: f3d6ea4b9b12be1430b6cc024f7ea12d7e00033d4dfd50e7f8880a145731165a.

A integração de backend está instalada e verificada tecnicamente. NÃO foi executada
venda real automaticamente. O ciclo completo no APK/empresa de teste ainda precisa
de validação manual; não é apresentado como já testado. Não houve commit/push/deploy.

## Preservação e segurança verificadas no projeto remoto

- Das 444 funções existentes antes, 442 permaneceram com hash idêntico. Apenas
  pdv_historico_listar/detalhar receberam os metadados previstos.
- Funções de caixas, registrar_venda/mista/prazo, estoque, taxas, Bar, Gastronomia,
  PET e Fiscal preservadas. Índices e restrições de public.caixas idênticos ao catálogo.
- Colunas novas em vendas opcionais, sem default; não reescreveram registros anteriores.
- Duas tabelas novas com RLS. Cliente autenticado não pode inserir diretamente;
  operações privadas nem sequer podem ser lidas diretamente pelo cliente.
- Seis RPCs públicas móveis security definer com EXECUTE para authenticated, recusado
  para anon; empresa/usuário/permissão são exigidos no servidor.
- Teste remoto em READ ONLY sob papel authenticated sem JWT foi recusado por sessão
  ausente, antes de abrir caixa/registrar operação. Nenhum usuário de teste foi criado.
- Verificação remota após aplicação: zero caixas móveis, zero operações móveis e zero
  vendas móveis naquele instante. Nenhum dado de clientes/produtos/vendas foi alterado
  por testes automáticos. A configuração fiscal não foi modificada.

## Testes executados

- `npm run check`: TypeScript estrito passou.
- `npm test`: 33 testes do aplicativo passaram, nenhum ignorado.
- `node --test backend/tests/erp-integration.test.cjs`: 3 passaram.
- `python3 backend/tests/run_isolado.py`: passou no PostgreSQL 16 sintético local,
  incluindo RLS/grants, abertura por dispositivo, venda/itens/estoque, pagamentos separados,
  rollback, preço adulterado, falta de estoque, recibos, prazo e fechamento consistente.
- `backend/tests/concorrencia.py`: seis chamadas simultâneas da mesma chave retornaram
  uma venda/pagamento/baixa; corrida venda/fechamento manteve o resumo correto.
- Bundle Android Hermes exportado com logo; prebuild e catálogo Expo offline aprovados.
- Android: pacote preservado, versionCode 3, versão 0.3.0, adjustResize e assinatura
  Release explícita conferidos. Não foi gerado/assinado APK neste Linux.
- Diff revisado com core.whitespace=cr-at-eol para preservar o HTML original em CRLF.

Os testes locais usam snapshots de funções reais e helpers fixture; não equivalem a
executar todas as integrações de taxas/fiscal no projeto remoto nem substituir o teste
no aparelho. Os testes de APIs do aplicativo usam mocks, com teste adicional do bloqueio
real de sessão no projeto. Não foi feita autenticação com senha de cliente.

## Implementação e limites

Caixa exclusivo da instalação, confirmação/rejeição idempotente, estoque pela função
central existente, pagamentos canônicos separados, taxas existentes, título a prazo,
fechamento e resumo calculado do banco. Histórico móvel tem filtros no servidor e
permissão por operador/financeiro. Auditoria de ajustes e título são exibidos nos detalhes.

A emissão fiscal NÃO foi alterada. O móvel recusa vendas se emite_nota_fiscal=true ou
não confirmada, enquanto o fluxo fiscal existente não estiver integrado ao app. Não
modificar essa configuração para liberar o celular. Esse caso permanece uma limitação.

Pontos visuais do ERP (origem/caixa/operador e produtos por caixa) foram preparados em
florest-erp/sistema/index.html, mas NÃO publicados. As consultas gerais continuam usando
as mesmas tabelas canônicas, sem contabilidade paralela ou soma duplicada de venda móvel.
É necessário publicar os ajustes locais autorizados para que os novos rótulos apareçam
no site servido; não declarar essa publicação concluída pela aplicação SQL.

## Arquivos e procedimento

Lista exata em docs/ARQUIVOS-ALTERADOS.txt. Somente aplicativo/backend/testes e os pontos
de relatório/histórico autorizados do HTML do ERP foram alterados. Sem Vercel/workflows.
Migração reversível apenas antes de existir qualquer operação móvel: rollback aborta se
há dados, em vez de apagá-los. Migração aplicada não deve ser executada novamente.

Windows: manter .env.local, keystore original e APK anterior; executar
GERAR_APK_FLOREST_PDV_MOVEL.bat na pasta do app. Exigir BUILD SUCCESSFUL e APK RELEASE
verificado. Saída APK-GERADO/Florest-PDV-Movel.apk. Instalar por cima, sem desinstalar.
A distribuição dos arquivos atuais/GitHub aguarda autorização de commit/push.

# Backend PDV Móvel — situação e aplicação controlada

Projeto consultado: `etulhyboogqhyyevpnlo`. Catálogo atual recuperado em 05/11/2026,
sem ler cadastros/vendas. Não há necessidade de chaves secretas no APK.

## Resultado da aplicação

APLICADA em 05/11/2026 no projeto acima, após receber token de escrita.
`current_user=postgres`, modo de escrita ativo e DDL temporário/revertido confirmaram o acesso.
Guardas dos contratos atuais passaram; a migração foi executada numa transação e verificada.
SHA-256: `f3d6ea4b9b12be1430b6cc024f7ea12d7e00033d4dfd50e7f8880a145731165a`.

O bloqueio anterior de `supabase_read_only_user` foi superado pelo novo token, sem troca de
papéis para elevar permissões, sem desativar RLS e sem contornar a restrição anterior.
Não reaplicar a migração: o utilitário aborta quando encontra seus objetos existentes.

Pós-migração: RLS nas tabelas novas, escrita direta bloqueada ao cliente, seis RPCs com
EXECUTE apenas autenticado e rejeição remota de sessão ausente. Das 444 funções
preexistentes, 442 preservadas e só dois históricos alterados como previsto. Índices e
restrições de public.caixas preservados. Nenhuma venda, pagamento ou caixa de teste remoto
foi criado. A leitura final encontrou zero sessões, operações e vendas móveis naquele instante.

Não executar fixtures de testes no Supabase. A validação comercial deve ser feita manualmente
pelo proprietário no celular, sem modificar a configuração fiscal para contornar bloqueios.

## Objetos exatos da migração

Novos:
- `public.pdv_movel_caixas`: apenas sessões de caixa por instalação/empresa, sem duplicar
  vendas, pagamentos, estoque ou contas a receber.
- `private.pdv_movel_operacoes`: pedidos/recibos idempotentes, sem acesso direto de clientes.
- `public.vendas.pdv_movel_caixa_id`, `pdv_movel_ajustes`, FK composta e índice;
  constraint impede ter caixa principal e móvel na mesma venda.
- `private.pdv_movel_resumo`.
- RPCs públicas `pdv_movel_contexto`, `pdv_movel_operar`, `pdv_movel_operacao_consultar`,
  `pdv_movel_caixas_listar`, `pdv_movel_vendas_listar`, `pdv_movel_venda_detalhar`.
- RLS e grants específicos; clientes não escrevem diretamente nos objetos novos.

Consultas existentes ajustadas apenas para incluir metadados de origem/caixa/operador:
- `public.pdv_historico_listar`.
- `public.pdv_historico_detalhar`.
As regras de autorização/editabilidade originais permanecem. Venda móvel não se torna
editável pelo fluxo de caixa principal.

Permanecem intactos: tabela `public.caixas`, suas funções/índices, registrar_venda,
registrar_venda_mista/prazo, validadores de estoque, taxas, contas a receber existentes,
funções fiscais e funções do Bar/Gastronomia/PET. Os registros financeiros móveis usam
as MESMAS tabelas canônicas, sem uma segunda contabilidade.

## Procedimento registrado para revisão (já executado; não reaplicar)

1. Confirmar o projeto e usar acesso de escrita autorizado.
2. Reexecutar `python3 backend/inspecionar_supabase.py --project-ref etulhyboogqhyyevpnlo`.
3. Conferir as precondições: hashes dos contratos inspecionados dentro da migração abortam
   se alguma função central/histórico mudou. Não remova nem atualize hashes para forçar.
4. Aplicar `20261105_pdv_movel.sql` em uma única transação. Não selecionar só trechos.
   Como alternativa, com o segredo já disponível e escrita permitida:
   `python3 backend/aplicar_migracao.py` (não executa vendas de teste).
5. Verificar objetos, RLS/grants e respostas antes de liberar o teste manual no celular.
   Em falha ou timeout, consultar o estado antes de reaplicar. O utilitário aborta se
   encontrar objetos já existentes.
6. Publicar o app/ajustes locais de ERP SOMENTE após autorização posterior do proprietário.
   Não servir o novo HTML antes da migração: as consultas usam as novas colunas.

Rollback: `20261105_rollback_sem_dados.sql` restaura os dois históricos e remove só objetos
novos se NENHUMA sessão/operação/venda móvel foi registrada. Se houver dados, ele aborta;
preparar uma correção aditiva. Nunca apagar dados de caixa para fazer o rollback passar.

## Testes técnicos, sem vendas reais

Os ensaios usam o Docker LOCAL e somente o banco sintético `mobile_test` no container
`florest-mobile-pg`. Eles nunca apontam para o Supabase.

```sh
docker --host=unix:///var/run/docker.sock run -d --name florest-mobile-pg \
  -e POSTGRES_PASSWORD=local-test-only -e POSTGRES_DB=mobile_test postgres:16-alpine
python3 backend/tests/run_isolado.py
node --test backend/tests/erp-integration.test.cjs
```

O runner recria apenas esse banco sintético nesse container dedicado. Requer a imagem oficial
PostgreSQL 16; usa funções reais inspecionadas para venda, pagamentos, histórico e vínculo de
caixa. Helpers de taxas/fiscal/cadastro são fixtures; não afirma testar esses serviços reais.

Passaram: dois celulares independentes, gravação canônica, estoque, pagamentos separados,
rollback de erros, recibo de rejeição, prazo, fechamento, histórico, RLS/permissões,
isolamento, proteção fiscal, seis reenvios concorrentes da mesma chave e venda/fechamento
concorrentes. As guardas de versão são verificadas separadamente contra o catálogo remoto;
no fixture isolado seus hashes são omitidos porque helpers são simulados.

Teste comercial no projeto real NÃO foi executado automaticamente. Depois de acesso,
migração e APK, o proprietário deve realizar o cenário manual descrito nas instruções.

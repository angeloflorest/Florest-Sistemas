# Rotisseria — implantação

As integrações compartilhadas receberam autorização específica em 09/11/2026. As migrações foram aplicadas e o módulo foi liberado somente para a empresa vinculada a `bar@gmail.com`. A publicação das telas deve ser conferida pelo conteúdo servido no ERP e no admin, além do commit no GitHub.

## Alterações compartilhadas necessárias

A migração `20261109142419_rotisseria_comandas_caixa.sql` mantém os ramos existentes e acrescenta:

| Ponto | Acréscimo exclusivo da Rotisseria |
|---|---|
| `admin_configurar_modulo` | Aceita o identificador comercial `rotisseria`; mantém a regra existente entre Bar e Gastronomia. |
| `usuarios_modulos` / constraint de permissões | Quatro permissões `rotisseria_*`. |
| Constraint de tipo de caixa / `caixa_tipo_validar` | Aceita `ROTISSERIA` além dos três tipos atuais. |
| `caixa_pode_operar` | Exige módulo ativo e permissão de caixa da Rotisseria para esse novo tipo. |
| `caixa_vinculo_validar` | Vendas e pagamentos `rotisseria` só se vinculam ao caixa `ROTISSERIA`. |
| `caixa_calcular` | Delega exclusivamente o tipo novo ao resumo da Rotisseria. |
| `impressao_agente_jobs_reservar` | Encaminha comprovantes marcados `rotisseria_impressora_propria` à impressora configurada no módulo; preserva os demais destinos. |

A migração também cria as tabelas e RPCs novas. Tabelas operacionais privadas, sinal público com RLS, autorização por empresa ativa/módulo/permissão e dispositivo de caixa. Não substitui os fluxos de venda, estoque, fiscal ou caixa dos módulos existentes.

Todas as definições compartilhadas possuem guarda de hash antes da atualização. Se outra implantação mudar uma delas, a transação aborta em vez de sobrescrever a versão nova.

## Validação realizada

- 37 testes direcionados passaram: módulo novo em dois navegadores e regressões do Bar.
- Transação real no banco com ROLLBACK: peso, deduplicação, preço, versão, dispositivo, estoque, pagamento, troco, resumo/fechamento, histórico, impressão, preparação idempotente de NFC-e, produto de outra empresa, bloqueio de módulo e chamada com papel `authenticated`.
- Caminho de venda do PDV principal exercitado em subtransação revertida.
- Nenhuma venda de teste persistiu. Nenhuma NFC-e foi transmitida à SEFAZ; nenhum job de impressão de teste persistiu. Impressão física e emissão real dependem da configuração existente e da validação do operador.
- Base de interface atualizada para `c25f45a`, preservando a conferência de caixa da Gastronomia publicada em paralelo.

## Conferências de implantação

1. Buscar a versão mais recente de `main` e conferir novamente as funções do banco; reaplicar só a Rotisseria se houver alterações.
2. Aplicar a migração em uma única transação, validar RLS e os avisos de segurança referentes aos objetos novos.
3. Ativar `empresa_modulos.rotisseria` somente para a empresa vinculada a `bar@gmail.com`, depois de confirmar novamente o vínculo. Nenhuma outra empresa deve ser liberada automaticamente.
4. Publicar a interface do ERP e do admin e comparar os arquivos servidos com o commit publicado.
5. No computador, definir o dispositivo como caixa; no tablet, manter Atendimento. Configurar produtos/fotos/impressora e testar a operação.

## Revisão de segurança

A migração adicional `20261109145357_rotisseria_admin_api_privada.sql` mantém a autorização administrativa no schema privado. A RPC pública é `SECURITY INVOKER`; a função privada exige `florest_eh_admin()`. As quatro tabelas operacionais privadas têm RLS e acesso direto revogado para clientes: a ausência de políticas nessas tabelas é intencional, pois somente as funções autorizadas operam nelas.

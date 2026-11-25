# iFood na Gastronomia — conexão de testes

Atualizado em 17/11/2026. A preparação de 09/11 foi ampliada para conexão centralizada no servidor. A liberação inicial usa a empresa autorizada SPETTOS DAY e exclusivamente o merchant de teste. Não habilita lojas de produção nem outras empresas.

## Fluxo

1. Gastronomia → Configurações → iFood: cadastro da loja, credenciais protegidas no Vault, teste de conexão, consulta manual e pausa.
2. O servidor consulta Events em rotina agendada, inclusive com o navegador fechado. A reserva por empresa evita execuções sobrepostas; falhas respeitam Retry-After.
3. Eventos são persistidos antes do ACK. Pedidos e comandos usam chaves únicas; eventos repetidos não repetem atendimento, estoque ou impressão.
4. Gastronomia → Pedidos mostra a fila iFood, o valor pago online e o valor a cobrar. É preciso vincular os códigos externos aos produtos/adicionais da mesma empresa antes de confirmar.
5. Confirmação, preparo, pronto, despacho próprio e cancelamento são enviados ao iFood. HTTP 202 significa aceito para processamento; o estado só muda com o evento correspondente. Comando com resultado incerto não é repetido automaticamente.
6. Após confirmação efetiva, o pedido entra nos atendimentos com origem `ifood`. Usa a receita e estoque da Gastronomia, preserva os preços recebidos e imprime duas vias deduplicadas. Pedidos agendados só são importados no horário de preparo.
7. Pagamentos ONLINE compõem a quitação sem gerar recebimento no caixa físico. OFFLINE só entra no caixa quando o operador registra o recebimento real. A venda preserva a forma de pagamento; taxas e repasses do iFood não são estimados.
8. Cancelamentos com dinheiro recebido ou venda consolidada ficam explicitamente para conciliação financeira/fiscal. Antes do preparo, cancelamento sem recebimentos devolve estoque; após preparo não presume recuperação física de insumos.

## Isolamento

- Merchant, credenciais, vínculos, eventos, pedidos, comandos e pagamentos pertencem a uma empresa.
- Sessão e empresa esperada são verificadas nas ações do operador. Pedidos fora do merchant autorizado são recusados.
- Worker é exclusivo de `service_role`. O agendamento usa assinatura HMAC com prazo e corpo vinculado; a chave nunca entra na fila HTTP.
- Somente as ramificações da origem iFood foram acrescentadas aos helpers compartilhados de pagamentos, venda e impressão. A RPC existente recusa alterações manuais de conteúdo/expedição em pedidos iFood, direcionando às ações próprias.
- Nenhuma credencial é incluída no Git ou retornada à interface.

## Validação e pendências de homologação

Autenticação e status da loja foram validados contra a API real; após polling o iFood retornou loja conectada e aberta. A consulta real recebeu os pedidos de teste #7585 e #7557. Ambos foram cancelados pelo iFood antes da confirmação; o #7557 foi cancelado por falta de confirmação no prazo. Não foram forçados de volta a estados ativos.

Testes de unidade, de navegador com transporte simulado e PostgreSQL isolado cobrem falhas antes de ACK, comandos incertos, isolamento, preços, pagamentos, duplicação de eventos/estoque e impressão. Isso não substitui a homologação externa.

Próximo teste: gerar um pedido no portal iFood, vincular seus códigos externos a produtos existentes, confirmar e acompanhar os eventos na Gastronomia. Conferir a impressão física no agente dessa empresa. Não afirmar homologação aprovada sem o relatório do iFood.

Complementos até o terceiro nível preservam árvore, códigos e quantidades e são resolvidos no estoque da mesma empresa. Composição ambígua, níveis adicionais e preço fracionado sem representação exata ficam em revisão. Negociações usam os motivos específicos e alternativas oferecidos pelo iFood; a resposta tem prazo, validação de valores e bloqueio de duplicação entre aceitar, recusar e contrapropor. Reembolsos e cancelamentos parciais permanecem explicitamente para conciliação financeira, sem inventar devolução de dinheiro ou estoque. Eventos não reconhecidos são guardados e sinalizados. A sincronização de catálogo foi ativada somente na loja de teste autorizada. Conciliação de repasses via Financial continua separada: pagamento online reconhecido não comprova depósito bancário.

## Verificações

```sh
node --test florest-erp/sistema/tests/ifood-preparacao.test.cjs florest-erp/sistema/tests/ifood-conexao.test.cjs
node florest-erp/sistema/tests/ifood-browser.cjs
```

O teste de navegador requer Playwright e Chromium. Não contém credenciais reais.

## Referências oficiais

- https://developer.ifood.com.br/en-US/docs/food/guides/modules/authentication/centralized
- https://developer.ifood.com.br/en-US/docs/food/guides/modules/events/polling-overview
- https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/details
- https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/endpoints
- https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/homologation

Atualização dos complementos: taxas adicionais do iFood são preservadas no total original e demonstradas separadamente; não entram na receita/fiscal da empresa. Em pedidos pagos online, o valor da empresa é rateado entre os pagamentos com ajuste determinístico de centavos, preservando os valores originais recebidos da API. A taxa de plataforma cobrada presencialmente é guardada no recebido bruto do caixa; somente a parcela da loja quita a venda.


## Catálogo, pesquisa e relatórios por canal

- Pedidos começa na data civil de hoje em America/Sao_Paulo; pesquisar outra data consulta o banco pelo período, sem depender dos 500 atendimentos do contexto. Em aberto e Finalizados/cancelados usam a data selecionada. Atualizar recarrega todos os canais da lista. Até 1000 registros por fonte/dia, com aviso de limite.
- Configurações → Relatórios de vendas por canal: origem, início e fim (até 93 dias). Vendas usam data de entrada do pedido; recebimentos presenciais usam data do pagamento. Cancelamentos não compõem o total de vendas; testes são identificados. Online não é tratado como dinheiro recebido nem como repasse bancário confirmado.
- Incluir no cardápio + Salvar mantém o Cardápio Digital e enfileira publicação/pausa no iFood conectado. Estoque não determina a inclusão. A 99Food permanece aguardando ativação.
- O catálogo usa IDs estáveis, snapshots com hash e comparação de versão ao concluir. Mudanças concorrentes não são substituídas por resultados antigos. Categorias são reaproveitadas sem distinção de maiúsculas/minúsculas. Apenas itens gerenciados pela integração são publicados/pausados; não exclui o catálogo remoto.
- Nome, preço, categoria, opções inclusas e foto são enviados. Fotos WebP do armazenamento da própria empresa são convertidas para PNG; o decodificador tem versão e hash WASM fixos. Falhas de foto ficam explícitas. GET após PUT confirma o item; resposta assíncrona é consultada novamente sem repetir PUT.
- A fila de catálogo roda depois dos comandos de pedido e tem orçamento próprio de tempo. O polling de pedidos permanece em 30 segundos. A liberação para outras empresas/produção depende da homologação.

## Verificação de 17/11/2026

- Cache de token no Vault por empresa e fingerprint das credenciais, até `expiresIn`; 401 invalida somente o token usado. Renovação concorrente usa reserva. A cadência real é marcada antes do polling; tolera pequeno desvio do cron sem reduzir o mínimo de 30 segundos.
- CONCLUDED fecha o atendimento e registra a venda uma vez após a quitação. O teste #4715 foi reconciliado: venda de R$ 26,00, pagamentos de R$ 26,00, zero recebimentos presenciais; R$ 1,00 de taxa iFood permanece fora da venda.
- OFFLINE exige permissão de caixa/pedidos, caixa Gastronomia aberto, valor integral pendente e confirmação do operador. Chave repetida não repete recebimento. A taxa da plataforma não aumenta a receita da loja.
- Endereço, instruções, observações de itens, contato/localizador, código de coleta, documento fiscal informado, bandeira, troco e patrocinadores dos benefícios constam na consulta e nas novas impressões. Documento somente na via Caixa. Jobs antigos não são reimpressos automaticamente.
- O catálogo tem acionamento assinado após commit, independente do polling; alterações simples de preço/status usam lote de até 100 itens e conferem COMPLETED e SUCCESS por recurso. Nome/descrição/preço têm limites; existe suporte a contextModifiers no payload, com interface para os contextos já disponibilizados pelo iFood, sem criar novos contextos na loja. Mudanças estruturais usam PUT e confirmação por GET; atualização de nome reaproveita o ID da categoria já gerenciada.
- 29 testes de unidade, navegador e PostgreSQL isolado cobrem persistência antes de ACK, isolamento, repetição, fechamento, caixa fechado, taxa presencial, cupons por patrocinador, agendamento/retirada, negociação, lote parcial e status da interface.
- Advisors: tabelas privadas com RLS sem políticas são intencionalmente inacessíveis ao cliente; RPCs autenticadas fazem checagem de permissão/empresa. Acrescentados índices das FKs de eventos, pagamentos e vínculos iFood.

### Etapas externas ainda não concluídas

1. Executar o roteiro oficial Order + Events no portal, incluindo cancelamento originado no ERP, retirada/agendamento e pagamento presencial. Os testes simulados não equivalem ao relatório oficial.
2. Configurar impressora/Print Agent da empresa e confirmar fisicamente as duas vias. Os dois jobs existentes continuam pendentes; nenhuma impressão foi presumida.
3. Homologar Catalog por ticket com demonstração real dos fluxos e medição de propagação (2 s individual / 100 itens em 10 s). O lote foi testado com transporte isolado; o prazo externo não é garantido por um teste local. Horários por produto (dias, horas e datas) e personalização dos contextos realmente disponíveis têm interface própria. O servidor calcula a disponibilidade em São Paulo e sincroniza mudanças de status na rotina de 30 s. Nenhuma regra foi aplicada aos produtos atuais.
4. Conferir aplicação PDV de produção e permissões no portal após aprovação. A guarda por merchant de teste permanece; não habilitar lojas reais automaticamente.
5. Financial (repasses bancários líquidos) não faz parte de Order/Events. Os relatórios atuais são vendas e pagamentos, não confirmação de depósito bancário.

Referências adicionais: [autenticação](https://developer.ifood.com.br/en-US/docs/food/guides/modules/authentication/intro), [Handshake](https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/handshake-platform), [catálogo](https://developer.ifood.com.br/en-US/docs/food/guides/modules/catalog/endpoints), [critérios Catalog](https://developer.ifood.com.br/en-US/docs/food/guides/modules/catalog/homologation), [política por módulo](https://developer.ifood.com.br/en-US/docs/getting-started/homologation/categories).

O catálogo reserva e conclui até 100 atualizações em chamadas de banco em lote, sem abrir 100 conexões. Falhas transitórias têm tentativas limitadas com backoff; 4xx de validação não são repetidos. Cancelamento reconfirma os motivos vigentes antes do envio, envia `cancellationCode` e `reason` descritivo, conforme validação real da API em 17/11 e trata CAR/CARF sem encerrar o pedido indevidamente. Eventos de acompanhamento do entregador são exibidos separadamente dos estados Order.

O diagnóstico real retornou HTTP 400 / InvalidParameter para corpo contendo apenas reason: cancellationCode é obrigatório. O pedido #7954 foi cancelado pelo SCHEDULER (902) por ausência de confirmação; não comprova cancelamento iniciado pelo ERP. O motor não deve marcar comandos que falharam como confirmados por esse evento.

## Acompanhamento da homologação — 19/11/2026

- Pedidos exibe resumo das confirmações pendentes, prazo de oito minutos no horário de Brasília e diferença entre pedido sem solicitação e solicitação aguardando evento. Agendados também precisam de confirmação no prazo. Nenhuma confirmação automática foi adicionada.
- Situação, cancelamento e histórico permanecem abaixo dos itens. O histórico técnico é carregado sob demanda pela RPC `gastronomia_ifood_historico`, que exige permissão de pedidos e a empresa da sessão; não aumenta a consulta de todos os pedidos do dia.
- Novos comandos de Order conservam o HTTP realmente retornado. Cancelamentos conservam quando o worker consultou os motivos antes do envio; não preenche retornos históricos desconhecidos. O histórico reúne comandos, eventos, ACK, motivo e origem sem credenciais.
- ORDER_PATCHED/OPA exige consultar o detalhe atualizado. Guarda antes/depois e não muda o estado do pedido para cancelado. Antes de importar, atualiza os totais com o novo detalhe. Se já houver atendimento, conserva o registro financeiro original e sinaliza conciliação; bloqueia novos recebimentos, novas etapas de preparo/despacho e fechamento automático. Venda, imposto, caixa e estoque não são estornados automaticamente. A conciliação financeira/fiscal de pedidos já importados continua sendo uma etapa manual; não existe botão que a declare concluída automaticamente.
- Testes: 32 testes unitários; navegador cobre resumo, ausência de comandos automáticos, posição inferior, histórico sob demanda e proteção de parcial; PostgreSQL isolado cobre atualização antes da importação, repetição, snapshot anterior, bloqueio de recebimento/fechamento e isolamento do histórico. Os testes existentes de fluxo, cancelamento, homologação e estabilidade continuam passando.

Na próxima tentativa oficial: confirmar os pedidos gerados na etapa 2, aguardar os eventos de confirmação e ACK, anexar evidência e somente então executar a etapa 3 no UUID indicado pelo assistente. Os eventos reais mostram cancelamentos iniciados no ERP, mas não comprovam qual UUID o avaliador exigiu nas tentativas anteriores. A mensagem genérica sobre logs não comprova ausência de um endpoint de envio de logs. Estas alterações não alteram relatórios antigos nem garantem aprovação.

## Recusa e diagnóstico de cancelamento — 25/11/2026

- Recusar negociação usa os nove códigos de `negotiationReasons` documentados, com seleção obrigatória e validação no servidor. Aceitação e contrapropostas mantêm seus motivos e regras anteriores.
- O histórico distingue solicitação enviada com HTTP 202 de cancelamento confirmado. A comprovação aceita RESTAURANT ou ORDER_API, exige evento processado com ACK na mesma empresa/loja/pedido e um comando local confirmado no horário desse evento. SCHEDULER não comprova cancelamento solicitado pelo ERP.
- Regressões: 24 testes unitários, teste de recusa no navegador, testes existentes de cancelamento e homologação no navegador, e PostgreSQL isolado (`NODE_PATH=/tmp/erp-perf-pg/node_modules node florest-erp/sistema/tests/ifood-recusa-diagnostico.db.cjs`, com PGlite instalado nesse ambiente). Nenhum teste dispara cancelamento na API real. A aprovação continua dependendo do roteiro oficial.

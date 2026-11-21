# Order e Events — revisão de 21/11/2026

Escopo: PDV Food, aplicativo centralizado e loja de testes autorizada. Aprovação automática do iFood ainda depende da execução dos cenários no portal. Catálogo, Financial e Shipping têm escopos próprios; não são liberados por esta alteração.

## Contrato observado

- Polling `/events/v1.0/events:polling`, `x-polling-merchants`, mínimo de 30 segundos, um worker por empresa/loja com lease no banco.
- Persistência durável antes de ACK. ACKs sem confirmação local podem ser recuperados; não se repete automaticamente uma operação de pedido cujo resultado é incerto.
- `POST /order/v1.0/orders/{UUID}/confirm`: HTTP 202 aceita a solicitação. `CONFIRMED` é a evidência da confirmação, com ACK separado.
- Cancelamento: consultar motivos vigentes, selecionar código e descrição, revalidar antes de `POST requestCancellation` com `cancellationCode` e `reason`. HTTP 202 não encerra o pedido. Aguardar `CANCELLED` ou `CANCELLATION_REQUEST_FAILED`. HTTP 204 sem política não é sucesso.
- O cancelamento do cenário precisa corresponder ao UUID indicado no assistente. Cancelamento automático SCHEDULER não comprova solicitação do restaurante.
- Ready/dispatch continuam usando POST, conforme referência de endpoints e chamadas já aceitas pela API. O resumo de homologação apresenta exemplos PUT divergentes; não se troca um transporte comprovado por esse exemplo isolado.
- A página de fundamentos e a de homologação divergem sobre o início do prazo de pedidos agendados. Mantém-se confirmação imediata e aviso conservador de oito minutos da criação; o preparo respeita `preparationStartDateTime`.

## Correções desta revisão

1. Eventos de pedidos já conhecidos não dependem de novo GET para atualizar o estado. Pedidos desconhecidos e ORDER_PATCHED ainda exigem detalhes atuais.
2. Falha de importação local não desfaz a confirmação remota nem a evidência do evento. A importação fica pendente, com erro explícito e nova tentativa controlada.
3. Há tempo reservado para comandos; revisão de vínculos e catálogo ficam depois dos comandos. Revisões repetitivas de todos os pedidos recebidos foram removidas.
4. Cancelamento em andamento bloqueia novas etapas e recebimento presencial, na interface e no servidor.
5. Eventos PRS, atualização de endereço DAR e informativos RPS/DGAC são tratados sem regressão de estado.
6. Negociações são revalidadas na reserva: disputa atual, não resolvida e não expirada. Campos `allowedsAdditionalTime*` e formatos anteriores são aceitos sem criar ofertas não recebidas.
7. Histórico por UUID mostra comando, HTTP, horários reais, evento, origem, aplicativo de origem quando informado e ACK. Campos antigos ausentes permanecem desconhecidos, sem preenchimento retroativo fictício. Copiar diagnóstico é ação explícita e não inclui credenciais nem dados pessoais do cliente.
8. Alterações parciais antes do preparo podem ser conciliadas explicitamente. Recriação dos itens, estoque, totais e pagamentos virtuais ocorre em uma transação; histórico anterior é preservado. Repetir o worker não repete baixas.

## Limites preservados

- Conciliação automática não desfaz pagamento real, venda emitida, documento fiscal nem estoque de itens preparados. Esses casos permanecem bloqueados para revisão financeira/operacional. Não há promessa de conciliação financeira completa do módulo Financial.
- Ações e histórico ficam abaixo dos itens.
- Impressão física depende de impressora e agente configurados. Testes isolados verificam a fila e duas vias, não a saída física.
- Não criar homologação nem movimentar pedidos reais em testes automatizados. Testar o cenário real exige ação do operador e comparação do UUID do assistente.
- Status de conectividade, sucesso dos testes locais e evidência no ERP não equivalem à aprovação do avaliador.

## Verificação

`node --test florest-erp/sistema/tests/ifood-*.test.cjs`

Testes Chromium de acompanhamento, cancelamento, homologação e fluxo. O módulo `tests/ifood-fluxo.db.cjs` recebe o banco PostgreSQL isolado com as migrações aplicadas e testa falha de estoque, ACK, conciliação, permissões, endereço e expiração. Nunca aponta ao banco de produção.

## Fontes

- https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/homologation
- https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/endpoints
- https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/cancellation
- https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/events
- https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/handshake-platform
- https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/scheduled-orders
- https://developer.ifood.com.br/en-US/docs/food/guides/modules/events/intro
- https://developer.ifood.com.br/en-US/docs/getting-started/documentation/best-practices

Pesquisa complementar: relato em primeira pessoa de Felipe Bufelli sobre reprovação com mensagem genérica de logs e consumidores concorrentes: https://dev.to/felipebufelli/integracao-com-o-ifood-o-bug-que-ficou-escondido-por-semanas-e-a-investigacao-que-terminou-numa-30hf . Não comprova defeito no avaliador deste ERP. O intervalo de 15 segundos citado no relato não foi adotado; prevalece o mínimo oficial de 30 segundos.

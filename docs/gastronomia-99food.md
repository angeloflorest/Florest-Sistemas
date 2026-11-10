# 99Food no Gastronomia — preparação

Configuração exclusiva do Gastronomia. Estado fixo `preparacao`, sem credenciais no navegador, worker, cron, publicação de cardápio ou recebimento real. A configuração é persistida por empresa via RPC autorizada com `gastronomia_configurar`; não altera vendas, produtos, fotos ou outros módulos.

## Portal e processo oficial

Consultado em 10/11/2026: https://developer-food.99app.com/pt-BR/openapi/index

Seções: Basic Process Overview; Before Coding; Before Going Live; Authorization Module; Menu Module; Orders Module; Webhooks; API Rate Limit; Authentication & Signature Mechanism; Open Delivery Introduction.

A Florest deve concluir contato comercial, NDA e qualificação, criar aplicativo e loja de testes, testar, obter liberação de produção e iniciar piloto. Contato: 99FoodTechSupport@didiglobal.com. Recomenda-se protocolo nativo 99Food; o Open Delivery oferecido pela plataforma tem escopo diferente.

## Configuração já disponível

- Nome da loja, Shop ID textual (sem perder precisão de IDs de 64 bits), AppShopID, ambiente e intenção de sincronizar cardápio.
- Vínculos de app_item_id de produtos e adicionais com produtos ativos da mesma empresa, com busca, desativação e controle de concorrência.
- Identificação futura na aba Pedidos: iFood vermelho; Cardápio Digital azul; 99Food amarelo. Sem aba operacional nova. Mesas permanece independente.
- Reservas privadas para eventos e comandos. RPC não permite ativação, credenciais, recebimento de eventos ou criação de pedidos.
- Adaptador de servidor sem consumidor: bloqueado por padrão, consulta de token/renovação, consulta de cardápio/pedido e disponibilidade, assinatura de webhook sobre bytes originais e preservação de números longos. Testado com respostas simuladas, não homologado.

## Requisitos pendentes para conexão real

1. Configurar App ID, App Secret, tokens por loja e renovação exclusivamente em armazenamento secreto do servidor, com separação dos ambientes. Autorizar loja via link oficial com superadministrador. Conferir Shop ID ↔ AppShopID e empresa. Cada loja pode estar vinculada a um aplicativo de produção: planejar migração se já houver integrador.
2. Implementar o consumidor durável de webhooks HTTPS: validar `didi-header-sign` (MD5 do corpo bruto + App Secret), rotear pela loja autorizada, persistir antes de responder `errno:0` dentro de 6s. Deduplicar e reconciliar eventos, inclusive fora de ordem. Não ativar o index.ts de preparação como receptor operacional.
3. Converter pedidos para Gastronomia e validar estados/valores na sandbox. Preservar `order_id` e `order_index`, preços, descontos, complementos e diferenças entre entrega da plataforma, própria e retirada. O schema de atendimentos ainda não recebe origens externas; a liberação futura precisa de importador específico e controle de autoria.
4. Implementar confirmação, pronto, retirada/entrega, cancelamentos e negociações conforme modalidade. Persistir comandos, tentativas, request IDs e resultados incertos; reconciliar antes de repetir operações que possam duplicar efeitos.
5. Distinguir pagamento pela plataforma e dinheiro efetivamente recebido. Se habilitada a antecipação em dinheiro pelo entregador 99Food, implementar `payConfirm` e seus requisitos; não registrar dinheiro apenas pela forma de pagamento informada no pedido.
6. Vincular cardápio existente antes de publicar. `GET /v3/item/item/list` não produz estrutura pronta para reenvio. `POST /v3/item/item/upload` **substitui** o cardápio e é assíncrono: validar primeiro em testes e acompanhar `uploadMenuTaskStatus` ou `/v1/item/item/getMenuTaskInfo`. Não há botão para substituição completa nesta preparação.
7. Para pausas diárias usar `/v3/item/item/updateItemStatus` (1 disponível, 2 indisponível); conferir listas `success` e `failed`, não marcar todo lote como sucesso pelo HTTP. Atualização individual por `/v3/item/item/updateItem` exige campos obrigatórios e não atualiza promoções. Implementar fotos via upload oficial e auditoria; validar grupos e limites de escolha.
8. Concluir fila de sincronização de catálogo com estados pendente/confirmado/erro por item, recuperação de falhas e limites da API. Sem publicação automática só por marcar a intenção de sincronização.
9. Integrar impressão duas vias com chave idempotente, estoque e caixa após validar o fluxo em testes. Não repetir impressão ao repetir evento. Liberar somente depois da aprovação e piloto.

## Limites relevantes documentados

Token GET/refresh: 1/30s; renovação tem cooldown de 2min. Cardápio listar/enviar: 1/min; status de tarefa: 100/min; atualizar item: 10/5s; disponibilidade: 10/s. Webhooks têm timeout de 6s. Respeitar limites por aplicação também em múltiplos workers (o adaptador isolado não é um limitador distribuído).

Fotos: JPEG/JPG/PNG, menos de 10MB, dimensões de 150 a 3000px. Usar o URL retornado pelo serviço oficial para atualizar a foto. Limites padrão do envio: 20 categorias, 4000 itens, 400 principais e 500 grupos; ampliações dependem da equipe da 99Food.

## Verificação

`node --test florest-erp/sistema/tests/99food-preparacao.test.cjs`

`node florest-erp/sistema/tests/99food-browser.cjs`

Não confundir testes simulados com homologação ou disponibilidade de pedidos reais.

# iFood — preparação exclusiva do Gastronomia

Implementado em 09/11/2026, sem cadastro de desenvolvedor, CNPJ, credenciais ou autorização de loja. Esta entrega é a preparação da integração; não é uma integração homologada e não basta inserir credenciais para receber pedidos reais.

## Disponível no ERP

Gastronomia → iFood, somente para quem já pode configurar Gastronomia. A API pública executa como chamador e delega a uma função privada que verifica empresa ativa, módulo contratado, permissão de visualizar/configurar e empresa esperada; alterar o navegador não concede acesso.

- Nome, ID opcional da loja e ambiente planejado, com versão para evitar sobrescrever outro terminal.
- Vínculos por código externo, separando produtos e adicionais. Desativação preserva o registro.
- Simulador local de pagamento online, dinheiro com troco e evento duplicado. Não envia dados ao iFood e não cria atendimento, venda, recebimento, estoque ou impressão.
- Estruturas privadas para configuração, vínculos, reserva única por loja/pedido com valores financeiros separados, fila de eventos deduplicada por empresa/evento e fila de comandos com chave única por empresa.
- Contrato de pedido com identificação externa, itens, adicionais, observações, agendamento, entrega, pagamentos e benefícios. Valores em centavos; divergências e produtos sem vínculo exigem revisão.
- Adaptador de servidor testado com transporte simulado: autenticação centralizada, renovação por `expiresIn`, consulta de pedidos, polling limitado às lojas permitidas e ACK. Assinatura HMAC-SHA256 validada sobre os bytes originais com Web Crypto.

## Barreiras da preparação

O estado do banco aceita somente `preparacao`. Nenhuma opção da interface ativa a integração. Não há cron, worker, credencial armazenada, concessão de acesso de lojas ou abertura automática de estabelecimento.

`supabase/functions/gastronomia-ifood/index.ts` é um receptor bloqueado preparado em código (POST retorna 503; não confirma recebimento e não anuncia presença). Não é cadastrado como webhook no iFood. O adaptador permanece fora dos arquivos públicos da interface e inicia desativado. A chave secreta não tem campo no navegador.

O normalizador não publica dados nas tabelas operacionais. As regras atuais de origem/autoria de atendimentos, caixa, estoque, pedidos manuais, cardápio e Print Agent foram preservadas. Não há mudanças nos módulos Bar, PDV, Rotisseria ou outros.

## Como testar agora

1. Abrir Gastronomia → iFood e salvar o nome da loja sem preencher ID ou credenciais.
2. Vincular um código externo a um produto desta empresa. `DEMO-001` corresponde ao produto fictício do simulador.
3. Usar os exemplos online e dinheiro com troco. R$ 35 online não entra na gaveta; R$ 35 em dinheiro aparece como a cobrar, com R$ 15 de troco para R$ 50.
4. Simular confirmação repetida: uma confirmação, sem pedido, baixa ou impressão duplicada.

Verificações automatizadas:

```sh
node --test florest-erp/sistema/tests/ifood-preparacao.test.cjs
node florest-erp/sistema/tests/ifood-browser.cjs
```

O teste de navegador requer Playwright e Chromium; usa RPC simulada. Os testes não usam dados ou credenciais reais de lojas.

## Etapa futura, após o cadastro

1. Aplicação Food/PDV centralizada, CNPJ definitivo, credenciais protegidas no servidor, lojas de teste e autorização por merchant. Verificar a titularidade e homologação com o iFood.
2. Implantar receptor autenticado por assinatura antes do parse, validar merchant por empresa e persistir evento antes de responder. Webhook não utiliza o ACK do polling. Presença/KEEPALIVE deve anunciar somente lojas explicitamente habilitadas e saudáveis.
3. Implantar worker durável com reserva, tentativas limitadas, atrasos, dead-letter/revisão e monitoramento. Consumir eventos duplicados/fora de ordem e mudanças/cancelamentos/negociações. Polling principal respeita 30 segundos; fallback do webhook segue a configuração homologada. ACK somente depois da persistência durável, inclusive de eventos desconhecidos.
4. Validar os contratos reais e divergências entre exemplos da documentação e referência de API. O adaptador usa o módulo Events `/events/v1.0/events:polling` e `/events/v1.0/events/acknowledgment`; não mistura endpoints de Order, Logistics ou Groceries.
5. Adaptar o importador com origem/autoria reais `ifood`, vínculo único merchant/pedido, instantâneo de preço e composição, sem atribuir usuário fictício. Resolver produtos/adicionais sem vínculo antes de aceitar e baixar estoque. Preservar histórico e distinguir eventos de cancelamento, atualização parcial e negociação.
6. Enviar confirmar, iniciar preparo, pronto e despacho conforme a modalidade; consultar motivos de cancelamento e tratar Handshake. `202 Accepted` não é confirmação final. Timeout de comando deve virar resultado incerto e ser reconciliado antes de qualquer repetição.
7. Financeiro: separar pré-pago online, pendência offline e dinheiro efetivamente recebido. Não considerar todo CASH como recebido; não cobrar novamente online; preservar bandeira, cupons/patrocinadores, taxas e repasses. Taxa de entrega ou serviço não implica saldo físico. Não estimar taxas/repasse a partir do total do pedido.
8. Imprimir duas vias na impressora única da Gastronomia após confirmação efetiva, deduplicadas por pedido/lote/evento; reimpressão explícita. Definir o que cada via pode conter conforme as regras atuais de privacidade do iFood.
9. Homologar entrega própria/iFood, retirada, agendamento, adicionais, cupons, múltiplos pagamentos, cancelamentos e negociações. Testar falhas e reconciliação, inclusive navegador fechado. Definir retenção de dados e monitoramento antes de produção.
10. Somente então liberar ativação controlada por empresa. Sincronização de cardápio/fotos/preços é uma etapa própria (Catalog), não foi ativada nesta entrega.

## Fontes oficiais consultadas

- [Autenticação centralizada](https://developer.ifood.com.br/en-US/docs/food/guides/modules/authentication/centralized)
- [Estrutura dos pedidos e pagamentos](https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/details)
- [Assinatura do webhook](https://developer.ifood.com.br/en-US/docs/food/guides/modules/events/webhook-signature)
- [Comportamento do webhook](https://developer.ifood.com.br/en-US/docs/food/guides/modules/events/webhook-overview)
- [Polling e ACK](https://developer.ifood.com.br/en-US/docs/food/guides/modules/events/polling-overview)
- [Endpoints de pedidos](https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/endpoints)
- [Homologação de pedidos](https://developer.ifood.com.br/en-US/docs/food/guides/modules/order/homologation)

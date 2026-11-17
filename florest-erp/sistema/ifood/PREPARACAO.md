# iFood na Gastronomia — conexão de testes

Atualizado em 16/11/2026. A preparação de 09/11 foi ampliada para conexão centralizada no servidor. A liberação inicial usa a empresa autorizada SPETTOS DAY e exclusivamente o merchant de teste. Não habilita lojas de produção nem outras empresas.

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

Complementos até o terceiro nível preservam árvore, códigos e quantidades e são resolvidos no estoque da mesma empresa. Composição ambígua, níveis adicionais e preço fracionado sem representação exata ficam em revisão. Negociações com motivo específico de aceitação devem ser respondidas no Gestor iFood; a interface sinaliza essa exigência. Eventos não reconhecidos são guardados e sinalizados. A sincronização de catálogo e a conciliação de repasses via Financial são escopos próprios e não foram ativadas.

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

Atualização dos complementos: taxas adicionais do iFood são preservadas no total original e demonstradas separadamente; não entram na receita/fiscal da empresa. Em pedidos pagos online, o valor da empresa é rateado entre os pagamentos com ajuste determinístico de centavos, preservando os valores originais recebidos da API. Taxa de plataforma com cobrança offline fica em revisão para conciliação.

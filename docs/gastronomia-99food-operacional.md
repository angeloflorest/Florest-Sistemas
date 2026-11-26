# 99Food — conexão da loja de teste (26/11/2026)

A qualificação da empresa está aprovada no portal; o aplicativo disponível é **de teste**. Não há credenciais de aplicativo de produção nem autorização de loja real. O receptor e o executor desta atualização ficam limitados ao vínculo já existente `florest-gastronomia-teste-01` / Florest Gastronomia Teste, na empresa Spettos Day. As demais empresas e integrações não são ativadas.

## Fluxo publicado

- Webhook já cadastrado: `gastronomia-99food-sandbox`. MD5 dos bytes originais + segredo, comparação constante, 256 KiB máximos, validação de app/loja/IDs longos, persistência antes de errno:0. Eventos repetidos são deduplicados por hash. Eventos de atualização, solicitações e notificações sem pedido não recebem mais 422 apenas por não serem orderNew.
- Executor `gastronomia-99food-sandbox-aceite`: autentica usuários pelo RPC com JWT/empresa ativa/permissões. Worker automático tem HMAC próprio, validade de 90s, reserva de execução e limites persistentes. Nenhum segredo chega ao navegador.
- Renovação automática: GET token; 10102 → refresh; nova consulta respeita 30s; refresh respeita 2min. Cache e limites no banco funcionam entre instâncias. O cron prepara a autenticação sem esperar que um pedido falhe.
- Pedidos na aba **Pedidos**, seção amarela **99Food · Integração de teste**: cliente/endereço quando fornecidos, produtos e complementos recursivos, observações, valores em centavos, modalidade, estados atuais, eventos e histórico de comandos/protocolos.
- Ações: confirmar, pronto, despacho próprio com entregador e prazo, entregue, conclusão por código do cliente, retirada, cancelamento com motivos oficiais e resposta às solicitações de cancelamento/reembolso recebidas.
- Ações persistidas com chave idempotente. Consultar estado antes do envio; erro de transporte depois de POST fica incerto, sem repetição cega. Um comando ativo por pedido. Estado terminal não reabre por consulta antiga. A API aceitar um comando não é confundido com pedido concluído.
- Atualização local em 15s enquanto a seção está ativa, sem consultar a API a cada navegador. O worker consulta no máximo quatro pedidos por execução e não inicia mais de uma execução em 10s. Cron a cada 30s; reconciliação de pedidos ativos a cada 2min, por até três dias. Pedidos 12004 deixam de ser consultados repetidamente.
- Impressão de conferência pelo navegador, identificada **PEDIDO DE TESTE**. Não dispara impressão automática nem cria vendas, estoque ou caixa para pedidos simulados. Pagamentos exigidos pela 99Food são exibidos para conferência, sem presumir recebimento em dinheiro.

## Duas modalidades de teste — diferença obrigatória

A documentação **Tools Introduction > Sandbox Environment** informa que a ferramenta do portal injeta notificações, mas não permite testar as respostas pela API. **Testing the Integration > Using a Test Store** orienta usar uma conta de cliente de teste no C-App para criar pedidos cujo ciclo possa ser confirmado/cancelado pela integração. Não insistir em confirmar uma injeção que a API não reconhece.

Para teste completo: solicitar à equipe 99Food uma conta de cliente de teste; entrar no app, selecionar endereço próximo à loja em Goiânia (Avenida T 2, 1922, Setor Bueno), criar pedido na Florest Gastronomia Teste e confirmar no ERP em até cinco minutos. O operador usa o aplicativo oficial, não o botão Criar da ferramenta de injeções, para essa validação.

Não afirmar homologação com base em testes simulados locais. A confirmação real depende de um pedido válido criado na conta de testes. Não há autoaceite implícito.

## Antes da produção

Concluir os cenários com conta de cliente de teste e aprovação da 99Food; criar/obter aplicativo de produção e suas credenciais; autorizar a loja real e validar os vínculos por empresa. A versão atual permanece restrita à loja de teste. Catálogo, fotos/publicação de cardápio, baixa financeira/estoque e impressão automática operacional não foram ativados por esta atualização. São necessários validação de pedidos reais de teste, regras financeiras e aprovação antes de conectar os efeitos comerciais. Não reutilizar o segredo de teste em produção.

## Fontes oficiais consultadas

Portal: https://developer-food.99app.com/pt-BR/openapi

Conteúdos oficiais recuperados pelo serviço de documentação do próprio portal:
- Tools Introduction: node 1879; Testing the Integration: 1885.
- Authorization Module / Get / Refresh: 1913, 1929, 1931.
- Webhooks / Rate Limit / Signature: 1921, 1923, 1925.
- Orders/Webhooks/Detail/Confirm/Ready/Delivered/Cancel: 1919, 1981, 1983, 1985, 1987, 1989, 1991.
- Cancellation/Refund requests: 1995, 1997.
- Self delivery dispatch/delivered/code: 2005, 2007, 2209; pickup: 2215.

## Validação local

```
node --test florest-erp/sistema/tests/99food-operacional.test.cjs florest-erp/sistema/tests/99food-webhook.test.cjs
NODE_PATH=/tmp/erp-perf-pg/node_modules:$NODE_PATH node florest-erp/sistema/tests/99food-operacional.db.cjs
node florest-erp/sistema/tests/99food-operacional.browser.cjs
node --test florest-erp/sistema/tests/99food-preparacao.test.cjs
node florest-erp/sistema/tests/99food-browser.cjs
```

Verificar depois da publicação: status/versão das duas funções, assinatura do cron, token válido e data de validade (sem expor o token), cron ativo, ACL de tabelas e RPCs, conteúdo servido pelo domínio. Para comprovar confirmação/entrega/cancelamento reais, acompanhar pedido válido no portal **e** ERP; só o HTTP 200 do webhook não comprova o ciclo.

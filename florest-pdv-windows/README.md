# Florest PDV Windows — início do desenvolvimento

Projeto separado na branch `florest-pdv-windows`, sem mudanças na produção.

## Referência obrigatória

O PDV original está em `florest-erp/sistema/index.html`. Reproduzir seu layout, atalhos, caixa, vendas, clientes, formas de pagamento e permissões. Não remover funcionalidades. Remover apenas a opção **Sair do PDV** e o fluxo de emissão fiscal no executável. Após finalizar uma venda, oferecer **Imprimir comprovante não fiscal** ou **Cancelar impressão**, retornando imediatamente à próxima venda.

## Estado atual

Base inicial Electron + SQLite, sem conexão ao ERP e **sem fluxo de venda ainda**. O banco local cria cache de produtos/clientes, vendas locais e cursor de sincronização. As ações de sincronização estão intencionalmente desativadas até a implementação segura com autenticação, empresa_id, idempotência e regras reais do ERP.

## Execução local de desenvolvimento

Com Node.js e ambiente Windows: `npm install`, depois `npm start`. O pacote nativo `better-sqlite3` pode exigir rebuild compatível com Electron. **Ainda não é um instalador para clientes.**

## Próximas entregas

1. Mapear e reaproveitar o PDV original (incluindo atalhos, abertura/fechamento, pagamentos, comandas e regras).
2. Implementar operações locais transacionais e numeração segura por empresa/terminal.
3. Implementar envio idempotente de vendas e recebimento incremental de cadastros com autenticação e RLS.
4. Impressão de comprovante não fiscal, testes offline/reconexão e empacotamento Windows.

Não emitir NFC-e offline nem alterar tabelas de produção sem revisão e aprovação.

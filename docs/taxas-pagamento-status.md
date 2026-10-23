# Controle de taxas de pagamento — em desenvolvimento

Não aplicar esta migração isoladamente em produção. A sintaxe foi validada em transação revertida; testes funcionais e clientes ainda estão pendentes.

Escopo autorizado: configuração por empresa em Financeiro; Pix e cartões débito/crédito à vista; Visa, Mastercard, Elo, American Express, Hipercard e Diners; controle inicialmente desativado; bandeira solicitada somente com regras configuradas; bruto integral no caixa e taxas como Despesa administrativa de cartões; snapshot imutável por pagamento; mesma regra no ERP, Bar e PDV Windows offline.

A migração proposta cria versões de configuração e registro idempotente de taxas, consolida despesas diárias e integra as rotinas existentes de vendas, comandas, Bar e contexto desktop. Cancelamentos e estornos retiram a contribuição correspondente. Nenhum dado de produção foi alterado por este trabalho.

Antes de publicar: testes transacionais de isolamento entre empresas, arredondamento, snapshots, cancelamentos, estornos e reenvio desktop; implementar telas web e desktop, persistência dos metadados na fila local e testes; revisar segurança; aplicar migração; publicar ERP; gerar instalador Windows e atualizar portal. O executável necessita uma atualização inicial; configurações posteriores serão recebidas por sincronização.

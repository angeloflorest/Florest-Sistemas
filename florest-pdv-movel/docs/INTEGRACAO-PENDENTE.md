# Integração de caixa móvel — proposta, sem execução

## Evidência consultada somente em leitura

- `../florest-erp/sistema/index.html`: `obterEmpresaId`, `carregarPerfilEMostrarApp`,
  `pdvConsultarProdutos`, `buscarProdutoPorCodigo` e controle de caixa Migration 032.
- `../florest-erp/banco-de-dados/001_estrutura_banco.sql`: perfil possui um `empresa_id`
  por usuário. Não foi encontrado um fluxo de seleção multiempresa para essa conta.
- `../florest-erp/banco-de-dados/002_funcoes_banco.sql`: `pdv_produtos_consultar` deriva
  a empresa de `private.exigir_empresa_ativa()` e exige `private.perm('pdv')`.
- PDV à vista chama `registrar_venda_mista` com cliente/itens/pagamentos/CPF; não informa
  chave idempotente ou caixa móvel. O caixa é identificado por tipo `PDV`, não dispositivo.
- Leitura do esquema remoto via PostgREST/chave pública do ERP: HTTP 401. Não houve
  autenticação de cliente, acesso privilegiado, DDL, migração ou operação de venda real.

## Por que a escrita permanece bloqueada

Um toque bloqueado no botão evita concorrência dentro da tela, mas não resolve uma
venda confirmada no servidor cuja resposta se perdeu. Reenviar poderia duplicar venda
e baixa de estoque. Também não deve ser aberto/fechado o caixa do computador pelo celular.
Não é seguro expor essas operações simplesmente trocando o nome da tela.

## Trabalho que exige autorização específica fora do aplicativo

1. Confirmar no banco atual o contrato e o suporte a uma sessão de caixa móvel separada
   por empresa, vinculada ao operador, com no máximo um caixa móvel aberto por empresa.
2. Definir operações autenticadas de consulta, abertura e fechamento dessa sessão,
   com RLS/permissões equivalentes ao ERP e totais calculados no servidor.
3. Reutilizar a transação de venda/estoque existente, acrescentando associação explícita
   ao caixa móvel e idempotência por empresa/operação, com chave preservada antes do envio.
   Uma repetição retorna a mesma venda; nunca cria outra baixa. Permitir consultar o
   resultado de uma tentativa após timeout/reabertura, sem vendas offline.
4. Fornecer formas de pagamento autorizadas e totais/estoque/preços confirmados no backend.
   Dinheiro/Pix/cartões são registros de recebimento externo, sem cobrança integrada.
5. Validar transações concorrentes, sessão expirada, falta de estoque, empresa diferente,
   perda de resposta, fechamento simultâneo e reconciliação do histórico.

Os nomes e assinaturas dessas novas operações precisam ser definidos na tarefa de backend;
este aplicativo não as presume nem chama funções inexistentes. Após aprovação e implementação,
integrar as telas e executar a matriz de testes real antes de liberar vendas.

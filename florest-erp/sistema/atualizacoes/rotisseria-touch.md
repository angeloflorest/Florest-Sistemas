# Rotisseria: atendimento por toque e recebimentos fracionados

A comanda abre uma sobretela com a área disponível do navegador. Produtos principais vêm das configurações da Rotisseria, com fotos e nomes maiores. Quando os produtos não cabem, a navegação usa páginas e botões de toque; não exige arrastar uma barra de rolagem. O campo de pesquisa encontra os demais produtos. A janela de peso aparece por cima e retorna à mesma comanda após confirmar. Em telas estreitas, o botão Itens e recebimentos alterna a área; no computador, produtos e relatório aparecem lado a lado.

Entrar numa comanda vazia não a pinta de ocupada. Sair fecha a sessão vazia; sessões antigas sem itens também aparecem livres. Com consumo, o cartão mantém o saldo pendente até a quitação.

Removidos os indicadores de dispositivo e o botão Atualizar do cabeçalho. A atualização automática permanece. A proteção de recebimento no servidor é preservada: abrir o caixa registra o computador; a configuração permite transferir o recebimento para outro computador. O tablet não recebe automaticamente ao abrir a tela.

O histórico de caixas é recolhido por padrão e consultado somente ao expandir. Vendas aparecem em linhas. As configurações identificam explicitamente os produtos dos botões e têm Salvar configurações acessível antes da lista de fotos. Cadastro, preços, unidades e tributações permanecem no cadastro de produtos do ERP.

## Pagamentos

Botões para Dinheiro, Débito, Pix, Crédito e Nota a Prazo; nenhum seletor de forma de pagamento. Mostra total consumido, total pago, saldo e pagamentos registrados. Cada confirmação possui chave de idempotência. Pagamento parcial conserva a comanda; saldo zero consolida uma única venda e libera o número. Troco é permitido somente em dinheiro e limitado ao excedente do saldo.

O estoque é reservado uma vez no primeiro recebimento. Itens posteriores dão baixa ao lançar; cancelamentos devolvem a quantidade e não podem reduzir o consumo abaixo do já pago. Os recebimentos reais ficam ligados aos seus caixas, inclusive quando a comanda atravessa dois turnos. A consolidação não repete a baixa nem os valores de caixa. Vendas anteriores continuam com seus vínculos e resumos.

Nota a prazo exige cliente e vencimento e converte o saldo restante em um título real do Financeiro. Não é dinheiro recebido. A única integração compartilhada acrescentada é o reconhecimento da origem `rotisseria` em `private.contas_receber_tipo_caixa`, mantendo intactas as expressões das outras origens e suas regras de cobrança. Não altera telas nem emissores dos outros módulos. O emissor fiscal central foi preservado; nenhuma nota real foi transmitida nos testes. NFC-e de venda com combinação de recebimento e saldo a prazo requer validação fiscal específica, pois o emissor central valida a soma dos pagamentos monetários.

## Verificações

- Dois navegadores: abrir/sair de cinco comandas vazias, 20 produtos, pesquisa, peso sobreposto, atualização compartilhada, pagamento parcial em dinheiro e quitação em Pix, liberação e configurações de cinco ícones.
- Layout verificado em 820×1000, 1024×600 e 768×1024, sem rolagem na seleção de produtos.
- SQL em transação com ROLLBACK e empresa/usuário de teste isolados: parcial, reenvio, reserva de estoque, acréscimo/cancelamento, dois caixas, consolidação única, título a prazo e cobrança pelo Financeiro.
- Scripts e estilos alterados apenas na Rotisseria. Nenhum arquivo de interface do Bar, Gastronomia, PDV ou Financeiro foi modificado.

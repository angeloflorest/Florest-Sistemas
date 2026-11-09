# Rotisseria: impressão da comanda e confirmações

Removidos o tooltip que repetia o nome do produto e os avisos rotineiros de item lançado, pagamento registrado e configurações salvas. Erros e situação fiscal continuam visíveis uma única vez no diálogo ativo ou na tela principal, sem duplicação no fundo.

Imprimir comanda fica na área de produtos/recebimentos da comanda. No tablet, acessar Itens e recebimentos. A opção oferece impressão pelo navegador e envio à impressora cadastrada na Rotisseria pelo Print Agent. O documento inclui todos os produtos não cancelados, quantidades, preços, totais, valor já pago e saldo; é conferência não fiscal e não encerra a comanda.

A ação nova é exclusiva de `private.rotisseria_rpc`, com a autorização e a empresa ativa existentes. A prévia não cria jobs; o envio usa a impressora própria da Rotisseria e chave de idempotência. Mais de 200 linhas usam o navegador para evitar o limite do leitor térmico existente. Nenhuma atualização do executável ou de outro módulo foi necessária.

A sincronização Realtime existente foi preservada. O teste em dois navegadores mantém a mesma comanda aberta, lança itens nos dois sentidos e verifica os totais sem perder o peso em digitação. A atualização de segurança de 60 segundos permanece quando a tela está visível.

Verificação: HTML de impressão com mais de 200 linhas e nomes maliciosos escapados; impressão do navegador em iframe isolado; fila com envio único; ausência de faixas de confirmação e preservação de erro real. SQL em empresa/usuário de teste isolados, encerrado com ROLLBACK: lista, exclusão de cancelados, valores, empresa, impressora própria, reenvio e nenhuma alteração de estoque, pagamentos ou venda. Impressão física depende do equipamento e do Print Agent do cliente.

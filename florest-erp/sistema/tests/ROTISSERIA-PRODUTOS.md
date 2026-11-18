# Produtos da Rotisseria

Rotisseria → Produtos possui Combos e Produtos compostos. Fotos fica em uma aba própria do módulo. O catálogo e as receitas pertencem à empresa e à Rotisseria; os produtos físicos e o estoque são os existentes do ERP.

- Combo: preço fixo do título comercial, até 10 produtos principais e 10 acompanhamentos. Todos entram automaticamente; não soma preços dos componentes. Não há limite total de 20 combos; a listagem é paginada.
- O consumo é configurado no cadastro, na unidade do produto: 400 g de um produto em KG = 0,400. Acompanhamento composto usa o número de porções da receita e apresenta as escolhas na venda.
- Composto: componentes fixos (com opção de baixar estoque) ou grupos de escolhas, conforme a lógica dos módulos existentes. Não permite ciclos ou composição recursiva; apenas combo → acompanhamento composto → produtos físicos.
- Na venda do combo não há quantidade para digitar; cada confirmação lança um combo. Quantidades de consumo e preços individuais dos componentes não aparecem no comprovante.
- Baixa ocorre no primeiro recebimento, seguindo o fluxo atual da Rotisseria. Lançamentos posteriores a pagamento parcial baixam na inclusão; cancelamentos devolvem a composição daquele lançamento. A receita registrada no item permanece mesmo se o cadastro mudar.
- Impressão não fiscal utiliza linhas descritivas sem preços nem quantidades individuais. Cada linha respeita o limite do Print Agent existente. Acima de 200 linhas, imprimir a comanda pelo navegador.
- Nome, unidade, preço e tributação de um título já cadastrado continuam no cadastro central de Produtos. Ao criar um título novo pelo módulo, informe nome e preço fixo; revise a tributação no cadastro central antes de emissão fiscal.

## Validação

`ROTISSERIA_BROWSER=/caminho/playwright node --test florest-erp/sistema/tests/rotisseria-produtos.test.cjs florest-erp/sistema/tests/rotisseria.test.cjs`

`rotisseria-produtos.sql`, `rotisseria-parciais.sql` e `rotisseria-impressao.sql` são executados dentro de BEGIN/ROLLBACK. Criam empresas e usuários fictícios isolados e não deixam cadastros, estoque, vendas, caixa ou impressão persistidos. O teste de permissões usa um funcionário separado, preservando o proprietário exigido pelo ERP.

Foram validados preço fixo, acompanhamento composto, consumo em KG, reenvios, pagamento parcial, cancelamento, composição histórica, finalização, fotos/destaques, paginação, limite por receita, permissões e isolamento entre empresas. Testes de navegador usam RPCs simuladas; não foi realizada impressão física.

# Cardápio digital da Rotisseria

Configurações → Cardápio digital permite escolher produtos disponíveis, ativar/pausar pedidos, copiar o link geral da loja e baixar o QR Code correspondente. Não existe vínculo com mesa. Fotos são lidas da Rotisseria, com compatibilidade com as fotos antigas dos destaques; não há novo upload obrigatório.

O cliente informa nome e telefone, seleciona peso em gramas para produtos em KG, produtos por unidade ou combos com preço fixo e escolhas de acompanhamento composto. O valor e o consumo são validados no servidor. Não há cobrança on-line nem criação automática de cliente no cadastro central.

Pedidos digitais criam atendimentos de origem `cardapio`, com numeração própria e crescente, sem ocupar ou limitar as comandas presenciais. O caixa usa os mesmos lançamentos, recebimentos parciais, cancelamentos e impressão térmica da Rotisseria. A baixa de estoque permanece no primeiro recebimento, usando a composição registrada no item.

A tela coloca os atendimentos em uso antes das comandas vazias, mantém os números visíveis e usa amarelo mais forte nos ocupados. As comandas presenciais são configuráveis entre 1 e 50; pedidos digitais não têm esse limite.

## Acesso e reenvios

- Página pública independente em `rotisseria-cardapio.html#loja=TOKEN`; o QR é gerado localmente com qrcode-generator 1.4.4 (MIT), sem serviço externo.
- Edge Function `rotisseria-cardapio` faz a ponte pública. JWT é dispensado especificamente neste endpoint, que autentica a loja pelo token de 64 caracteres validado no banco; nenhuma chave de servidor vai para o cliente.
- RPC pública de banco é exclusiva de `service_role`; tabelas e funções internas não são acessíveis por `anon`/`authenticated`.
- Catálogo retorna somente produtos permitidos, nomes, fotos e dados comerciais necessários. Não retorna estoque, custos nem dados de clientes.
- Chave de envio e conteúdo idêntico recuperam o mesmo pedido. Resultado incerto conserva o envio no navegador e impede alterar o carrinho; acompanhamento requer o segredo retornado àquele cliente.
- Limites por loja/IP/ação, catálogo paginado e pedido de até 30 itens. IP fica somente como hash, em contadores com limpeza dos registros antigos.
- A origem pública é registrada explicitamente; não se simula sessão de funcionário ou proprietário para receber pedidos.

## Validação

`ROTISSERIA_BROWSER=/caminho/playwright node --test florest-erp/sistema/tests/rotisseria-cardapio.test.cjs florest-erp/sistema/tests/rotisseria.test.cjs florest-erp/sistema/tests/rotisseria-produtos.test.cjs`

`rotisseria-cardapio.sql` usa empresas e usuários fictícios dentro de BEGIN/ROLLBACK: fotos existentes, peso de 500 g, repetição, preço adulterado, 55 pedidos mais combo digital com escolha, 50 comandas independentes, caixa, estoque, impressão, acompanhamento por segredo e permissões. Os testes descartam todos os registros criados. Não enviam impressão física, documentos fiscais ou pedidos reais de clientes.

## Tema, vídeos e organização

O cardápio público usa tons de madeira, marrom, preto e dourado, inspirados na referência do Casarão da Fumaça. Não existe controle de aparência no painel.

Dentro de Cardápio digital há Produtos e link, Vídeos e Categorias e subcategorias. Cada vídeo é enviado separadamente (MP4/WebM, até 25 MB por arquivo), sem duração fixa. No cliente, aparecem lado a lado, também no celular, com autoplay, muted, playsinline e loop, sem controles de pausa. A filtragem dos produtos não recria os elementos de vídeo, preservando a reprodução. O espaço só aparece quando houver vídeos cadastrados.

O armazenamento de vídeos usa um bucket próprio da Rotisseria. Os arquivos são públicos para exibição no cardápio; o upload e a exclusão exigem sessão da empresa, módulo e permissão de configuração. Não há acesso de escrita anônimo. Cada posição usa um nome aleatório novo, sem sobrescrever objetos. Um envio pendente conserva o arquivo para repetir o salvamento; o arquivo anterior é removido somente depois da confirmação do novo vínculo.

As categorias e subcategorias pertencem somente à Rotisseria. Há dois níveis; ciclos e vínculos entre empresas são recusados. O vínculo por produto fica em Produtos e link. Selecionar uma categoria principal inclui suas subcategorias; Todos mantém os produtos sem categoria visíveis. Excluir uma categoria limpa o vínculo, preservando cadastro, fotos, preço e estoque do produto.

`rotisseria-midia.test.cjs` verifica dois vídeos reais de 10 segundos, a volta automática ao início, ausência de controles, disposição lado a lado, continuidade após filtros e os controles administrativos. `rotisseria-midia-categorias.sql` verifica filtros, relações, isolamento por empresa e as políticas de upload dentro de uma transação descartada, sem transferir arquivos reais.

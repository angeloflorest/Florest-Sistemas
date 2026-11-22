# Pedidos e cardápio digital do Bar

## Apresentação do cardápio — 22/11/2026

O cardápio público tem cabeçalho com a identidade da loja, busca fixa e cartões adaptados a celular e computador. As cores principal e de fundo continuam vindas da configuração de cada empresa. Fotos usam enquadramento integral (`contain`) em lista, grade e detalhe do produto, preservando garrafas, latas e pratos sem cortes. A escolha do produto abre a foto ampliada. Carrinho, preços, publicação, entrega/retirada, envio e isolamento por token mantêm o contrato existente.

O cabeçalho utiliza as iniciais do nome enquanto não houver logo; ele aceita a imagem de identidade quando fornecida pelo catálogo. Nenhuma logo foi criada ou atribuída ao Nova Ponte nesta atualização: o arquivo original ainda precisa ser enviado pelo proprietário. Nenhuma foto de produto foi substituída. O mesmo link da loja continua válido, inclusive ao navegar pelo atalho de acessibilidade.

Validação visual: onze fotos reais do catálogo Nova Ponte carregadas em 390 e 1440 px, sem cortes ou rolagem horizontal. Teste isolado adicional em 320, 390 e 1440 px: fotos verticais/horizontais, detalhe, logo opcional e preservação do token da loja.

Bar → Pedidos recebe exclusivamente pedidos do cardápio digital do Bar, para entrega ou retirada. Os cartões seguem a grade da Rotisseria (145 px mínimos; 120 px no celular) e mostram número, cliente, modalidade, itens, total e andamento. Abrir mostra telefone, endereço, escolhas e observações. A lista atualiza a cada 15 segundos enquanto estiver visível, com botão de atualização manual e paginação. Finalizados e recusados têm consulta separada.

Bar → Configurações → Cardápio digital configura somente a empresa ativa: nome de apresentação, texto, cores, lista ou grade, produtos publicados, descrição, categoria e foto. Cada empresa recebe um token, link, QR Code e numeração de pedidos próprios. O carrinho do cliente também é separado pelo token. Novas configurações começam pausadas e nenhum produto é publicado automaticamente. Gastronomia, Rotisseria e a prévia estática `cardapio/bar-teste/` permanecem independentes.

O cliente escolhe produtos e acompanhamentos, informa nome, telefone, entrega/retirada e endereço completo em ambas as modalidades, conforme solicitado. Não existe pagamento on-line. O preço e as escolhas são conferidos no servidor. Reenvios com mesma chave e conteúdo recuperam o mesmo pedido; respostas incertas mantêm o envio salvo para recuperação. O acompanhamento individual exige o segredo retornado ao comprador.

Aceitar registra o consumo pelas funções atuais do Bar, inclusive componentes, escolhas, destinos e estoque. Os dados do pedido são incluídos nas observações enviadas às impressoras existentes. O pedido não ocupa mesa. O operador acompanha preparo, pronto e saída para entrega. Pedidos ainda não aceitos podem ser recusados. O recebimento integral exige caixa BAR aberto e a permissão de caixa; usa as mesmas formas e preparação de taxas atuais. Uma repetição da finalização devolve a venda anterior. Após confirmar o pagamento, o componente existente pergunta sobre o cupom fiscal: emitir usa o emissor e a impressão atuais; ESC ou Não fecha a pergunta sem emissão automática.

## Escopo técnico

Quatro tabelas privadas com RLS e sem acesso direto de anon/authenticated guardam configuração, publicação, pedidos e contadores de acesso. A empresa das ações administrativas vem da sessão validada, com módulo e permissão conferidos no servidor. A Edge Function `bar-cardapio` autentica o link por token e expõe somente catálogo/envio/acompanhamento; a ponte SQL pública exige service_role. Não envia chaves de servidor ao navegador.

`bar_comandas.mesa_id` e `bar_pedidos.mesa_id` passam a aceitar NULL para os novos pedidos digitais. As FKs de empresa permanecem. Nenhuma função existente de mesa, venda, pagamento ou fiscal é substituída. Um adaptador privado é derivado da definição atual do recebimento do Bar, removendo somente a dependência da mesa física e fechando a comanda digital. Uma guarda por hash recusa instalação se o recebimento original mudar; ao atualizar esse recebimento no futuro, revisar também o adaptador digital. A numeração, os pagamentos, o estoque e a conferência fiscal continuam usando o núcleo do Bar.

## Validação

- `node --test florest-erp/sistema/tests/bar-cardapio.browser.cjs`: entrega, retirada, endereço, escolhas, armazenamento por empresa, recuperação de resposta perdida, cartões, aceite, finalização, ESC e configuração com QR exclusivo. Definir `BAR_MENU_BROWSER` para o pacote Playwright quando necessário.
- `BAR_REFRESH_BROWSER=/caminho/playwright node --test florest-erp/sistema/tests/bar-atualizacao.test.cjs`: regressão das mesas.
- `node --test florest-erp/sistema/tests/cupom-pos-venda.browser.cjs`: componente fiscal existente.
- `tests/bar-cardapio.sql`: executar somente dentro de BEGIN/ROLLBACK; fixtures fictícias, isolamento, preços, endereço, segredo, reenvios, caixa fechado, venda única, contexto fiscal sem emitir documento, composto com escolha e regressão de mesa presencial. Nenhum teste transmite documento à SEFAZ ou confirma impressão física.

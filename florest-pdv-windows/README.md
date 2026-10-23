# Florest PDV Windows

Aplicativo de teste Windows do PDV principal do Florest ERP. O layout é derivado da tela do navegador. O controle opcional de taxas usa a mesma configuração por empresa do ERP e do Módulo Bar.

## Instalação e conferência

1. Execute `Florest-PDV-Setup-0.2.2.exe` no Windows 10/11 de 64 bits.
2. Com internet, entre com e-mail da empresa, usuário e senha do Florest ERP. Os produtos, clientes e atalhos são recebidos automaticamente.
3. Abra o Caixa PDV. A abertura e o fechamento precisam de conexão.
4. Faça uma venda. O aplicativo salva primeiro no SQLite local e oferece **Imprimir comprovante não fiscal** ou **Cancelar impressão**.
5. Desconecte a internet e faça outra venda. Feche e abra o aplicativo para conferir a persistência. Reconecte e use **Enviar atualizações**, ou aguarde a rodada automática (a cada minuto).
6. Confira a venda no ERP e o histórico local. Antes de fechar o caixa, envie todas as pendências.

O primeiro acesso exige internet. A sessão é protegida pelo Windows; o próximo início pode continuar sem conexão. Revogação de acesso e mudanças de permissão são verificadas quando o servidor volta a responder. A versão não emite documentos fiscais.

## Busca e atalhos de teclado (0.2.2)

Digite parte do nome (ex.: BR); a busca aparece enquanto você digita e reconhece prefixos de palavras, como BRAHMA em CERVEJA BRAHMA. Use as setas para escolher, Enter para abrir a quantidade, digite 2 e Enter para adicionar. O foco passa ao valor do pagamento. O leitor de código de barras mantém a entrada direta dos produtos comuns.

| Tecla | Ação |
| --- | --- |
| F1 | Manual de atalhos |
| F2 | Cliente |
| F3 | Finalizar a venda |
| F4 | Dinheiro |
| F5 | Desconto |
| F6 | Pix |
| F7 | Cartão de débito |
| F8 | Cartão de crédito |
| F9 | Buscar produto |

A opção Outros foi removida das vendas e comandas desta versão. F10 fica livre. Os pagamentos não finalizam a venda automaticamente. O manual usa a mesma lista de atalhos do aplicativo e é gerado por `npm run build:manual`, em `dist/Manual-Florest-PDV.html`.

## Funcionalidades

- Leitura de código de barras e pesquisa de produtos; quantidades fracionadas/granel.
- Clientes, CPF opcional, desconto, pagamentos mistos, troco em dinheiro e Nota a Prazo.
- Catálogo por empresa, estoque local descontando pendências e cupom em andamento recuperável.
- UUID por venda e proteção contra clique repetido; envio idempotente preservando as validações do ERP.
- Sincronização automática, botões manuais e histórico com erros e reimpressão.
- Abertura/fechamento de caixa, comandas compartilhadas e configuração dos atalhos **com internet**.
- Comprovante térmico não fiscal via diálogo de impressão do Windows.

## Regras de operação desta versão de teste

- Abra o caixa com internet antes de operar offline. Não feche esse mesmo caixa em outro computador enquanto este terminal tiver pendências. Se o caixa remoto for trocado, o aplicativo preserva a venda e exibe o erro para conferência; não transfere o valor para outro caixa automaticamente.
- O estoque offline é o último saldo recebido, menos vendas locais. Vendas simultâneas de outros computadores podem provocar recusa no envio; a pendência fica salva e visível.
- Produtos e clientes são cadastrados no ERP e recebidos pelo aplicativo.
- A impressão física e o comportamento no Windows do cliente precisam ser conferidos no equipamento. O instalador de teste ainda não possui assinatura digital de certificado comercial.
- Não há atualização automática do programa; uma atualização posterior pode ser instalada mantendo os dados locais.

## Desenvolvimento

Node.js 22: `npm ci`, `npm run check`, `npm test`. Depois `npm start` (o SQLite nativo precisa corresponder ao ABI do Electron; `npx electron-rebuild -f -w better-sqlite3` prepara a execução desktop). `npm run build:win` gera o instalador no Windows. O workflow da branch `florest-pdv-windows` executa testes e build no Windows e publica um pré-lançamento de teste.

`src/renderer/pdv.css` e a estrutura principal da tela foram extraídas de `florest-erp/sistema/index.html`. A ponte Electron tem operações permitidas explicitamente; o renderer não recebe tokens de acesso nem credenciais. A sessão usa `safeStorage`, e o banco SQLite usa WAL e transações.

## Servidor

A migration `supabase/migrations/20261023120715_pdv_desktop_offline.sql` adiciona somente as APIs deste aplicativo e uma tabela privada de recebimentos. As funções verificam usuário ativo, empresa aprovada/desbloqueada e permissão `pdv`. O UUID é serializado por trava transacional e o registro de recebimento é atômico com a venda original. Não altera as funções existentes de venda e caixa.

Verificação do servidor executada em subtransação revertida: contexto por usuário, catálogo sem custo de produto, envio repetido sem duplicidade, baixa única de estoque, rejeição de chave conflitante, rejeição de caixa incorreto e bloqueio de acesso anônimo. Os dados de teste foram revertidos.

## Taxas de pagamento (0.2.2)

No ERP: **Financeiro → Formas de pagamento**. O controle inicia desativado por empresa. Cadastre Pix e as bandeiras Visa, Mastercard, Elo, American Express, Hipercard e Diners no débito e crédito à vista. Campo em branco não configura a bandeira; 0% configura. No executável atualizado, use **Receber atualizações**. A seleção aparece somente para formas com bandeiras configuradas e controle ativo. O pagamento mantém a versão da configuração na fila local, inclusive offline; o servidor calcula a taxa daquela versão e consolida a **Despesa administrativa de cartões**, preservando o bruto do caixa. Cancelamento e estorno revertem a contribuição. Não há parcelas nesta configuração.

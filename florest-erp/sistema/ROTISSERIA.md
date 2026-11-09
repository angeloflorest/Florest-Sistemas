# Módulo Rotisseria

Operação integrada ao ERP, liberada por empresa em `empresa_modulos.rotisseria` pelo portal admin. Reutiliza login, produtos, preços, clientes, estoque, vendas, pagamentos, taxas, impressoras/Print Agent e emissão fiscal existentes. Não usa o caixa do PDV principal, Bar ou Gastronomia.

## Uso

1. Admin: editar a empresa e ativar **ROTISSERIA**.
2. Proprietário: configurar quantidade de comandas (1–200), produtos principais (até 20), fotos e impressora. O cadastro de produtos define unidade e preço; produtos em KG recebem peso manual em quilos, por exemplo `1,132`.
3. No navegador do computador do caixa, acessar **Caixa → Definir este dispositivo como caixa**, e abrir o caixa da Rotisseria.
4. No tablet, entrar com o login existente e abrir **Comandas**. Tocar na comanda abre diretamente a seleção. A pesquisa encontra produtos ativos além dos destaques.
5. Confirmar o lançamento envia o item para a comanda compartilhada. O dispositivo de atendimento não recebe pagamentos. Definir outro dispositivo como caixa transfere essa autorização; apenas abrir outro navegador não transfere.
6. No caixa, conferir a comanda e receber. A finalização baixa estoque e cria uma venda `tipo='rotisseria'`, com caixa `ROTISSERIA`, itens e pagamento no núcleo. Produtos continuam usando o estoque comum da empresa.
7. Emitir NFC-e opcionalmente, respeitando as configurações fiscais atuais, ou continuar sem emitir naquele momento. Impressão do DANFE usa o componente fiscal do ERP. O comprovante não fiscal usa a impressora selecionada na Rotisseria.

Abas: **Comandas**, **Caixa**, **Histórico de vendas** e **Configurações**. Permissões: `rotisseria_visualizar`, `rotisseria_lancar`, `rotisseria_caixa`, `rotisseria_configurar`. Operadores que emitem documento fiscal precisam também da permissão Fiscal existente. Proprietários seguem as permissões usuais do ERP.

## Consistência e isolamento

- Abertura serializada e índice único impedem duas sessões abertas para o mesmo número/empresa.
- Cada lançamento tem UUID de idempotência. Repetir a mesma requisição não duplica o produto.
- Alterações e recebimento bloqueiam a sessão no banco. Receber exige a versão conferida pelo operador; se entrar um item antes do pagamento, a cobrança é recusada para nova conferência.
- Repetir pagamento concluído retorna a mesma venda e o mesmo troco, sem nova baixa.
- O estoque é bloqueado por produto em ordem fixa e validado com a configuração existente de venda sem estoque. Falhas revertem toda a transação.
- Sinal Realtime contém somente empresa/revisão. Atualizações são agrupadas e há recarga de segurança a cada 60 s, somente com a tela visível. Busca tem debounce de 300 ms. Uma leitura traz a grade inteira, sem consulta de saldo por comanda.
- Fotos são reduzidas no navegador e só retornam nos contextos em que a configuração mudou. Dados de custo não são enviados ao atendimento.
- As tabelas operacionais ficam no schema privado, sem acesso direto de `anon`/`authenticated`; a RPC exige empresa ativa, módulo e permissões. O token do dispositivo de caixa é exclusivo do navegador e do usuário, e é conferido no servidor.
- A migração acrescenta somente integrações de tipo de caixa, permissões, admin e roteamento de impressão necessárias à Rotisseria. Guardas verificam as definições anteriores das funções compartilhadas antes de aplicar.

## Verificação

`node --test florest-erp/sistema/tests/rotisseria.test.cjs`. Definir `ROTISSERIA_BROWSER` com o caminho do Playwright executa também o teste em dois contextos Chromium independentes.

`tests/rotisseria-transacao.sql` deve ser executado **somente em transação terminada em ROLLBACK**, após a migração. Usa a conta de testes autorizada. Verifica peso, reenvio, dispositivo, versão, estoque, isolamento, venda, financeiro, caixa, impressão e preparação de NFC-e. Não transmite documento à SEFAZ nem confirma impressão física.

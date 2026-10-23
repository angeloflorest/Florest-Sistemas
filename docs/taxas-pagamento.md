# Controle de taxas de pagamento

Em Financeiro → Formas de pagamento, cada empresa pode ativar o controle e informar percentuais de Pix e cartões de débito/crédito à vista. O padrão é desativado; não há parcelamento nesta configuração.

As bandeiras disponíveis são Visa, Mastercard, Elo, American Express, Hipercard e Diners. Apenas as bandeiras com percentual preenchido são solicitadas no pagamento; 0% é uma regra preenchida. Campo vazio não configura aquela bandeira. Pix não solicita bandeira.

O PDV principal, as comandas e o módulo Bar usam a configuração da empresa autenticada. A versão 0.2.2 do PDV Windows recebe a configuração por sincronização e usa a última versão recebida sem conexão. A fila local preserva a versão e a bandeira; o servidor usa a versão imutável para calcular o percentual e os centavos. O pagamento mantém bruto, percentual e taxa no registro privado de auditoria. Uma alteração futura na configuração não recalcula o histórico.

O bruto integral permanece no caixa e na venda. As taxas geram uma despesa paga diária por empresa com descrição e categoria **Despesa administrativa de cartões**; o resumo e o relatório de despesas consolidam os dias do período em uma linha. Pix usa a mesma categoria. Não há retirada artificial de dinheiro físico. Cancelamento e estorno atualizam a contribuição; reenvio da mesma venda não duplica taxa nem despesa. Despesas automáticas não permitem edição ou remoção manual.

## Implantação e verificação

Migration: `supabase/migrations/20261023142143_taxas_pagamento.sql`. Registro remoto: versão 20261023142143, taxas_pagamento.

Ensaios transacionais: cálculo, consolidação, preservação de versões, isolamento entre empresas, rejeição de bandeira inválida, bloqueio de alteração manual, cancelamento, estorno, venda direta, comanda PDV, sincronização desktop repetida e as duas rotinas de pagamentos do Bar. Todos os dados de ensaio foram revertidos.

O workflow Windows [execução 5](https://github.com/angeloflorest/Florest-Sistemas/actions/runs/39968554523) validou sintaxe, testes unitários, interfaces web e desktop, criação do instalador e abertura do aplicativo empacotado. O manual inclui o controle de taxas e os atalhos existentes.

As três tabelas privadas usam RLS sem políticas e sem privilégios para anon/authenticated: acesso somente pelos RPCs que verificam empresa ativa e permissão. Os avisos do advisor sobre essas tabelas fechadas e os dois RPCs SECURITY DEFINER autenticados são esperados; não há acesso anônimo aos novos endpoints.

Instalar `Florest-PDV-Setup-0.2.2.exe` sobre a versão anterior e usar **Receber atualizações**. As alterações seguintes de configuração dispensam nova instalação. Instalação e impressão física no computador do cliente precisam ser conferidas no próprio equipamento.

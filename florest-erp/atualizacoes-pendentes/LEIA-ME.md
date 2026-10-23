# Atualizações aprovadas em 23/10/2026

Base: main 2982e31148810be309cb353f0141a38c05fa469b. A publicação deste pacote foi autorizada no chat após a escolha dos itens.

## Frontend

Filtro Ativos/Inativos/Todos (padrão Ativos) e recuperação completa da aba XMLs para Contadores: cadastro, conferência, download, envio com confirmação e histórico. Mantido o campo atual de usuário/e-mail na autorização. Nenhuma correção do cadastro com maria_acessar foi aplicada: o item 3 ficou sem resposta.

O envio real e o agendamento de XMLs dependem do backend e do serviço de e-mail existentes. Não foram enviados e-mails durante a validação.

## Cancelamentos: arquivo pendente de aplicação

bar_cancelar_itens_antes_da_mesa.sql contém a correção para impedir cancelamento de mesa/comanda com itens válidos. Cancela-se primeiro os itens; depois a mesa/comanda. Preserva cancelamento individual sem limite artificial, proteção de pagamentos/fiscal, token e auditoria.

**Não aplicado no Supabase.** O arquivo está fora de supabase/migrations para não ser aplicado automaticamente. A autorização desta etapa é publicar no Git. Antes da aplicação, revisar o pacote com Angelo. A verificação MD5 bloqueia aplicação sobre uma função diferente da consultada. A versão anterior está em ../backend-referencia/2026-10-23/florest_bar_cancelar.antes.sql; não reverter cegamente se houver alterações posteriores.

## Fontes atuais

../backend-referencia/2026-10-23 contém 148 funções relacionadas e dependências, com assinaturas, proprietário, ACL e definições, além de colunas, constraints, índices, triggers e políticas. São referências do estado instalado, não migrações e não backup de dados. Cinco fontes de Edge Functions foram recuperados exatamente como implantados. Versionar esses fontes não faz deploy das Edges.

## Print Agent

Fontes completos em /florest-print-agent, incluindo Montserrat e licença OFL. Instalador de validação preparado localmente, sem substituir o download de produção nem instalar serviço no computador. Precisa de validação em impressoras reais.

## Verificação

- ERP: 44 testes aprovados, zero falhas, dois opcionais ignorados.
- Interface da aba e padrão Ativos: conferidos em Edge headless; alternância das abas preservada.
- JavaScript do módulo principal: verificação de sintaxe.
- Cancelamento: compilação e sete cenários no PostgreSQL 17 local, com dependências simuladas: bloqueio de mesa/comanda com itens, preservação dos itens ao bloquear, cancelamento individual, liberação após itens cancelados, bloqueio por pagamento/fiscal e preservação do cancelamento de pedido.
- Print Agent: 543 testes aprovados, zero falhas, zero ignorados; avisos preexistentes de compilação.
- Sem vendas, pagamentos, senhas ou documentos fiscais alterados em produção.

Documentação consultada: https://supabase.com/docs/guides/database/functions .

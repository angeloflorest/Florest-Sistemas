# Matriz das 47 ferramentas da MARIA

31 leituras e 16 ações da versão publicada v14 preservadas. Todo acesso passa primeiro por maria_autorizar. As regras abaixo são cumulativas e não substituem validações internas da função. Modo SQL e filtro de empresa originais foram preservados. Nenhuma função de pedidos/PDV/fiscal foi alterada.

| Ferramenta | Tipo | Grupo | RPC / ação | Regra preparada |
| --- | --- | --- | --- | --- |
| resumo_vendas_hoje | leitura | vendas | maria_resumo_vendas_hoje | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| resumo_vendas_ontem | leitura | vendas | maria_resumo_vendas_ontem | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| resumo_vendas_mes | leitura | vendas | maria_resumo_vendas_mes | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| formas_pagamento_mes | leitura | vendas | maria_formas_pagamento_mes | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| produtos_mais_vendidos_mes | leitura | vendas | maria_produtos_mais_vendidos_mes | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| ultimas_vendas | leitura | vendas | maria_ultimas_vendas | maria + gates originais da RPC; consultar migration |
| ranking_produtos | leitura | vendas | maria_ranking_produtos | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| comparar_produtos | leitura | vendas | maria_comparar_produtos | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| produto_por_dia_semana | leitura | vendas | maria_produto_por_dia_semana | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| pagamento_por_semana | leitura | vendas | maria_pagamento_por_semana | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| buscar_produto | leitura | estoque | maria_buscar_produto | maria + gates originais da RPC; consultar migration |
| estoque_baixo | leitura | estoque | maria_estoque_baixo | maria + gates originais da RPC; consultar migration |
| estoque_zerado | leitura | estoque | maria_estoque_zerado | maria + gates originais da RPC; consultar migration |
| estoque_analise | leitura | estoque | maria_estoque_analise | maria + domínio de estoque/produtos/notas/fiscal/relatorios; além de abaixo_minimo exige relatorios; gates originais cumulativos |
| produto_detalhe | leitura | estoque | maria_produto_detalhe | maria + produtos ou relatorios + gates originais; histórico agregado só com relatorios |
| financeiro_resumo | leitura | financeiro | maria_financeiro_resumo | maria + financeiro ou relatorios; validações originais, RLS e tenant |
| despesas_listar | leitura | financeiro | maria_despesas_listar | maria + financeiro ou relatorios; validações originais, RLS e tenant |
| despesas_agrupadas | leitura | financeiro | maria_despesas_agrupadas | maria + financeiro ou relatorios; validações originais, RLS e tenant |
| contas_a_pagar | leitura | financeiro | maria_contas_pagar | maria + financeiro ou relatorios; validações originais, RLS e tenant |
| comparar_periodos | leitura | financeiro | maria_comparar_periodos | maria + financeiro ou relatorios; validações originais, RLS e tenant |
| clientes_buscar | leitura | clientes | maria_clientes_buscar | maria + gates de cliente; histórico de compras só com relatorios e gates originais |
| cliente_detalhe | leitura | clientes | maria_cliente_detalhe | maria + gates de cliente; histórico de compras só com relatorios e gates originais |
| clientes_ranking | leitura | clientes | maria_clientes_ranking | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| clientes_situacao | leitura | clientes | maria_clientes_situacao | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| comparar_clientes | leitura | clientes | maria_comparar_clientes | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| panorama_negocio | leitura | panorama | maria_panorama | maria + relatorios + gates originais (pdv nas funções legadas); não substitui RLS |
| pet_agenda | leitura | pet | maria_pet_agenda | maria + gates originais da RPC; consultar migration |
| pet_pacotes | leitura | pet | maria_pet_pacotes | maria + gates originais da RPC; consultar migration |
| pet_historico | leitura | pet | maria_pet_historico | maria + gates originais da RPC; consultar migration |
| pet_retorno | leitura | pet | maria_pet_retorno | maria + gates originais da RPC; consultar migration |
| bar_analise | leitura | bar | maria_bar_analise | maria + Bar comercial + gates por foco; além de agora exige relatorios ou financeiro |
| cadastrar_cliente | acao | acoes | maria_acao_preparar → cliente_criar | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| atualizar_cliente | acao | acoes | maria_acao_preparar → cliente_atualizar | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| cadastrar_produto | acao | acoes | maria_acao_preparar → produto_criar | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| atualizar_produto | acao | acoes | maria_acao_preparar → produto_atualizar | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| atualizar_preco_produto | acao | acoes | maria_acao_preparar → produto_atualizar_preco | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| lancar_despesa | acao | acoes | maria_acao_preparar → despesa_criar | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| atualizar_despesa | acao | acoes | maria_acao_preparar → despesa_atualizar | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| marcar_despesa_paga | acao | acoes | maria_acao_preparar → despesa_marcar_paga | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| cadastrar_pet | acao | acoes | maria_acao_preparar → pet_criar | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| agendar_servico_pet | acao | acoes | maria_acao_preparar → agendamento_criar | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| criar_pacote_pet | acao | acoes | maria_acao_preparar → pacote_criar | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| registrar_sessao_pacote | acao | acoes | maria_acao_preparar → pacote_registrar_uso | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| estornar_sessao_pacote | acao | acoes | maria_acao_preparar → pacote_estornar_uso | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| bar_abrir_mesa | acao | acoes | maria_acao_preparar → bar_abrir_mesa | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| bar_adicionar_pessoas | acao | acoes | maria_acao_preparar → bar_adicionar_pessoas | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |
| bar_lancar_pedido | acao | acoes | maria_acao_preparar → bar_lancar_pedido | maria + requisitos originais por ação, módulo/plano e confirmação; execução revalida |

`maria_uso_finalizar` não é ferramenta e mantém o contrato de finalização de reserva com segredo e identidade. Para definições exatas, consultar a migration e a baseline SQL dos testes.

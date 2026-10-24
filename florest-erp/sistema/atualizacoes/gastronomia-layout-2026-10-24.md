# Gastronomia — reorganização visual de 24/10/2026

Base oficial: `eb73e2f09a7c00ce95a943b384fdbff2ec9035ee`.

Publicação limitada ao layout, conforme orientação posterior do usuário: mostrar a proposta SQL antes de aplicar e preservar as regras instaladas de estoque, pagamentos e fiscal. **Nenhuma migration foi aplicada nesta atualização.**

## Incluído

- Quatro abas: Mesas, Pedidos, Caixa e Configuração.
- Mesas compactas e clicáveis, com cliente quando disponível, abertura/tempo, consumido e saldo.
- Pedidos somente de entrega/retirada, com filtros por origem/modalidade e rótulos separados para pagamento e andamento. O rótulo de impressão direciona a consulta ao Print Agent: não inventa estado da fila.
- Preparo e expedição permanecem nos detalhes/cartões, chamando as ações existentes. Marcar pronto continua por item/setor, sem nova regra de estoque.
- Configuração em blocos, sem campos de saldo, ajuste ou baixa de estoque. Taxa de entrega padrão e impressão usam a configuração já instalada; taxa de serviço permanece no ajuste do atendimento. Produtos/preços seguem o cadastro central e suas permissões. Publicação/destino preservam os componentes e grupos atuais.
- Histórico de caixa pode abrir os atendimentos carregados e seus movimentos, indicando a janela de até 500. A interface não chama a função de detalhe que requer correção no backend.

## Proposta SQL separada, não aplicada

A proposta local contém reimpressão efetiva, leitura de estado da fila, campos adicionais de configuração, correções de cadastro/quantidade e consulta ampliada de histórico/número de venda. Esses controles excedem a reorganização visual e precisam de conferência separada antes de qualquer aplicação. Nenhuma dessas ações novas foi ligada no HTML publicado.

Cardápio por QR, envio online e acompanhamento continuam sem conexão real; iFood é futuro e WhatsApp significa lançamento manual. Não houve substituição da prévia existente nem ativação de empresas.

## Validação e reversão

Sintaxe do HTML completo conferida. Funções novas de mutação e consulta da proposta SQL ausentes do layout. Alterações restritas ao bloco de interface do Gastronomia e seu CSS; demais trechos preservados. Os 14 testes de referência e 10 de concorrência foram executados localmente; testes da proposta SQL não significam publicação dela. Sem testes de impressão física ou SEFAZ.

Backup anterior: branch `codex/backup-gastronomia-antes-quatro-abas-2026-10-24`. Para reverter apenas o layout, reaplicar o bloco Gastronomia anterior sobre o Git mais recente, preservando mudanças posteriores. Não é necessário reverter o banco.

# Integração PDV Móvel — estado após aplicação

A autorização posterior permitiu implementar o backend real. A migração preparada foi
aplicada ao projeto etulhyboogqhyyevpnlo em 05/11/2026 com o novo token de escrita.
O bloqueio antigo de acesso somente leitura foi resolvido.

Implementados: sessões de caixa por empresa/dispositivo, recibos transacionais idempotentes,
reuso de registrar_venda para estoque/itens/numeração, tabelas canônicas de pagamentos,
taxas e contas a receber, fechamento e resumo, histórico filtrado no servidor e metadados
para o ERP. As funções dos demais caixas/módulos não foram alteradas.

Restam validações/limites concretos:

1. Teste MANUAL do APK pelo proprietário com usuário/empresa de teste: login, teclado,
   câmera, abertura, CERVEJA BRAHMA 600ML se cadastrada, venda confirmada, estoque,
   pagamentos, histórico e fechamento. Nenhuma venda real foi executada automaticamente.
2. Empresas com emissão fiscal ativa/não confirmada continuam impedidas de vender no
   móvel. A configuração e a emissão existentes não foram alteradas. Não desabilitar
   essa configuração para contornar o bloqueio; o fluxo fiscal requer integração própria.
3. Os ajustes visuais de relatório/histórico do HTML do ERP ainda estão locais. O site
   servido só exibirá os novos rótulos depois de publicação autorizada.
4. Os arquivos atuais ainda não foram enviados ao GitHub; commit/push/deploy dependem
   da autorização posterior exigida pelo proprietário. APK assinado será gerado no Windows.

Ver VALIDACAO.md, backend/LEIA-ME.md e COMO_INSTALAR_FLOREST_PDV_MOVEL.txt.

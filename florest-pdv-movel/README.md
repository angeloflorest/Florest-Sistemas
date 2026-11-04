# Florest PDV Móvel — Android

Projeto isolado do ERP existente. Nenhum arquivo do ERP, função SQL ou tabela foi alterado.

## Estado atual

Base inicial de aplicativo: autenticação Supabase, consulta de produtos, carrinho, leitura por câmera, entrada por leitor Bluetooth em modo teclado e consulta de manifesto remoto de atualizações. **Não está pronto para realizar vendas reais, abrir/fechar caixa ou gerar APK de produção.** Essas ações exigem operações de backend específicas e seguras para um único caixa móvel por empresa, ainda não implementadas. O botão de finalização permanece desabilitado para não criar vendas inconsistentes.

## Regras obrigatórias para a próxima etapa

- Um caixa móvel por empresa, separado do caixa do computador; fechamento individual e consolidação no ERP.
- Mesmo login e permissões do ERP; empresa_id validado no servidor.
- Vendas, descontos, cancelamentos, venda a prazo, pagamentos divididos e estoque devem reutilizar regras seguras do PDV principal.
- Nenhuma emissão fiscal no aplicativo. A obrigação fiscal deve continuar tratada pelo ERP, sem suprimir exigências legais.
- PDF não fiscal para WhatsApp após venda confirmada.
- Atualizações: consultar manifesto de versão publicado; exibir aviso e link para APK oficial. Atualização binária requer instalação pelo Android; atualizações OTA exigem serviço e configuração EAS Update, ainda não configurados.

## Preparar

1. `npm install` para gerar `package-lock.json` e validar versões do Expo.
2. Copiar `.env.example` para `.env` e inserir apenas URL e chave **pública** do Supabase. Nunca incluir `service_role`.
3. `npm start` para testar em Android; compilar APK após integrar backend.
4. Publicar manifesto de versão HTTPS controlado pela Florest Sistemas e informar `EXPO_PUBLIC_UPDATE_MANIFEST_URL`.

## Escopo preservado

Não modificar `florest-erp/`, `admin/`, `supabase/` ou o portal existente sem autorização específica. Para versões futuras, pesquisar primeiro `florest-pdv-movel/` no Git e consultar as tabelas/funções no Supabase antes de implementar mudanças.

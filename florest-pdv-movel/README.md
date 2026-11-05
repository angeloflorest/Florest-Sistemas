# Florest PDV Móvel 0.3.0 — migração aplicada; teste manual no aparelho pendente

Pacote preservado: `br.com.florestsistemas.pdvmovel`; Android versionCode 3.
Expo SDK 54 / React Native 0.81.5. Mesma marca, autenticação e geração Windows do 0.2.0.

## Estado confirmado desta entrega

Migração `20261105_pdv_movel.sql` APLICADA ao projeto `etulhyboogqhyyevpnlo` em 05/11/2026,
com o novo token de escrita. As guardas dos contratos passaram e os objetos foram
verificados. RLS ativa nas duas tabelas novas; seis RPCs móveis somente autenticadas.
Das 444 funções existentes, 442 permaneceram idênticas; somente os dois históricos
previstos receberam metadados. Índices/restrições dos caixas atuais foram preservados.
Nenhum caixa ou venda comercial foi criado automaticamente no projeto remoto.

TypeScript, 33 testes do app, 3 testes de relatórios e bateria SQL isolada passaram.
No remoto, o acesso sem sessão foi recusado em transação somente leitura. O ciclo real
no APK com o usuário da empresa de teste continua pendente, sem simular sua conclusão.
A emissão fiscal mantém a limitação descrita abaixo.

Não houve commit, push ou deploy. Os ajustes visuais do ERP estão locais e só aparecerão
no site servido após publicação autorizada. Os dados canônicos já são compatíveis com
as consultas gerais do ERP, mas não existe venda móvel de teste remota para demonstrá-los.

## Fluxo implementado e contrato instalado

- Login por Usuário + e-mail da empresa + senha via `florest-login`, ou e-mail pessoal
  com Usuário vazio via Supabase Auth. Empresa/operador vêm do perfil, nunca de ID digitado.
- Teclado Android com adjustResize, rolagem do campo focado e navegação entre campos.
- Cliente padrão nulo; pesquisa de clientes/produtos reais da empresa, câmera e GTIN.
- Quantidade, desconto e acréscimo por unidade em reais. Backend confere preço atual,
  ajustes, produtos ativos, estoque e cliente na mesma transação.
- Cada instalação tem UUID criptográfico protegido. Cada celular abre sua própria sessão
  de caixa; fechar não altera os caixas do computador, Bar ou Gastronomia.
- Abertura, venda e fechamento usam recibos idempotentes persistidos no servidor. O app
  preserva chave e pedido antes de enviar, consulta antes de repetir e exige reconhecer o
  resultado. Não há venda offline nem reenvio automático.
- Venda chama a função central EXISTENTE `registrar_venda` para estoque/itens/numeração.
  Usa as mesmas `vendas_pagamentos`, regras de taxas e `contas_receber` para nota a prazo.
  Pagamentos separados, limite dez; nota a prazo integral exige cliente e nenhum recebimento.
- Caixa mostra valores calculados dos registros canônicos, por forma, nota a prazo,
  troco/esperado, quantidade de vendas e horários/operador. Fechamento guarda o resumo.
- Histórico aplica período/número/caixa/cliente/operador no servidor. Sem Financeiro,
  operador vê suas próprias vendas móveis; perfil financeiro pode ver os dois PDVs.
- Ajustes pontuais no HTML do ERP identificam PDV Móvel em financeiro/histórico/relatórios
  e acrescentam produtos por caixa. Esses arquivos ainda NÃO foram publicados.

## Fiscal — limitação explícita, sem contornar configuração

A emissão fiscal não foi alterada ou reimplementada. O backend verifica a configuração
fiscal existente e **recusa vendas móveis quando emite_nota_fiscal=true ou não confirmada**,
pois o app ainda não implementa o fluxo de emissão existente do ERP. Não desative essa
configuração para contornar a restrição. Nesse caso, use o fluxo fiscal autorizado do ERP.
Empresas explicitamente configuradas sem emissão podem usar a operação móvel após migração
e validação manual. Não foi testada uma venda real na empresa do proprietário.

## Compilar e validar

```sh
npm ci --no-audit --no-fund
npm run check
npm test
npx expo install --check
npx expo export --platform android --output-dir dist --max-workers 2
```

`npm test` executa somente os testes do aplicativo. Integração de relatórios e SQL têm
comandos separados no backend; não exigem banco de produção para os ensaios técnicos.
Preserve `.env.local`, keystore e APK anteriores. Nunca inclua o token de gestão em
EXPO_PUBLIC, `.env` do app ou APK. SecureStore continua protegendo a sessão e tentativas.

No Windows, execute `GERAR_APK_FLOREST_PDV_MOVEL.bat` como antes. O gerador verifica JDK 17,
Node, SDK, tipos/testes, assinatura original, pacote, versão, câmera e JavaScript incorporado.
Saída: `APK-GERADO/Florest-PDV-Movel.apk`. Nenhuma ferramenta global precisa ser reinstalada
se a versão anterior já compila. Não foi gerado um APK assinado nesta instância Linux.
Veja `COMO_INSTALAR_FLOREST_PDV_MOVEL.txt` e `VALIDACAO.md`.

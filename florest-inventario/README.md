# Florest Inventário 1.0.0

Aplicativo Android independente, pacote `br.com.florestsistemas.inventario`, para contagem física com atualização imediata do saldo existente no ERP. Nenhuma migração, tabela, função, permissão, tela ou configuração do ERP é criada ou alterada por esta entrega. O app utiliza as mesmas APIs existentes de login, perfis e produtos.

## Operação

Entre com usuário/e-mail da empresa/senha do ERP, ou e-mail pessoal e senha com usuário vazio. Exige proprietário ou permissão Estoque, empresa aprovada e usuário ativo. Abra um inventário, pesquise por nome/código ou leia o código de barras com a câmera. Informe a quantidade física total (zero permitido, até quatro decimais). Confira e confirme. A quantidade substitui o saldo; não é uma entrada adicional. Serviços e produtos inativos não são contáveis.

Cada confirmação altera somente `produtos.quantidade_estoque`, com filtro por empresa, produto, saldo e versão `atualizado_em` consultados. O próprio trigger já existente do ERP atualiza a versão. Se uma venda ou edição mudar o registro antes da confirmação, o app recusa a gravação e pede conferência. O app não modifica esse trigger nem os fluxos de venda.

## Histórico local e arquivos

A abertura, operador, empresa, número sequencial local, fechamento e todas as tentativas são preservados em SQLite no aparelho. O diário é gravado antes de enviar ao ERP. Outro operador/empresa não vê esses relatórios na interface. O número do inventário é deste aparelho, não uma numeração global do ERP.

Finalizar apenas encerra o inventário. Não reaplica saldo. Inventários com tentativa pendente não podem ser encerrados. Relatórios CSV e JSON são salvos na pasta de documentos privados do app e podem ser compartilhados/salvos pelo Android. CSV identifica registros sem confirmação e protege campos textuais contra fórmulas de planilha.

A restrição de não alterar o ERP implica: não existe aba nova no ERP, sincronização de histórico entre celulares, restauração automática dos JSONs ou recibo de idempotência no servidor. Os saldos confirmados aparecem normalmente no estoque existente. Os relatórios ficam no aparelho e nos arquivos exportados. Desinstalar ou limpar os dados remove o histórico local; exporte os relatórios antes.

## Conexão interrompida

Não há envio automático offline. Se a resposta se perder, o registro fica para conferência, sem ser apresentado como confirmado. Consultar um saldo igual ao desejado não comprova autoria. Repetir usa sempre a versão original, impedindo sobrescrever vendas posteriores. O operador pode, após conferir no ERP, encerrar a tentativa SEM CONFIRMAÇÃO; isso fica no relatório e não altera estoque. Uma nova contagem exige consultar o produto novamente. Não há garantia de recibo remoto exatamente uma vez sem adicionar um contrato de servidor, o que está fora do escopo autorizado.

## Compilação

Node 22, JDK 17 e Android SDK compatível com Expo SDK 54 / React Native 0.81.5. Dependências e lock fixados. A configuração distribuída contém apenas URL e chave PUBLICÁVEL do mesmo ERP; sessões ficam em SecureStore. Nenhum token administrativo, senha ou chave privada faz parte do APK.

```
npm ci --no-audit --no-fund
npm run check
npm test
npx expo prebuild --platform android --no-install
node scripts/prepare-unsigned.cjs
cd android
./gradlew :app:assembleRelease --no-daemon --max-workers=2 -PreactNativeArchitectures=arm64-v8a,armeabi-v7a
```

O workflow específico compila somente esta aplicação em branch isolada. O APK unsigned deve receber uma chave exclusiva e preservada pelo proprietário. Não reutilize a chave de teste nem inclua keystores/senhas no Git ou em artefatos públicos. A chave privada e sua senha precisam ser guardadas para futuras atualizações.

## Validação

TypeScript e 11 testes passam, incluindo fluxo das telas com componentes nativos simulados, SQLite real, persistência, isolamento por usuário, permissão revogada, zero/decimais, saldo concorrente, resposta perdida e exportação. Esses testes não fazem alterações no ERP de produção. Login real do cliente, câmera física, teclado Android e estoque real precisam ser homologados pelo operador no aparelho. Não há teste comercial automático.

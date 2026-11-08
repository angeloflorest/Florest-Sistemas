# Retomar a compilação no Windows com pouca memória

O print de 08/11/2026 mostra avisos CMAKE_OBJECT_PATH_MAX e o erro Ninja `manifest 'build.ninja' still dirty after 100 tries`. Use uma pasta curta e gere os arquivos nativos novamente: caches antigos contêm caminhos absolutos.

Copie os fontes para uma pasta nova, como C:\pdv, sem node_modules, android e dist. Preserve a pasta original, .env.local, APK anterior e keystore original. Não use /MIR nem apague o projeto original. Mantenha o keystore fora de C:\pdv e confira que FLOREST_EXISTING_APK aponta para o APK anterior preservado. Variáveis definidas somente no CMD são mantidas apenas nessa sessão e nos seus processos filhos.

Execute GERAR_APK_FLOREST_PDV_MOVEL.bat na pasta curta. O gerador recria dependências e projeto Android. Em computadores com até 6 GB, limita o Gradle a um worker, desativa paralelismo Gradle, limita heap Java a 1536 MB e metaspace a 384 MB, executa Kotlin no processo de compilação e limita heap Node a 768 MB. Solicita paralelismo CMake de um processo; ferramentas nativas podem aplicar suas próprias opções.

Esses limites reduzem concorrência, mas não garantem que toda compilação React Native caiba em 4 GB. Feche Chrome, Android Studio e emuladores; mantenha o arquivo de paginação do Windows gerenciado pelo sistema e espaço livre no disco. Se houver falta de memória, use um computador com mais RAM, mantendo a mesma assinatura; não troque o keystore.

Exija BUILD SUCCESSFUL e a mensagem APK RELEASE verificado. O destino é APK-GERADO\Florest-PDV-Movel.apk. Instale por cima da versão anterior, sem desinstalar. Confira login, campos/teclado, cliente, produto/câmera, quantidade/ajustes, pagamentos, abertura/fechamento do caixa exclusivo e histórico/estoque no ERP. A limitação fiscal descrita no README permanece.

Validação desta correção: TypeScript e 35 testes automatizados passaram no Linux. Não foi executada compilação Windows, assinatura ou teste em aparelho nesta sessão.

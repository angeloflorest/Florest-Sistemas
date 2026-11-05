# Florest PDV Móvel — Android

Aplicativo Expo SDK 54 / React Native 0.81.5 / TypeScript, versão 0.2.0.
Pacote preservado: `br.com.florestsistemas.pdvmovel`.
Todas as alterações desta revisão ficam nesta pasta. Nenhum deploy ou SQL é necessário
para instalar as dependências ou gerar o aplicativo.

## Disponível nesta revisão

- Login por e-mail/senha no Supabase Auth do ERP; sessão em Expo SecureStore, em blocos
  com gravação atômica, renovação enquanto ativo e saída local explícita.
- Empresa obtida exclusivamente de `perfis.id = auth.user.id`, com checagem de ativo,
  papel/permissão PDV e empresa bloqueada/pendente. Não há empresa digitada ou fixa.
- Consulta pela RPC existente `pdv_produtos_consultar`, que aplica empresa e permissão
  no servidor. Sem fallback para leitura direta de `produtos` ou criação de cadastros.
- Busca dinâmica; código exato com prioridade de GTIN, variantes com zeros à esquerda,
  câmera e leitor Bluetooth em modo teclado (Enter solicita código exato).
- Lista temporária de itens, edição de quantidade/peso com até três casas decimais,
  remoção e total arredondado por item. Não é uma venda salva, nem fila offline.
- Logo e ícone originais copiados dos assets do ERP, sem modificar a origem. Splash,
  ícone adaptativo, cores azul-marinho/dourado e layout para toque.
- Manifesto opcional HTTPS, apenas atualização de versão maior; APK na mesma origem do
  manifesto. Nenhum domínio fictício nem OTA não configurado. O usuário instala o APK.

## Limite de integração: operação de caixa

**Não utilizar esta revisão para registrar vendas.** Abertura/fechamento, recebimentos,
confirmação e estoque estão bloqueados. O backend consultado usa `caixa_atual/abrir/fechar`
com `p_tipo: 'PDV'`, compartilhado com o computador. `registrar_venda_mista` no PDV
não recebe chave idempotente nem identifica uma sessão móvel independente. Reutilizar
essas chamadas sem um contrato específico poderia misturar caixas ou duplicar uma venda
após perda da resposta. Não foram criadas operações alternativas nem chamadas de escrita.

A pasta `docs/INTEGRACAO-PENDENTE.md` descreve o trabalho separado necessário. A existência
e as regras das funções foram conferidas no código/backup SQL do repositório, não por uma
sessão autenticada no banco atual. A consulta ao esquema remoto recebeu HTTP 401.
O aplicativo usa somente a chave pública configurada pelo proprietário durante o build.

## Desenvolvimento

```sh
npm ci --no-audit --no-fund
npm run check
npm test
npx expo install --check
npx expo start
```

Copie `.env.example` para `.env.local` e configure URL/chave **públicas** do ERP.
Não versionar `.env.local`, keystore, senhas ou APKs. Nunca usar `service_role`.
Não é preciso ID manual da empresa. Não há migração ou escrita de dados no startup.
As permissões do app não substituem as políticas RLS e a autorização das RPCs.

Para validar o empacotamento sem SDK: `npx expo export --platform android --output-dir dist --max-workers 2`.
`npx expo prebuild --platform android --no-install` gera `android/` local, ignorado pelo Git.
O plugin `plugins/with-release-signing.cjs` configura assinatura Release explícita, sem
fallback para o certificado genérico do Expo. Não usar o workflow Debug antigo como entrega.
O workflow fora desta pasta foi mantido intocado conforme o escopo autorizado.

## Gerar e instalar no Windows

Leia `COMO_INSTALAR_FLOREST_PDV_MOVEL.txt` e execute `GERAR_APK_FLOREST_PDV_MOVEL.bat`.
Requer JDK 17, Node >=20.19, Android SDK, keystore original e APK anteriormente instalado.
O gerador usa `npm ci`, testes, prebuild e `assembleRelease`, verifica o certificado contra
o APK anterior, pacote, versão, permissão e bundle, e entrega `APK-GERADO/Florest-PDV-Movel.apk`.
Não publica nem altera ERP/Supabase/GitHub/portal. APK anterior é preservado em falhas.
O script Windows ainda precisa ser executado no computador do proprietário.

Veja `VALIDACAO.md` para os testes executados e os que dependem do dispositivo/backend.

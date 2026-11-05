# Entrega e validação — 04/11/2026

## Resultado

Preparada revisão 0.2.0 do app, sem publicação. Login/empresa, pesquisa por RPC,
lista de itens, identidade visual e gerador Windows foram implementados.
**Operação comercial de caixa não está liberada.** A integração segura exige backend
separado descrito em `docs/INTEGRACAO-PENDENTE.md`. Não foi gerado APK Release assinado.

## Verificações executadas

- `npm run check`: passou, TypeScript estrito.
- `npm test`: 11 testes executados, 11 passaram, nenhum ignorado. Cobrem validação de
  perfil/permissões, ausência de empresa manual nos argumentos da RPC, consulta sem
  fallback de tabela, código exato/GTIN, quantidade/total, atualização HTTPS, chave
  pública, persistência segura de sessão (incluindo falha de gravação e Unicode) e plugin
  de assinatura. Dependências externas nesses testes são simuladas; não provam RLS real.
- `EXPO_OFFLINE=1 npx expo install --check`: versões compatíveis com o catálogo local
  do Expo instalado. Consulta online do catálogo falhou por erro de rede; a própria
  ferramenta alerta que a validação offline é menos confiável.
- `CI=1 EXPO_OFFLINE=1 npx expo export --platform android --output-dir dist --max-workers 2`:
  bundle Android Hermes e logo exportados. É empacotamento, não um APK instalável.
- `CI=1 EXPO_OFFLINE=1 npx expo prebuild --platform android --no-install`: passou,
  inclusive repetição sobre `android/` existente. Um primeiro erro no plugin de assinatura
  causado por comentários no template Expo foi corrigido antes da validação final.
- Inspeção do nativo gerado: nome `Florest PDV Móvel`, versão 0.2.0/versionCode 2,
  pacote `br.com.florestsistemas.pdvmovel`, ícones adaptativos com margem nativa para preservar a águia e splash gerados,
  câmera/internet declaradas, microfone/armazenamento externo removidos, backup desativado,
  Release usa `signingConfigs.florestRelease` e lê credenciais do ambiente.
- `node --check` nos scripts CJS e `git diff --check`: passaram.
- Gerador chamado em Linux: recusou o sistema conforme esperado. Isso não valida o .bat
  nem a execução de Gradle/assinatura/apksigner no Windows.
- GitHub: leitura de HEAD remoto funcionou. Esquema PostgREST remoto com a chave pública
  encontrada no HTML: HTTP 401. Não houve acesso autenticado ao banco atual.

## Matriz de testes solicitados

| Item | Situação real |
| --- | --- |
| Abertura do aplicativo | Bundle/prebuild passaram; abertura no celular não executada |
| Login e-mail/senha | Implementado; login real não executado por ausência de conta de teste |
| Empresa automática | Lógica de perfil e falhas testadas com mocks; vínculo real não validado |
| Isolamento entre empresas | App não aceita ID manual; contrato RPC revisado no SQL; RLS real não testada |
| Pesquisa de produtos | Argumentos/RPC e erros testados; consulta autenticada real não executada |
| Leitura de código de barras | Correspondência/zeros testados; câmera/leitor físico não executados |
| Inclusão/remoção/edição de itens | Implementadas; interação touch no dispositivo não executada |
| Cálculo total | Testado por item com quantidade decimal e centavos |
| Abertura de caixa | Bloqueada por falta de contrato de caixa móvel independente |
| Registro de pagamentos | Bloqueado; nenhuma cobrança ou registro realizado |
| Finalização de venda | Bloqueada; nenhum comprovante ou sucesso fictício |
| Baixa de estoque | Não realizada; depende da transação confirmada do backend |
| Prevenção de venda duplicada | Escrita indisponível; idempotência transacional futura não validada |
| Fechamento de caixa | Bloqueado; não fecha o caixa do computador |
| Totais por forma de pagamento | Não exibidos como valores reais; dependem de relatório móvel do servidor |
| Nome/ícone | Assets/configuração/nativo verificados; launcher do aparelho não testado |
| APK Release sem Metro | Bundle exportado; APK final/instalação sem Metro não executados |
| Assinatura compatível | Verificador preparado; depende do keystore e APK anteriores no Windows |

Não há SDK Android/adb configurado, keystore original nem APK anterior nesta instância.
O Java encontrado é 21, enquanto o gerador Windows exige o JDK 17 do proprietário.
A tarefa admite geração no Windows nessas condições; use o .bat e as instruções anexas.
Não foram solicitadas senhas em chat nem criadas chaves substitutas.

## Arquivos alterados (todos sob `florest-pdv-movel/`)

Modificados:
- `.env.example`
- `App.tsx`
- `README.md`
- `app.json`
- `package.json`

Criados:
- `.gitignore`
- `COMO_INSTALAR_FLOREST_PDV_MOVEL.txt`
- `GERAR_APK_FLOREST_PDV_MOVEL.bat`
- `VALIDACAO.md`
- `assets/icon.png` (cópia do favicon oficial quadrado)
- `assets/logo-florest.png` (logo oficial)
- `assets/logo-florest-icone.png` (asset oficial preservado)
- `docs/INTEGRACAO-PENDENTE.md`
- `package-lock.json`
- `plugins/with-release-signing.cjs`
- `plugins/with-brand-icons.cjs`
- `scripts/build-release.cjs`
- `src/api.ts`
- `src/domain.ts`
- `src/secureStorage.ts`
- `tests/api.test.cjs`
- `tests/domain.test.cjs`
- `tests/helpers.cjs`
- `tests/storage-signing.test.cjs`

Saídas locais ignoradas: `node_modules/`, `android/`, `dist/` e eventuais caches Expo.
Nenhum arquivo do ERP/Bar/Gastronomia/PET/Fiscal/portal/Print Agent/workflows foi alterado.
Nenhuma tabela, função, trigger, política RLS ou dado de produção foi alterado.
Nenhum commit, push, deploy, publicação de ambiente ou upload de APK foi feito.

## Próximos passos do proprietário

1. Revisar as alterações do app. Não há publicação automática.
2. Configurar valores públicos, keystore original e APK anterior no Windows; executar o .bat.
3. Testar o APK no aparelho e com usuários de teste de empresas diferentes antes de distribuir.
4. Definir uma tarefa separada, com autorização específica, para o backend de caixa móvel.
   A versão atual não deve substituir um caixa de vendas até essa integração ser concluída.

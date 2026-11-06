# NF-e modelo 55 — multiempresa, implementação local

O emissor usa o CRT e os dados fiscais da empresa autenticada. Não existe uma configuração global que force CRT 1 ou 3. O suporte à transmissão depende do formato fiscal de cada item/operação, não da escolha de uma única empresa. **Implantação autorizada em 06/11/2026; veja o registro ao final. Não foi executada emissão fiscal real durante a implantação. Não cobre ainda todos os enquadramentos tributários.**

## Fluxo implementado

1. Venda existente, sem documento fiscal concorrente; pesquisar por número ou período.
2. Carregar os produtos, quantidades, preços, total, dados fiscais e cliente da venda.
3. Usar esse destinatário, preencher CPF/CNPJ manualmente ou pesquisar outro cliente da mesma empresa por nome/documento. A seleção não altera a venda nem o cadastro do cliente. A RPC de pesquisa limita o retorno a 20 registros e exige permissão fiscal/empresa ativa.
4. Conferir destinatário, endereço, natureza da operação, consumidor final, presença e transporte. CPF não contribuinte é suportado; CNPJ não é presumido contribuinte nem isento. O cliente pode precisar de IBGE/IE, ausentes no cadastro atual.
5. Dados dos produtos, CST/CSOSN, origem, PIS, COFINS, NCM, CFOP, GTIN, unidade e alíquota ICMS existente vêm do cadastro. O sistema não escolhe códigos ou alíquotas. Valores ausentes permanecem pendentes, sem substituir GTIN ausente por “SEM GTIN”.
6. Consultar listas fiscais ou calcular tributos no Dados Já, sem emissão. Totais e valores confirmados são preenchidos a partir do cálculo. Detalhes fiscais/totais ficam recolhidos na interface; não é necessário redigitar dados que o cadastro/cálculo já forneceu. Para este fluxo mínimo, confirmar operação sem frete, seguro, desconto adicional ou outras despesas; isso não altera os valores da venda.
7. Conferir os dados, confirmar explicitamente a emissão em produção e transmitir pelo backend exclusivo. Quando o operador usou o cálculo, o servidor o refaz com os valores atuais antes de reservar número e transmitir.
8. Consultar resultado e baixar XML/DANFE somente após autorização compatível com a identidade persistida.

A confirmação final solicita validação no servidor antes de habilitar o botão Emitir. Um hash da conferência impede emitir se venda, cadastro ou série mudarem desde a seleção; é preciso recarregar a conferência. Os controles ficam bloqueados durante cálculo/validação/transmissão para evitar sobrescrever edições em andamento. Troca de sessão/empresa ou seleção de outra venda invalida respostas antigas.

## Contratos oficiais e limites

Collection consultada novamente em 06/11/2026:
https://documenter.getpostman.com/view/53424652/2sBXikoBN8

JSON da própria collection:
https://documenter.getpostman.com/api/collections/53424652/2sBXikoBN8?segregateAuth=true&versionTag=latest

Exemplos com placeholders, sem credenciais:
- `documentacao/dadosjah-nfe55-exemplo-oficial.json`
- `documentacao/dadosjah-calculo-exemplo-oficial.json`

Base: `https://api-dfe.dadosjah.com.br/v1`. Login de usuário `POST /auth/user/login`, corpo `{email,password}`, retorno `data.accessToken/expiresAt`. Demais chamadas usam Bearer do usuário fiscal da empresa, somente no servidor.

| Recurso | Contrato implementado |
|---|---|
| Emissão | `POST /nfe?tpDanfe=Retrato`, `{async:false,NFe:[{idExternal,infNF}]} ` |
| Consulta | `GET /nfe?idExternal=...&tpDanfe=Retrato`, retorno `data.NFe[]` |
| XML | `GET /nfe/xml?chDfe=...&tpAmb=1`, `xml/xmlLink` |
| DANFE | `GET /nfe/danfe?chDfe=...&tpAmb=1&tpDanfe=Retrato`, `pdf/pdfLink` |
| Cálculo | `POST /tribute-calculation/out`, `UFEmitente`, `finNFe`, `det[].prod/imposto`; retorno `data.det`, `data.total.ICMSTot` |
| Listas | GET `/lists/icms`, `/lists/pis`, `/lists/ipi`, `/lists/ncm`, `/lists/cfop`, `/lists/cest`; COFINS tenta `/lists/cofins` e somente em 404 usa `/lists/confins`, ambas grafias existentes na collection |

A collection mostra paginação de listas no body de GET, incompatível com Fetch. Não foram inventados parâmetros de query. A consulta usa a página padrão retornada e informa explicitamente que é parcial. Um código ausente dessa página não é declarado inválido. Campos extras, tokens e dados não previstos são excluídos do retorno ao navegador. A lista é referência; `xmlFields` não é interpretado como prova da estrutura JSON de emissão nem como regra suficiente para selecionar tributação.

O cálculo aceita somente campos constantes no exemplo oficial, listados em `fiscal-nfe55/calculo-campos.json`. Quantidades, preços e valores vêm da venda relida no servidor, nunca do navegador. Alíquotas são do cadastro ou da conferência explícita. Não são inferidas pela UF ou regime. O cálculo não escolhe o enquadramento fiscal. Não foram enviados cálculos reais neste trabalho; os testes usam simulações.

O retorno é conferido por UF, finalidade, número de item, quantidades, preços, subtotais, origem, CST e totais. Divergência ou valor não suportado para emissão é recusado; nenhum tributo é descartado silenciosamente para fazer a nota fechar.

### Cobertura da transmissão neste estágio

- **CRT 2/3:** caminho de CST ICMS `cst90`, PIS/COFINS `07`, IPI `53` quando informado, com os campos efetivamente cobertos pelo exemplo NF-e. Mantém o CRT cadastrado. O exemplo publicado é CRT 3; o caminho CRT 2 reaproveita a estrutura normal de CST sem criar propriedades ou enums. Ambos foram testados tecnicamente com respostas simuladas, não contra autorização SEFAZ.
- **CRT 1 / CSOSN 102:** mapeia `imposto.ICMS.CSOSN="102"` e origem do cadastro, confirmado pela conversão técnica oficial modelo 55. Não usa CST normal nem cálculo separado. Outros CSOSN continuam com validação específica. PIS/COFINS vazios não recebem CST padrão; CST 49/99 sem destaque exige confirmação explícita do responsável. Veja `documentacao/nfe55-csosn102-contrato-confirmado.json`.
- **Outros CST de ICMS/PIS/COFINS/IPI:** a lista pode ser consultada, mas a emissão fica pendente quando falta confirmar o formato específico. Não é assumido que todo CST usa a estrutura exemplificada.
- **Destinatários:** CPF e CNPJ não contribuinte/isento são possíveis com dados completos. Contribuinte com IE aguarda confirmação da propriedade/tipo da inscrição na API de emissão.
- Serviços, exportações, devolução/complementar/ajuste, transporte/frete, cartões, tributação direta não coberta pelo exemplo e desconto/acréscimo não discriminado na venda exigem complementos de contrato. A diferença entre soma dos itens e total da venda não é redistribuída automaticamente.

O fluxo atual de emissão mantém totais tributários diretos/acessórios zerados para o cenário exemplificado; o cálculo pode preenchê-los automaticamente quando o enquadramento cadastrado resulta nesses valores. Resultado não zero em campo sem contrato de emissão confirmado produz pendência específica. Não se pode alterar o código do produto apenas para se enquadrar nesse caminho.

A solicitação detalhada ao suporte está em `documentacao/dadosjah-simples-pendencias.md`: CSOSN, IE, outros grupos tributários, leiaute 2026 e correção/reenvio sem duplicidade. As pendências não invalidam os outros cenários suportados de outras empresas.

## Numeração e série

Na aba principal Configurações, o painel NF-e tem “Último número da NF-e emitida”, “Série da NF-e”, confirmação do responsável e botão próprio. Usa campos exclusivos `nfe_serie`, `nfe_ultimo_numero`, `nfe_numeracao_confirmada_em` e `nfe_numeracao_confirmada_por` no cadastro fiscal. Série inicial 1, configurável de 1 a 999. Não modifica o salvamento, série, ambiente, CSC ou contador NFC-e.

As RPCs de numeração derivam a empresa do usuário. Somente Configurações permite salvar/confirmar. Não há emissão sem confirmação inicial. Informar 150/série 1 faz a próxima reserva usar 151/série 1. Outra série possui sequência própria. Considera contadores, documentos legados e reservas, inclusive série legada `001` na conferência de `1`. Redução abaixo de número conhecido é recusada.

Configuração e reserva travam a mesma linha fiscal antes do contador. Duas vendas concorrentes recebem números distintos. Dois cliques na mesma venda não criam outra reserva. A reserva só acontece após validação/autenticação/cálculo, imediatamente antes do claim e do POST fiscal. Números pendentes/rejeitados não são liberados ou reutilizados automaticamente; consulta não avança sequência. Lacunas exigem conciliação/correção ou inutilização autorizada.

## Segurança e preservação

JWT validado, empresa ativa e permissão fiscal são obrigatórios em todas as ações. Credenciais existentes são lidas por função restrita ao `service_role`, com senha no Vault se o token expirou. Login fica em memória; token compartilhado da NFC-e não é regravado. Certificado/emitente existentes não são substituídos.

A migração local cria `fiscal_nfe55_emissoes` com RLS e identidade/payload imutáveis, além dos campos/RPCs NF-e e pesquisa de clientes. Não altera vendas, clientes, produtos, estoque, pagamentos, contas, financeiro ou relatórios. No documento fiscal existente, apenas adiciona a proteção contra criação/reativação concorrente de documento para uma venda já reservada pela NF-e; sem esse vínculo retorna o registro sem alteração. Cancelamentos/rejeições continuam permitidos. Não substitui funções/payloads da NFC-e. O trigger deve ser revisado antes de autorizar instalação em produção.

Claim é persistido antes do POST. HTTP 200/201 não é autorização. Timeout, resposta incompleta, duplicidade ou falha de persistência ficam pendentes e permitem consulta, sem retransmissão automática. Autorização exige chave válida modelo 55, CNPJ, série, número, ambiente e protocolo correspondentes. Consulta não rebaixa autorização. XML/DANFE precisam corresponder à mesma nota.

## Instalação futura, somente após autorização

Aplicar a migração local revisada, publicar apenas o backend NF-e e os módulos novos da aba/configuração. O bundle da função também deve incluir o módulo compartilhado `sistema/fiscal-nfe55-modelo.js` e `calculo-campos.json`. Não substituir a função NFC-e existente. Confirmar no fornecedor as permissões NF-e da empresa/emitente/certificado e o credenciamento SEFAZ; conferir a numeração também com notas emitidas fora do ERP.

Reutilizar secrets de servidor `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `RESPTEC_CNPJ`, `RESPTEC_CONTATO`, `RESPTEC_EMAIL`, `RESPTEC_FONE`. Somente após autorização de emissão real configurar `NFE55_PRODUCAO_HABILITADA=true`. Consultas e cálculo não exigem esse sinalizador; emissão exige, além da confirmação explícita. Não há homologação separada obrigatória.

## Testes

- `node --test florest-erp/backend/tests/nfe55-core.test.mjs florest-erp/backend/tests/nfe55-automacao.test.mjs`
- `npm exec --yes --package=deno -- deno check florest-erp/funcoes-supabase/fiscal-nfe55/index.ts`
- `npm exec --yes --package=deno -- deno test florest-erp/backend/tests/nfe55-handler.test.ts`
- `NFE55_BROWSER=/caminho/playwright node --test florest-erp/sistema/tests/fiscal-nfe55.test.cjs florest-erp/sistema/tests/configuracao-nfe55.test.cjs`
- PostgreSQL local descartável: criar container novo `florest-nfe55-test` com `postgres:16-alpine`, aguardar TCP `pg_isready -h 127.0.0.1 -U postgres`, executar `python florest-erp/backend/tests/nfe55-banco.py`. Esse runner não usa token/URL de produção.

Os testes cobrem seleção CPF/CNPJ, escopo da empresa, códigos vindos do cadastro, isolamento de pendências por item/CRT, cálculo e listas com respostas simuladas, rejeição de divergências, emissão/consulta/XML/DANFE simulados, numeração, concorrência e proteção de dados. Nenhum teste transmite nota real. Não houve reserva remota, migração de produção, commit, push ou deploy.

Resultado da revisão multiempresa: 32 testes automatizados passaram (7 núcleo, 8 automação, 10 handler, 7 interface/configuração), além da bateria PostgreSQL local e validações de sintaxe/Deno. Nenhuma autorização SEFAZ real foi executada; os enquadramentos sem contrato continuam pendentes.

## Registro da implantação autorizada — 06/11/2026

- Projeto Supabase: `etulhyboogqhyyevpnlo`.
- Migração `20261106_nfe55.sql` aplicada, SHA-256 `dd5ad0ab45daca64f1dfde1c5c5908a53a1f75834a438a18a3f1f59b3f581645`.
- Tabela NF-e vazia, RLS ativo, quatro campos exclusivos no cadastro fiscal e dez funções SQL novas. As 451 funções SQL preexistentes mantiveram as definições anteriores.
- Edge Function exclusiva `fiscal-nfe55` publicada; configuração `NFE55_PRODUCAO_HABILITADA=true` ativada conforme autorização. A confirmação do operador, a validação fiscal e a conferência da numeração continuam obrigatórias.
- O cadastro da numeração não foi preenchido automaticamente para nenhuma empresa. O responsável deve confirmar série/último número antes de emitir.
- Conferência pontual da NFC-e publicada: usa `produtos.cst_csosn`, `configuracoes_fiscais.crt`, campos de produtos/emitente e distingue propriedades `CSOSN`/`CST` no payload NFC-e. Nenhum código dessa função foi modificado. A semântica de CRT/CSOSN no payload NFC-e não foi copiada automaticamente para NF-e; permanecem os bloqueios específicos do contrato modelo 55.
- A atualização do secret de ambiente pelo Supabase recarregou versões das funções existentes. Não houve reenvio de seus fontes; o bundle NFC-e foi comparado e permaneceu idêntico. Esse comportamento de recarga de secrets não altera a lógica da NFC-e.
- Frontend: publicação pela integração existente GitHub → Vercel, na branch `main`, a partir deste pacote. O relatório da execução informa a verificação do HTML servido e o commit.
- Nenhuma venda, reserva numérica ou transmissão fiscal foi executada na implantação.

## Correção pontual do CRT 1 / CSOSN 102

A tela não oferece mais os botões/painéis de cálculo tributário e listas auxiliares. A emissão valida diretamente os dados cadastrados e conferidos, sem chamada obrigatória ao cálculo. Os serviços auxiliares existentes foram preservados. A UF é normalizada apenas no payload (`mg` → `MG`), como na NFC-e, sem alterar o cadastro. GTIN ausente usa o literal técnico `SEM GTIN`, conforme o emissor atual.

Os totais do CSOSN 102 sem destaque são derivados dos itens e da confirmação da operação sem adicionais; não há escolha de CST, alíquota ou alteração da venda. Para CST 90 do Regime Normal são mantidos os totais fiscais explicitamente informados, sem presumir alíquota zero. Séries, numeração, consulta, XML/DANFE e proteção contra duplicidade permanecem iguais.

Na empresa reportada, os CSTs de PIS/COFINS do produto estão nulos. A interface abre os dados fiscais para conferência e informa exatamente esses dois campos. Não foram atribuídos 01/07/49/99 automaticamente nem atualizados os cadastros. Com os códigos válidos e demais dados obrigatórios preenchidos, o cenário CRT 1 / CSOSN 102 alcança a confirmação de emissão nos testes, sem pré-calcular. Em requisições lentas, a conferência expira com mensagem e restaura os controles, sem retransmitir.

Validação da correção: 34 testes passaram, incluindo navegador, confirmação cancelada sem envio, omissão de cálculo/listas na tela, mapeamento CSOSN, dados tributários ausentes e preservação de consulta/arquivos/numeração. Nenhuma NF-e real foi transmitida. Não houve migração, alteração de secrets/permissões, mudança na NFC-e ou gravação de cadastros nesta correção.

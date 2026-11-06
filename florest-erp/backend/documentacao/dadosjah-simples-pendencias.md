# Dados Já — evidências e pendências de Simples Nacional (06/11/2026)

Collection oficial: https://documenter.getpostman.com/view/53424652/2sBXikoBN8
JSON oficial consultado novamente: `GET https://documenter.getpostman.com/api/collections/53424652/2sBXikoBN8?segregateAuth=true&versionTag=latest` — HTTP 200.

O exemplo `Usuários → NFe → Emitir NFe` especifica `infNF.det[].imposto.ICMS.CST`, exemplificado como `cst90`, e `infNF.dest.indIEDest`. Ele não especifica como serializar CSOSN no POST `/v1/nfe`, nem o campo da IE do destinatário. Saber o código fiscal correto não basta para inferir a propriedade/enum JSON aceita pelo fornecedor.

A collection tem informações complementares:

- `GET /v1/lists/icms`: resposta `data.fiscoDetails[]` com `codeCST`, `CRT[]`, `description`, `xmlFields[]`, `group`, `tpNFDesc`. Os valores são placeholders; o exemplo mostra CST 51/CRT 3, não NF-e Simples.
- `GET /v1/lists/pis`, `GET /v1/lists/ipi`: o mesmo contrato de descrição/lista de campos. A consulta pública sem autenticação retornou HTTP 400: `Operação requer idSystem válido no contexto.`
- A collection contém duas grafias da consulta COFINS, `/lists/cofins` e `/lists/confins`. A primeira retornou HTTP 404 sem autenticação; não foi escolhida uma rota por adivinhação.
- `POST /v1/tribute-calculation/out`: documenta `ICMS.CST`, `pCredSN`, `vCredICMSSN`, bases/alíquotas e uma referência a CSOSN 500 nos comentários. É cálculo de impostos, não um exemplo de emissão NF-e. Não foi chamado, nem seus campos copiados para presumir o contrato de emissão.
- Os caminhos públicos `/docs`, `/swagger`, `/api-json`, `/swagger.json` responderam 404. O site institucional DFe respondeu 406/Mod_Security.

Nenhum token fiscal foi lido/exportado para obter essas referências e nenhuma nota ou cálculo fiscal real foi executado. Não se deve escolher arbitrariamente uma das empresas do banco para usar sua credencial durante pesquisa de documentação.

## Mensagem para enviar ao suporte Dados Já

> Estamos integrando a **emissão de NF-e modelo 55 para empresa CRT 1 — Simples Nacional**, em Minas Gerais, por **POST /v1/nfe?tpDanfe=Retrato**, com ambiente **tpAmb=1 (produção)**. Não precisamos apenas do XML: precisamos do **JSON de requisição aceito pela API**, com os nomes, tipos e valores/enums exatos. Favor enviar os exemplos sem tokens, senhas ou certificado.
>
> **1. Exemplos completos de emissão:**
> - Venda normal de mercadorias com emitente CRT 1 e destinatário CPF não contribuinte.
> - Venda normal com destinatário CNPJ contribuinte e inscrição estadual preenchida.
> - Exemplos de ICMS para CSOSN 102 e 500, indicando todos os campos exigidos em cada caso. São exemplos para documentar o contrato, não uma escolha automática da tributação da empresa. Precisamos também da documentação dos demais CSOSN quando aplicáveis aos produtos do cliente.
>
> **2. ICMS / CSOSN:** confirmar a propriedade exata em `NFe[].infNF.det[].imposto.ICMS` para enviar CSOSN: usa `CST`, `CSOSN` ou outra? O valor é texto numérico, número ou enum? Como enviar origem, crédito do Simples, ICMS-ST e valores retidos quando aplicáveis? Quais campos são obrigatórios, opcionais ou proibidos por CSOSN? Não podemos inferir a representação a partir de `cst90` do exemplo CRT 3.
>
> **3. Destinatário / IE:** confirmar a propriedade, tipo e formato da IE em `NFe[].infNF.dest`, junto de `CNPJCPF` e `indIEDest`. Enviar exemplos para indicador `1` (contribuinte), `2` (isento) e `9` (não contribuinte), informando quando a IE deve ser omitida ou preenchida. Incluir CPF com IE se esse cenário for aceito. Não basta confirmar o indicador sem mostrar onde entra a inscrição.
>
> **4. Produtos e tributos:** confirmar o formato aceito para `prod.NCM`, `prod.CFOP`, `prod.CEST` quando aplicável, e os grupos `imposto.PIS`, `imposto.COFINS` e `imposto.IPI`: CST aceitos, bases, alíquotas, valores e enquadramento do IPI quando exigidos. Explicar quando cada grupo/campo deve ser omitido e quando o zero é obrigatório. Precisamos dos campos completos de `total.ICMSTot` coerentes com os itens, inclusive ST quando aplicável. Os códigos e alíquotas efetivos serão definidos pelo responsável fiscal, não pelo integrador.
>
> **5. Regras vigentes em 2026:** para esse emitente CRT 1, quais grupos/campos de IBS/CBS e demais alterações de leiaute são obrigatórios, opcionais ou dispensados? Se exigidos, enviar exemplo do JSON e dos respectivos totais.
>
> **6. Respostas e recuperação:** enviar respostas reais anonimizadas de autorização (`cStat`, chave, protocolo e arquivos), rejeição, processamento pendente e duplicidade. Confirmar como consultar por `idExternal` após timeout; o que significa resposta vazia/404; e como corrigir uma rejeição preservando o número/série, indicando se reutiliza `idExternal` e qual método/rota permite esse reenvio sem duplicidade.
>
> **7. Habilitação:** confirmar se o usuário/emitente/certificado já usados na NFC-e podem emitir NF-e em produção sem alteração e se existe habilitação, permissão/plano ou configuração adicional exclusiva para NF-e. Não queremos modificar a integração NFC-e existente.

## Estado da implementação enquanto aguardamos

A numeração e a série são configuráveis por empresa, independentes da NFC-e, com confirmação do responsável e reserva transacional. A revisão do Simples coleta CSOSN do cadastro do produto, permite completar dados e mostra o CRT efetivo, mas frontend e backend bloqueiam a transmissão. Não existe payload Simples suposto ou fallback para CRT 3. Nenhuma configuração de produção será aplicada sem autorização.

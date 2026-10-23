# Florest Print Agent 1.2.0 — Montserrat — entrega para validação

Data: 18/10/2026.

## O que mudou

Somente a apresentação dos textos impressos: Montserrat Regular e Bold incorporadas ao Core, com licença SIL OFL 1.1 incluída; tamanho nominal de 26,4 pixels, aproximadamente 10% acima da referência ESC/POS Font A de 24 pontos. Não exige instalação de fontes no Windows. Os destaques originais de negrito, largura/altura dupla e observações em reverso foram mantidos.

O conteúdo continua sendo composto pelo TicketBuilder original. A quebra de linha mede a largura da fonte Montserrat, evitando cortar letras e evitando quebrar novamente um parágrafo já fragmentado pela antiga contagem de caracteres. Valores continuam alinhados à direita. Os separadores que já existiam continuam presentes; não foram acrescentados logotipos, enfeites ou imagens decorativas. O raster contém exclusivamente os caracteres do cupom.

Os textos são transformados em gráficos ESC/POS GS v 0, enviados pelo mesmo WinSpoolRawWriter à mesma fila. Os comandos originais de inicialização, página de código, alinhamento, destaques, avanço final e corte são preservados. O avanço das linhas gráficas é feito pelo próprio comando raster. A fonte não é substituída por outra: falha ao carregar Montserrat impede preparar o trabalho, seguindo o tratamento de erro já existente.

O tamanho físico depende da resolução e do modelo. A implementação usa a referência Font A de 12 pontos por coluna: 32 colunas = 384 pontos (configuração usual de 58 mm); 48 colunas = 576 pontos (usual de 80 mm). Não é possível confirmar essa correspondência para impressoras desconhecidas, outras larguras úteis ou outras configurações de colunas. A proporcionalidade de +10% é nominal em relação à referência, não uma medição da impressão anterior do cliente.

## Arquivos existentes modificados

1. `src/FlorestPrintAgent.Core/Jobs/TicketBuilder.cs`: composição original disponível internamente para testes; ativação de quebra medida e renderização Montserrat no caminho público de impressão; acompanhamento do estado de negrito para medição.
2. `src/FlorestPrintAgent.Core/FlorestPrintAgent.Core.csproj`: recursos de fonte incorporados, distribuição da licença e dependência Microsoft System.Drawing.Common 8.0.21 para renderizar no Windows.
3. `tests/FlorestPrintAgent.Tests/TicketTests.cs`: os testes antigos de texto ESC/POS agora verificam a composição original anterior à transformação gráfica. Essa mudança é necessária porque os caracteres já não aparecem como texto cru no documento final.

## Arquivos novos

1. `src/FlorestPrintAgent.Core/Jobs/MontserratRaster.cs`.
2. `src/FlorestPrintAgent.Core/Jobs/Fonts/Montserrat-Regular.ttf`.
3. `src/FlorestPrintAgent.Core/Jobs/Fonts/Montserrat-Bold.ttf`.
4. `src/FlorestPrintAgent.Core/Jobs/Fonts/OFL.txt`.
5. `tests/FlorestPrintAgent.Tests/MontserratPrintTests.cs`.

O CSV `ARQUIVOS-ALTERADOS.csv` contém a comparação por SHA-256 dos arquivos de fonte. Binários, caches e publicações geradas não são alterações de código. Arquivos de API, autenticação, configuração, identificação de impressoras, fila, diário, serviço, Tray, instalação e banco de dados permaneceram idênticos aos originais. Não foram executados scripts SQL nem chamadas reais ao ERP/Supabase.

## Caminhos de impressão identificados

`PrintJobProcessor.Process` resolve a impressora, carrega o layout e chama `TicketBuilder.Build`, que atende pedido de cozinha/bar, recibo não fiscal, relatório da mesa e teste. O resultado segue por `IRawPrinterWriter` para `WinSpoolRawWriter.Write`. Não foi identificado outro caminho de envio RAW no código-fonte. Cozinha e bar usam o mesmo tipo de pedido e se distinguem pelo setor/destino informado.

## Testes e compilação

- Original: 521 aprovados, zero falhas, zero ignorados.
- Alterado: 543 aprovados, zero falhas, zero ignorados.
- Os 22 casos novos incluem 20 combinações dos cinco papéis, 32/48 colunas e corte ligado/desligado; tamanho nominal e renderização efetiva de negrito, reverso, altura e largura duplas.
- Comparação do conteúdo antes/depois, desconsiderando somente espaços e quebras necessárias à nova fonte; comparação dos comandos originais e avanços em branco; validação de quantidade >1, múltiplos produtos, observação extensa, acentos, R$, preços, totais, pagamentos, caracteres muito largos e ausência do número de pedido nos papéis em que ele já era omitido.
- Os testes conferem que cada linha efetivamente desenhada cabe na largura medida e que nenhum caractere do conteúdo é descartado pela renderização.
- Os testes existentes de fila, confirmações, diário, inicialização e comunicação usam os doubles/mocks do projeto. Não representam teste ponta a ponta no ERP real nem no serviço instalado como LocalSystem.
- Service e Tray publicados em Release, Windows x64, self-contained, com zero erros. Permanecem avisos preexistentes de nulabilidade e analisadores de testes; não foram corrigidos para evitar mudanças fora do escopo.
- Instalador compilado a partir do `.iss` original com Inno Setup 6.7.3. Compilar não executa nem instala o serviço.
- Prévias PNG geradas a partir dos próprios bytes raster; conferência visual de cozinha, recibo e relatório em larguras representativas. São simulações em pixels, não fotos de impressão física.

Os registros finais estão em `testes-original/original-1.2.0.trx` e `testes-montserrat/montserrat-final.trx`. Uma execução intermediária identificou instabilidade ao recarregar fontes privadas entre trabalhos; a coleção passou a ter duração igual à do processo e a renderização foi serializada. Os testes finais incluem igualdade dos bytes entre renderizações repetidas e passaram com essa correção. Os registros intermediários não representam o estado final.

## Limitação que precisa ser validada antes da substituição

**Não está comprovada compatibilidade com “qualquer impressora”.** GS v 0 não é suportado por todos os modelos ESC/POS. O projeto não informa o modelo, a resolução ou a largura gráfica real dos equipamentos do cliente. Texto RAW funcionar não comprova que raster funcionará. A documentação da Epson confirma essa limitação: https://download4.epson.biz/sec_pubs/pos/reference_en/escpos/gs_lv_0.html.

A versão está entregue separadamente para validação. É preciso testar em cada equipamento de cozinha, bar e caixa: tamanho/legibilidade física, margens e valores em 58/80 mm conforme utilizados, observações longas, velocidade, fila, avanço e corte. O comando de corte é idêntico ao original, mas seu efeito físico não foi observado. Gaveta não possui comando no gerador original e nenhum foi adicionado.

Se um equipamento não aceitar raster ou tiver largura/resolução incompatível, não substituir a versão em produção por esta compilação. É necessário identificar o equipamento e avaliar sua renderização compatível; não existe fallback silencioso para a fonte antiga. Não foram feitos testes físicos, instalação, desinstalação, inicialização do agente ou consumo de trabalhos reais neste ambiente.

## Preservação da versão original

O ZIP original permaneceu intocado e foi extraído integralmente em `work/original-1.2.0`, separado das pastas de validação e alteração. SHA-256 do ZIP recebido:

`673AFBFFFAA6F54B10F3CF91DBAF649771EA0E077A04C0F7C514A760D1E0C8E9`

O projeto entregue omite os antigos `bin`, `obj` e `dist` para não misturar executáveis anteriores com a compilação Montserrat. Todos os fontes e scripts originais restantes foram preservados, salvo a lista explícita de alterações acima. O número interno 1.2.0 e o AppId do instalador foram mantidos; o nome externo contém MONTSERRAT/VALIDACAO para distinguir a entrega.

## Validação separada e instalação futura preservando configurações

1. Guardar o instalador/ZIP original 1.2.0 e um backup seguro dos binários e de `C:\ProgramData\Florest Sistemas\Print Agent\`, antes de qualquer atualização futura. A credencial DPAPI depende do computador original; o backup não transforma essa credencial em credencial portável.
2. Validar primeiro em computador ou ambiente de homologação, com dados fictícios e impressoras de teste. O instalador usa o mesmo serviço e AppId: **não cria uma segunda instalação independente no mesmo Windows**. Não executá-lo no computador de produção para tentar validar em paralelo.
3. No ambiente separado, usar somente empresa/estação de homologação para testes de comunicação e jobs. Não copiar nem utilizar o vínculo de produção. Testar os cinco tipos de impressão, margens, observações, valores e corte em cada modelo real antes de aprovar.
4. Somente após essa validação e aprovação operacional, executar `FlorestPrintAgent-1.2.0-Montserrat-VALIDACAO.exe` no computador original, como atualização sobre a instalação existente. O instalador original fecha o Tray, para o serviço, troca os binários e reinicia o serviço; `ProgramData` é preservada e não deveria ser necessário parear novamente. Fazer isso em janela de manutenção sem pedidos em andamento.
5. Não desinstalar antes, não apagar `ProgramData`, não alterar `impressao.json` nem copiar somente um EXE/DLL isolado. A pasta publicada tem runtime e dependências que precisam acompanhar o aplicativo.
6. Conferir empresa/estação preservadas, estado do serviço, comunicação e testes controlados autorizados. Se houver falha, interromper o uso da compilação Montserrat e restaurar os binários originais na mesma máquina, preservando os dados e o diário; não apagar o diário nem disparar reimpressões manuais sem conferir os trabalhos.

Alternativa técnica ao Setup, somente depois da mesma validação: extrair `FlorestPrintAgent-1.2.0-Montserrat-app.zip` e usar o `scripts/install-service.ps1` original do projeto, como Administrador, informando `-SourceDir` para a pasta completa extraída. Esse script também altera a instalação existente; não foi executado nesta entrega.

## Fontes e licença

Montserrat Regular/Bold e OFL obtidas do projeto oficial: https://github.com/JulietaUla/Montserrat. Os TTF estão incorporados como recursos do Core; `Jobs/Fonts/OFL.txt` acompanha os binários e a licença também está no projeto. System.Drawing.Common é uma dependência Microsoft destinada ao Windows. Não foi exigida instalação manual de fontes nem alterada a inicialização do aplicativo.

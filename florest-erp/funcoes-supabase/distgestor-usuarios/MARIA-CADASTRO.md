# Cadastro de funcionário com MARIA — item 3

Correção aprovada em 23/10/2026. Base do Git: d75c3a0e11e1c8242dc41835706929620154a25f. Base implantada: distgestor-usuarios versão 26, fonte idêntico ao Git antes desta correção.

A única mudança no index.ts é acrescentar maria_acessar à lista de permissões aceitas. A permissão continua sendo enviada apenas quando marcada no formulário. Não concede acesso automaticamente, não atualiza perfis existentes e não altera autenticação, senhas, proprietários, garçons ou autorização de cancelamentos.

Validação local: seis testes sobre o validador real, incluindo preservação integral do fonte anterior fora dessa linha. Sem criação de funcionários reais.

## Aplicação no Supabase — concluída em 23/10/2026

Publicar este index.ts na Edge Function **distgestor-usuarios**, projeto **ERP FLOREST (etulhyboogqhyyevpnlo)**, preservando configurações, secrets e verificação JWT atuais. Comparar novamente a versão implantada antes de substituir: se deixou de ser v26 ou se o fonte mudou, reaplicar somente a inclusão da permissão sobre o fonte novo.

Publicar o arquivo no Git não atualiza automaticamente essa Edge. Após autorização no chat, o deploy foi executado: distgestor-usuarios v27, ACTIVE, verify_jwt=true. O fonte implantado foi recuperado e conferido como idêntico ao aprovado. Não é necessário reinstalar a MARIA inteira nem alterar permissões dos usuários. O HTML já oferece a opção e a lista de permissões do banco já a contempla na versão conferida.

Após aplicação autorizada, testar com conta de teste: criar funcionário com permissão marcada e confirmar acesso; criar sem a permissão e confirmar bloqueio. Esses testes alteram cadastros e devem ocorrer em ambiente adequado.

Reversão: recuperar o fonte do commit-base acima para distgestor-usuarios, se não houver mudanças posteriores. Não apagar a permissão de usuários existentes para reverter o validador.

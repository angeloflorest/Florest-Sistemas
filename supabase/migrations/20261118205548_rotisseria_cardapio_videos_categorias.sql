BEGIN;
DO $g$ BEGIN IF md5(regexp_replace(replace(pg_get_functiondef('private.rotisseria_rpc(text,jsonb,uuid)'::regprocedure),chr(13)||chr(10),chr(10)),'[[:space:]]+$',''))<>'ab398e49645334cbcf3a565376e3d0df' THEN RAISE EXCEPTION 'Base alterada: rotisseria_rpc';END IF;END $g$;
DO $g$ BEGIN IF md5(regexp_replace(replace(pg_get_functiondef('private.rotisseria_cardapio_admin(text,jsonb)'::regprocedure),chr(13)||chr(10),chr(10)),'[[:space:]]+$',''))<>'d9080f96d1deccc5365f7af66cca497a' THEN RAISE EXCEPTION 'Base alterada: rotisseria_cardapio_admin';END IF;END $g$;
DO $g$ BEGIN IF md5(regexp_replace(replace(pg_get_functiondef('private.rotisseria_cardapio_publico(text,text,jsonb,uuid,text)'::regprocedure),chr(13)||chr(10),chr(10)),'[[:space:]]+$',''))<>'1aab24c2d7e9cb333f9399f315d4aee9' THEN RAISE EXCEPTION 'Base alterada: rotisseria_cardapio_publico';END IF;END $g$;
ALTER TABLE private.rotisseria_cardapio_config ADD COLUMN video1 text, ADD COLUMN video2 text;
CREATE TABLE private.rotisseria_cardapio_categorias(
 id uuid PRIMARY KEY,empresa_id uuid NOT NULL REFERENCES public.empresas(id),pai uuid,nome text NOT NULL CHECK(length(btrim(nome)) BETWEEN 1 AND 80),ordem integer NOT NULL DEFAULT 0 CHECK(ordem BETWEEN 0 AND 9999),UNIQUE(empresa_id,id),FOREIGN KEY(empresa_id,pai) REFERENCES private.rotisseria_cardapio_categorias(empresa_id,id),CHECK(pai IS NULL OR pai<>id));
CREATE UNIQUE INDEX rotisseria_cardapio_categoria_nome ON private.rotisseria_cardapio_categorias(empresa_id,coalesce(pai,'00000000-0000-0000-0000-000000000000'::uuid),lower(nome));
ALTER TABLE private.rotisseria_cardapio_categorias ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.rotisseria_cardapio_categorias FROM PUBLIC,anon,authenticated;
CREATE TABLE private.rotisseria_cardapio_classificacao(empresa_id uuid NOT NULL,produto_id uuid NOT NULL,categoria_id uuid NOT NULL,PRIMARY KEY(empresa_id,produto_id),FOREIGN KEY(empresa_id,produto_id) REFERENCES public.produtos(empresa_id,id),FOREIGN KEY(empresa_id,categoria_id) REFERENCES private.rotisseria_cardapio_categorias(empresa_id,id) ON DELETE CASCADE);
CREATE INDEX rotisseria_cardapio_classificacao_categoria ON private.rotisseria_cardapio_classificacao(empresa_id,categoria_id);
ALTER TABLE private.rotisseria_cardapio_classificacao ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.rotisseria_cardapio_classificacao FROM PUBLIC,anon,authenticated;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('rotisseria-cardapio-videos','rotisseria-cardapio-videos',true,26214400,ARRAY['video/mp4','video/webm']);
CREATE FUNCTION private.rotisseria_video_autorizado(p_nome text) RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT private.perm('rotisseria_configurar') OR NOT private.empresa_tem_modulo('rotisseria') THEN RETURN false;END IF;
 e:=private.exigir_empresa_ativa();
 RETURN p_nome ~ ('^'||e::text||'/[12]-[a-f0-9-]{36}\.(mp4|webm)$');
END $$;
REVOKE ALL ON FUNCTION private.rotisseria_video_autorizado(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.rotisseria_video_autorizado(text) TO authenticated;
CREATE POLICY rotisseria_video_inserir ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='rotisseria-cardapio-videos' AND private.rotisseria_video_autorizado(name));
CREATE POLICY rotisseria_video_ler ON storage.objects FOR SELECT TO authenticated USING(bucket_id='rotisseria-cardapio-videos' AND private.rotisseria_video_autorizado(name));
CREATE POLICY rotisseria_video_excluir ON storage.objects FOR DELETE TO authenticated USING(bucket_id='rotisseria-cardapio-videos' AND private.rotisseria_video_autorizado(name));
CREATE FUNCTION private.rotisseria_cardapio_extras(p_empresa uuid,p_admin boolean DEFAULT false) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT jsonb_build_object('categorias',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'pai',pai,'nome',nome,'ordem',ordem) ORDER BY ordem,nome,id) FROM private.rotisseria_cardapio_categorias WHERE empresa_id=p_empresa),'[]'),'videos',coalesce((SELECT jsonb_agg(jsonb_build_object('slot',x.slot,'url','https://etulhyboogqhyyevpnlo.supabase.co/storage/v1/object/public/rotisseria-cardapio-videos/'||x.path)||CASE WHEN p_admin THEN jsonb_build_object('path',x.path) ELSE '{}'::jsonb END ORDER BY x.slot) FROM private.rotisseria_cardapio_config cfg CROSS JOIN LATERAL(VALUES(1,cfg.video1),(2,cfg.video2)) x(slot,path) WHERE cfg.empresa_id=p_empresa AND nullif(x.path,'') IS NOT NULL),'[]'))
$$;
REVOKE ALL ON FUNCTION private.rotisseria_cardapio_extras(uuid,boolean) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.rotisseria_cardapio_extras_admin(p_acao text,p_dados jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
#variable_conflict use_column
DECLARE e uuid:=private.exigir_empresa_ativa();cid uuid:=nullif(p_dados->>'id','')::uuid;parent_id uuid:=nullif(p_dados->>'pai','')::uuid;pid uuid:=nullif(p_dados->>'produto_id','')::uuid;slot int:=(p_dados->>'slot')::int;path text:=nullif(p_dados->>'path','');titulo text:=btrim(p_dados->>'nome');
BEGIN
 IF NOT private.empresa_tem_modulo('rotisseria') OR NOT private.perm('rotisseria_configurar') THEN RAISE EXCEPTION 'Sem permissão para configurar o cardápio.' USING errcode='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':rotisseria-menu-extras',0));
 INSERT INTO private.rotisseria_cardapio_config(empresa_id) VALUES(e) ON CONFLICT DO NOTHING;
 IF p_acao='cardapio_video_salvar' THEN
  IF slot IS NULL OR slot NOT IN (1,2) THEN RAISE EXCEPTION 'Escolha o vídeo 1 ou 2.';END IF;
  IF path IS NOT NULL AND (NOT private.rotisseria_video_autorizado(path) OR path NOT LIKE e::text||'/'||slot||'-%' OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='rotisseria-cardapio-videos' AND name=path)) THEN RAISE EXCEPTION 'Envie um vídeo válido desta empresa antes de salvar.';END IF;
  UPDATE private.rotisseria_cardapio_config SET video1=CASE WHEN slot=1 THEN path ELSE video1 END,video2=CASE WHEN slot=2 THEN path ELSE video2 END WHERE empresa_id=e;
 ELSIF p_acao='cardapio_categoria_salvar' THEN
  IF cid IS NULL OR titulo IS NULL OR length(titulo) NOT BETWEEN 1 AND 80 OR coalesce((p_dados->>'ordem')::int,0) NOT BETWEEN 0 AND 9999 THEN RAISE EXCEPTION 'Informe o nome e a ordem da categoria.';END IF;
  IF EXISTS(SELECT 1 FROM private.rotisseria_cardapio_categorias WHERE id=cid AND empresa_id<>e) THEN RAISE EXCEPTION 'Categoria de outra empresa.' USING errcode='42501';END IF;
  IF parent_id IS NOT NULL AND (parent_id=cid OR NOT EXISTS(SELECT 1 FROM private.rotisseria_cardapio_categorias WHERE empresa_id=e AND id=parent_id AND pai IS NULL) OR EXISTS(SELECT 1 FROM private.rotisseria_cardapio_categorias WHERE empresa_id=e AND pai=cid)) THEN RAISE EXCEPTION 'Selecione uma categoria principal. Não é permitido criar ciclos ou mais de dois níveis.';END IF;
  IF NOT EXISTS(SELECT 1 FROM private.rotisseria_cardapio_categorias WHERE empresa_id=e AND id=cid) AND (SELECT count(*) FROM private.rotisseria_cardapio_categorias WHERE empresa_id=e)>=100 THEN RAISE EXCEPTION 'O limite é 100 categorias e subcategorias.';END IF;
  INSERT INTO private.rotisseria_cardapio_categorias(id,empresa_id,pai,nome,ordem) VALUES(cid,e,parent_id,titulo,coalesce((p_dados->>'ordem')::int,0)) ON CONFLICT(id) DO UPDATE SET pai=excluded.pai,nome=excluded.nome,ordem=excluded.ordem;
 ELSIF p_acao='cardapio_categoria_excluir' THEN
  IF EXISTS(SELECT 1 FROM private.rotisseria_cardapio_categorias WHERE empresa_id=e AND pai=cid) THEN RAISE EXCEPTION 'Remova ou mova as subcategorias antes de excluir a categoria principal.';END IF;
  DELETE FROM private.rotisseria_cardapio_categorias WHERE empresa_id=e AND id=cid;
 ELSIF p_acao='cardapio_categoria_produto' THEN
  IF NOT EXISTS(SELECT 1 FROM public.produtos WHERE empresa_id=e AND id=pid AND ativo) OR (cid IS NOT NULL AND NOT EXISTS(SELECT 1 FROM private.rotisseria_cardapio_categorias WHERE empresa_id=e AND id=cid)) THEN RAISE EXCEPTION 'Produto ou categoria indisponível nesta empresa.';END IF;
  IF cid IS NULL THEN DELETE FROM private.rotisseria_cardapio_classificacao WHERE empresa_id=e AND produto_id=pid;
  ELSE INSERT INTO private.rotisseria_cardapio_classificacao(empresa_id,produto_id,categoria_id) VALUES(e,pid,cid) ON CONFLICT(empresa_id,produto_id) DO UPDATE SET categoria_id=excluded.categoria_id;END IF;
 ELSE RAISE EXCEPTION 'Ação inválida.';END IF;
 RETURN private.rotisseria_cardapio_extras(e,true);
END $$;
REVOKE ALL ON FUNCTION private.rotisseria_cardapio_extras_admin(text,jsonb) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.rotisseria_rpc(p_acao text, p_dados jsonb DEFAULT '{}'::jsonb, p_chave uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
DECLARE
 e uuid:=private.exigir_empresa_ativa(); u uuid:=auth.uid(); cfg private.rotisseria_config; s private.rotisseria_sessoes;
 c public.caixas; prod public.produtos; it private.rotisseria_itens; r record; result jsonb; arr jsonb; n bigint; vid uuid; pid uuid;
 qtd numeric; total numeric; pago numeric; troco numeric:=0; forma text; cpf text; disponivel numeric; permitido boolean; dispositivo boolean; expected bigint; catalogo boolean;
BEGIN
 IF NOT private.empresa_tem_modulo('rotisseria') OR NOT private.perm('rotisseria_visualizar') THEN RAISE EXCEPTION 'Módulo Rotisseria não liberado para este usuário e empresa.' USING errcode='42501'; END IF;
 IF p_acao IN ('cardapio_video_salvar','cardapio_categoria_salvar','cardapio_categoria_excluir','cardapio_categoria_produto') THEN RETURN private.rotisseria_cardapio_extras_admin(p_acao,p_dados);END IF;
 IF p_acao IN ('cardapio_dados','cardapio_salvar','cardapio_produto') THEN RETURN private.rotisseria_cardapio_admin(p_acao,p_dados);END IF;
 IF p_acao IN ('catalogo_listar','catalogo_obter','catalogo_venda','catalogo_base','catalogo_salvar','catalogo_ativar','foto_listar','foto_salvar') THEN RETURN private.rotisseria_catalogo_rpc(p_acao,p_dados);END IF;
 IF p_acao='lancar' AND EXISTS(SELECT 1 FROM private.rotisseria_catalogo WHERE empresa_id=e AND produto_id=(p_dados->>'produto_id')::uuid) THEN RETURN private.rotisseria_lancar_catalogo(p_dados);END IF;
 IF p_acao IN ('config_salvar','abrir_comanda') THEN PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':rotisseria-config',0)); END IF;
 SELECT * INTO cfg FROM private.rotisseria_config WHERE empresa_id=e;
 IF NOT FOUND THEN cfg.quantidade:=5;cfg.destaques:=10;cfg.produtos:='[]'; END IF;
 SELECT EXISTS(SELECT 1 FROM private.rotisseria_dispositivo d WHERE d.empresa_id=e AND d.token=p_chave AND d.usuario_id=u) INTO dispositivo;
 IF p_acao='contexto' THEN
  catalogo:=nullif(p_dados->>'config_em','')::timestamptz IS DISTINCT FROM cfg.atualizado_em OR cfg.atualizado_em IS NULL;
  SELECT coalesce(jsonb_agg(jsonb_build_object('numero',g.numero,'id',s.id,'versao',s.versao,'criado_em',s.criado_em,'total',coalesce(x.total,0),'itens',coalesce(x.itens,0),'saldo',greatest(0,coalesce(x.total,0)-coalesce(pay.valor,0))) ORDER BY g.numero),'[]') INTO arr
  FROM generate_series(1,cfg.quantidade) g(numero) LEFT JOIN private.rotisseria_sessoes s ON s.empresa_id=e AND s.numero=g.numero AND s.estado='aberta' AND s.origem='comanda'
  LEFT JOIN LATERAL(SELECT sum(i.subtotal) total,count(*) itens FROM private.rotisseria_itens i WHERE i.empresa_id=e AND i.sessao_id=s.id AND NOT i.cancelado) x ON true
  LEFT JOIN LATERAL(SELECT sum(p.valor) valor FROM private.rotisseria_pagamentos p WHERE p.empresa_id=e AND p.sessao_id=s.id) pay ON true;
  arr:=arr||(SELECT coalesce(jsonb_agg(jsonb_build_object('numero',ds.numero,'id',ds.id,'origem','cardapio','solicitante',ds.solicitante,'versao',ds.versao,'criado_em',ds.criado_em,'total',(saldo->>'total')::numeric,'saldo',(saldo->>'saldo')::numeric,'itens',(SELECT count(*) FROM private.rotisseria_itens di WHERE di.empresa_id=e AND di.sessao_id=ds.id AND NOT di.cancelado)) ORDER BY ds.numero),'[]') FROM private.rotisseria_sessoes ds CROSS JOIN LATERAL private.rotisseria_saldo(ds.id,e) saldo WHERE ds.empresa_id=e AND ds.estado='aberta' AND ds.origem='cardapio');
  SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' AND status='aberto';
  RETURN jsonb_build_object('empresa_id',e,'config',CASE WHEN catalogo THEN to_jsonb(cfg) ELSE to_jsonb(cfg)-'produtos' END,'comandas',arr,'caixa',CASE WHEN c.id IS NOT NULL THEN private.caixa_json(c) ELSE NULL END,'dispositivo_caixa',dispositivo,
   'permissoes',jsonb_build_object('lancar',private.perm('rotisseria_lancar'),'caixa',private.perm('rotisseria_caixa'),'configurar',private.perm('rotisseria_configurar')),
   'destaques',CASE WHEN catalogo THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nome',p.nome,'codigo',p.codigo,'gtin',p.gtin,'preco_venda',p.preco_venda,'unidade_comercial',p.unidade_comercial,'venda_granel',p.venda_granel,'foto',coalesce(f.foto,x->>'foto'),'tipo_item',c.tipo,'catalogo_id',c.id,'modelo',c.modelo,'catalogo_versao',c.versao) ORDER BY ord),'[]') FROM jsonb_array_elements(cfg.produtos) WITH ORDINALITY t(x,ord) JOIN public.produtos p ON p.id=(x->>'id')::uuid AND p.empresa_id=e AND p.ativo LEFT JOIN private.rotisseria_catalogo c ON c.empresa_id=e AND c.produto_id=p.id LEFT JOIN private.rotisseria_fotos f ON f.empresa_id=e AND f.produto_id=p.id WHERE ord<=cfg.destaques AND (c.id IS NULL OR c.ativo)) ELSE NULL END);
 ELSIF p_acao='buscar' THEN
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM (SELECT p.id,p.nome,p.codigo,p.gtin,p.unidade_comercial,p.venda_granel,p.preco_venda,p.quantidade_estoque,c.id catalogo_id,c.tipo tipo_item,c.modelo,c.versao catalogo_versao,coalesce(f.foto,'') foto FROM public.produtos p LEFT JOIN private.rotisseria_catalogo c ON c.empresa_id=p.empresa_id AND c.produto_id=p.id LEFT JOIN private.rotisseria_fotos f ON f.empresa_id=p.empresa_id AND f.produto_id=p.id WHERE p.empresa_id=e AND p.ativo AND (c.id IS NULL OR c.ativo) AND (p.nome ILIKE '%'||left(coalesce(p_dados->>'busca',''),100)||'%' OR p.codigo ILIKE '%'||left(p_dados->>'busca',100)||'%' OR p.gtin=p_dados->>'busca') ORDER BY p.nome,p.id LIMIT 40) x);
 ELSIF p_acao='clientes' THEN
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM (SELECT id,nome FROM public.clientes WHERE empresa_id=e AND nome ILIKE '%'||left(coalesce(p_dados->>'busca',''),100)||'%' ORDER BY nome,id LIMIT 30) x);
 ELSIF p_acao='config_dados' THEN
  IF NOT private.perm('rotisseria_configurar') THEN RAISE EXCEPTION 'Sem permissão para configurar.' USING errcode='42501'; END IF;
  RETURN jsonb_build_object('config',to_jsonb(cfg),'impressoras',(SELECT coalesce(jsonb_agg(to_jsonb(p)),'[]') FROM public.impressoras p WHERE empresa_id=e AND ativa));
 ELSIF p_acao='config_salvar' THEN
  IF NOT private.perm('rotisseria_configurar') THEN RAISE EXCEPTION 'Sem permissão para configurar.' USING errcode='42501'; END IF;
  IF (p_dados->>'quantidade')::int NOT BETWEEN 1 AND 50 OR (p_dados->>'destaques')::int NOT BETWEEN 0 AND 20 OR p_dados->>'quantidade' IS NULL OR p_dados->>'destaques' IS NULL THEN RAISE EXCEPTION 'Informe de 1 a 50 comandas e de 0 a 20 destaques.'; END IF;
  IF EXISTS(SELECT 1 FROM private.rotisseria_sessoes WHERE empresa_id=e AND origem='comanda' AND estado='aberta' AND numero>(p_dados->>'quantidade')::int) THEN RAISE EXCEPTION 'Finalize as comandas abertas antes de reduzir a quantidade.'; END IF;
  arr:=coalesce(p_dados->'produtos','[]');
  IF jsonb_typeof(arr)<>'array' OR jsonb_array_length(arr)>20 OR octet_length(arr::text)>2000000 THEN RAISE EXCEPTION 'Configuração de fotos inválida.'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(arr) x WHERE NOT EXISTS(SELECT 1 FROM public.produtos p WHERE p.id=(x->>'id')::uuid AND p.empresa_id=e AND p.ativo) OR (coalesce(x->>'foto','')<>'' AND (x->>'foto' NOT LIKE 'data:image/jpeg;base64,%' OR length(x->>'foto')>100000))) THEN RAISE EXCEPTION 'Produto ou foto inválido.'; END IF;
  INSERT INTO private.rotisseria_fotos(empresa_id,produto_id,foto) SELECT e,(x->>'id')::uuid,coalesce(x->>'foto','') FROM jsonb_array_elements(arr) x ON CONFLICT(empresa_id,produto_id) DO UPDATE SET foto=excluded.foto;
  IF (SELECT count(*)<>count(DISTINCT x->>'id') FROM jsonb_array_elements(arr) x) THEN RAISE EXCEPTION 'Produto repetido nos destaques.'; END IF;
  IF nullif(p_dados->>'impressora_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.impressoras WHERE empresa_id=e AND ativa AND id=(p_dados->>'impressora_id')::uuid) THEN RAISE EXCEPTION 'Impressora de outra empresa ou inexistente.'; END IF;
  INSERT INTO private.rotisseria_config(empresa_id,quantidade,destaques,produtos,impressora_id) VALUES(e,(p_dados->>'quantidade')::int,(p_dados->>'destaques')::int,arr,nullif(p_dados->>'impressora_id','')::uuid)
  ON CONFLICT(empresa_id) DO UPDATE SET quantidade=excluded.quantidade,destaques=excluded.destaques,produtos=excluded.produtos,impressora_id=excluded.impressora_id,atualizado_em=now();
 ELSIF p_acao='caixa_vincular' THEN
  IF NOT private.perm('rotisseria_caixa') OR p_chave IS NULL THEN RAISE EXCEPTION 'Sem permissão para definir dispositivo de caixa.' USING errcode='42501'; END IF;
  INSERT INTO private.rotisseria_dispositivo(empresa_id,token,usuario_id,nome) VALUES(e,p_chave,u,left(coalesce(nullif(btrim(p_dados->>'nome'),''),'Caixa Rotisseria'),80)) ON CONFLICT(empresa_id) DO UPDATE SET token=excluded.token,usuario_id=excluded.usuario_id,nome=excluded.nome,atualizado_em=now();
 ELSIF p_acao IN ('caixa_abrir','caixa_fechar','receber','fiscal') THEN
  IF NOT dispositivo OR NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Recebimentos e caixa são exclusivos do dispositivo definido como Caixa da Rotisseria.' USING errcode='42501'; END IF;
  IF p_acao='caixa_abrir' THEN RETURN public.caixa_abrir('ROTISSERIA',(p_dados->>'valor')::numeric); END IF;
  IF p_acao='caixa_fechar' THEN
   SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND id=(p_dados->>'id')::uuid AND tipo_caixa='ROTISSERIA';
   IF c.id IS NULL THEN RAISE EXCEPTION 'Caixa da Rotisseria não encontrado.'; END IF;
   RETURN public.caixa_fechar(c.id);
  END IF;
  IF p_acao='fiscal' THEN
   IF NOT EXISTS(SELECT 1 FROM private.rotisseria_sessoes WHERE empresa_id=e AND venda_id=(p_dados->>'venda_id')::uuid AND estado='concluida') THEN RAISE EXCEPTION 'Venda da Rotisseria não encontrada.'; END IF;
   IF NOT private.perm('fiscal') AND NOT private.perm('pdv') THEN RAISE EXCEPTION 'Libere a permissão Fiscal ao operador para emitir NFC-e.' USING errcode='42501'; END IF;
   RETURN (SELECT coalesce(jsonb_agg(to_jsonb(d)),'[]') FROM public.fiscal_emitir_nota((p_dados->>'venda_id')::uuid) d);
  END IF;
  RETURN private.rotisseria_receber(p_dados,p_chave);
 ELSIF p_acao='abrir_comanda' THEN
  IF NOT private.perm('rotisseria_lancar') THEN RAISE EXCEPTION 'Sem permissão para abrir comanda.' USING errcode='42501'; END IF;
  n:=(p_dados->>'numero')::int;
  IF n IS NULL OR n NOT BETWEEN 1 AND cfg.quantidade THEN RAISE EXCEPTION 'Número de comanda inválido.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':rotisseria:'||n::text,0));
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND numero=n AND origem='comanda' AND estado='aberta';
  IF s.id IS NULL THEN INSERT INTO private.rotisseria_sessoes(empresa_id,numero,criado_por) VALUES(e,n,u) RETURNING * INTO s; END IF;
  result:=to_jsonb(s);
 ELSIF p_acao IN ('lancar','cancelar_item','fechar_vazia') THEN
  IF NOT private.perm('rotisseria_lancar') THEN RAISE EXCEPTION 'Sem permissão para lançar na comanda.' USING errcode='42501'; END IF;
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid FOR UPDATE;
  IF s.id IS NULL OR s.estado<>'aberta' THEN RAISE EXCEPTION 'Comanda encerrada ou inexistente. Abra novamente na grade.'; END IF;
  IF p_acao='lancar' THEN
   IF nullif(p_dados->>'chave','') IS NULL THEN RAISE EXCEPTION 'Chave do lançamento obrigatória.'; END IF;
   SELECT * INTO it FROM private.rotisseria_itens WHERE empresa_id=e AND chave=(p_dados->>'chave')::uuid;
   IF it.id IS NOT NULL THEN
    IF it.sessao_id<>s.id OR it.produto_id<>(p_dados->>'produto_id')::uuid OR it.quantidade<>(p_dados->>'quantidade')::numeric THEN RAISE EXCEPTION 'Chave já utilizada por outro lançamento.'; END IF;
    RETURN jsonb_build_object('item_id',it.id,'repetido',true);
   END IF;
   qtd:=(p_dados->>'quantidade')::numeric;
   IF qtd IS NULL OR qtd<=0 OR qtd>999999999 OR qtd<>round(qtd,4) THEN RAISE EXCEPTION 'Quantidade inválida, use até quatro casas decimais.'; END IF;
   SELECT * INTO prod FROM public.produtos WHERE empresa_id=e AND id=(p_dados->>'produto_id')::uuid AND ativo FOR UPDATE;
   IF prod.id IS NULL OR prod.tipo_fiscal='servico' THEN RAISE EXCEPTION 'Selecione um produto ativo para venda.'; END IF;
   IF NOT(prod.venda_granel OR upper(coalesce(prod.unidade_comercial,'')) IN ('KG','K','QUILO')) AND qtd<>trunc(qtd) THEN RAISE EXCEPTION 'Este produto é vendido por unidade. Informe uma quantidade inteira.'; END IF;
   IF (p_dados->>'preco')::numeric IS NULL OR (p_dados->>'preco')::numeric<>prod.preco_venda THEN RAISE EXCEPTION 'O preço do produto mudou. Pesquise novamente antes de lançar.'; END IF;
   IF s.estoque_baixado THEN
    SELECT coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false) INTO permitido;
    IF NOT permitido AND prod.quantidade_estoque<qtd THEN RAISE EXCEPTION 'Estoque insuficiente de %.',prod.nome; END IF;
    UPDATE public.produtos SET quantidade_estoque=quantidade_estoque-qtd WHERE empresa_id=e AND id=prod.id;
   END IF;
   INSERT INTO private.rotisseria_itens(empresa_id,sessao_id,produto_id,nome,unidade,quantidade,preco,chave,criado_por) VALUES(e,s.id,prod.id,prod.nome,coalesce(prod.unidade_comercial,'UN'),qtd,prod.preco_venda,(p_dados->>'chave')::uuid,u) RETURNING id INTO pid;
   result:=jsonb_build_object('item_id',pid);
  ELSIF p_acao='cancelar_item' THEN
   SELECT * INTO it FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND id=(p_dados->>'item_id')::uuid AND NOT cancelado;
   IF it.id IS NULL THEN RAISE EXCEPTION 'Item não encontrado ou já cancelado.'; END IF;
   IF it.subtotal>(private.rotisseria_saldo(s.id,e)->>'saldo')::numeric THEN RAISE EXCEPTION 'O cancelamento deixaria o consumo menor que o valor já pago.'; END IF;
   IF s.estoque_baixado THEN FOR r IN SELECT * FROM private.rotisseria_baixas(e,s.id,it.id) ORDER BY produto_id LOOP UPDATE public.produtos SET quantidade_estoque=quantidade_estoque+r.qtd WHERE empresa_id=e AND id=r.produto_id; END LOOP;END IF;
   UPDATE private.rotisseria_itens SET cancelado=true WHERE empresa_id=e AND id=it.id;
   IF (private.rotisseria_saldo(s.id,e)->>'saldo')::numeric=0 AND s.estoque_baixado THEN result:=private.rotisseria_consolidar(s.id,e); END IF;
  ELSE
   IF EXISTS(SELECT 1 FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado) THEN RAISE EXCEPTION 'A comanda ainda possui itens.'; END IF;
   UPDATE private.rotisseria_sessoes SET estado='cancelada',finalizado_em=now() WHERE empresa_id=e AND id=s.id;
  END IF;
  UPDATE private.rotisseria_sessoes SET versao=versao+1 WHERE empresa_id=e AND id=s.id;
 ELSIF p_acao='detalhe' THEN
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada.'; END IF;
  RETURN to_jsonb(s)||private.rotisseria_saldo(s.id,e)||jsonb_build_object('itens',(SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY criado_em,id),'[]') FROM private.rotisseria_itens i WHERE empresa_id=e AND sessao_id=s.id),'total',(SELECT coalesce(sum(subtotal),0) FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado));
 ELSIF p_acao='imprimir_comanda' THEN
  IF NOT private.perm('rotisseria_lancar') AND NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Sem permissão para imprimir comanda.' USING errcode='42501'; END IF;
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid AND estado IN ('aberta','concluida') FOR SHARE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada nesta empresa.'; END IF;
  SELECT jsonb_agg(x.value ORDER BY i.criado_em,i.id,x.ord) INTO arr FROM private.rotisseria_itens i CROSS JOIN LATERAL private.rotisseria_item_impressao(i) WITH ORDINALITY x(value,ord) WHERE i.empresa_id=e AND i.sessao_id=s.id AND NOT i.cancelado;
  IF arr IS NULL THEN RAISE EXCEPTION 'A comanda não possui produtos para imprimir.'; END IF;
  result:=private.rotisseria_saldo(s.id,e);
  result:=jsonb_build_object('versao',1,'tipo','recibo','rotisseria_impressora_propria',true,'rotisseria_comanda_id',s.id,'numero_comanda',s.numero,'origem',s.origem,
   'empresa_nome',(SELECT nome FROM public.empresas WHERE id=e),'empresa',CASE WHEN s.origem='cardapio' THEN 'PEDIDO ' ELSE 'COMANDA ' END||s.numero||' — '||(SELECT nome FROM public.empresas WHERE id=e),'setor','ROTISSERIA','data_hora',to_char(now() AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),
   'itens',arr,'total',(result->>'total')::numeric,'ja_pago',(result->>'total_pago')::numeric,'falta_pagar',(result->>'saldo')::numeric,
   'pagamentos',jsonb_build_array(jsonb_build_object('forma','Total já pago','valor',(result->>'total_pago')::numeric),jsonb_build_object('forma','Saldo pendente','valor',(result->>'saldo')::numeric)));
  IF p_dados->>'canal'='navegador' THEN RETURN result; END IF;
  IF p_dados->>'canal' IS DISTINCT FROM 'impressora' THEN RAISE EXCEPTION 'Escolha como imprimir a comanda.'; END IF;
  IF cfg.impressora_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.impressoras WHERE empresa_id=e AND id=cfg.impressora_id AND ativa) THEN RAISE EXCEPTION 'Selecione uma impressora ativa nas configurações da Rotisseria.'; END IF;
  IF jsonb_array_length(arr)>200 THEN RAISE EXCEPTION 'Para mais de 200 linhas, use Imprimir pelo navegador.'; END IF;
  IF nullif(p_dados->>'chave','') IS NULL THEN RAISE EXCEPTION 'Chave de impressão obrigatória.'; END IF;
  pid:=private.impressao_job_criar(e,'caixa','recibo','rotisseria:comanda:'||s.id||':'||(p_dados->>'chave')::uuid,CASE WHEN s.origem='cardapio' THEN 'Pedido ' ELSE 'Comanda ' END||s.numero||' — Conferência de produtos',result,u);
  RETURN jsonb_build_object('job_id',pid);
 ELSIF p_acao='imprimir' THEN
  IF NOT dispositivo OR NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Imprima no dispositivo de caixa.' USING errcode='42501'; END IF;
  IF cfg.impressora_id IS NULL THEN RAISE EXCEPTION 'Selecione a impressora nas configurações da Rotisseria.'; END IF;
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND venda_id=(p_dados->>'venda_id')::uuid AND estado='concluida';
  IF s.id IS NULL OR nullif(p_dados->>'chave','') IS NULL THEN RAISE EXCEPTION 'Venda ou chave de impressão inválida.'; END IF;
  SELECT jsonb_agg(x.value ORDER BY i.criado_em,i.id,x.ord) INTO arr FROM private.rotisseria_itens i CROSS JOIN LATERAL private.rotisseria_item_impressao(i) WITH ORDINALITY x(value,ord) WHERE i.empresa_id=e AND i.sessao_id=s.id AND NOT i.cancelado;
  IF jsonb_array_length(arr)>200 THEN RAISE EXCEPTION 'Esta composição gera mais de 200 linhas. Use Imprimir comanda pelo navegador.';END IF;
  SELECT private.impressao_job_criar(e,'caixa','recibo','rotisseria:recibo:'||s.venda_id||':'||(p_dados->>'chave')::uuid,'Rotisseria — '||CASE WHEN s.origem='cardapio' THEN 'Pedido ' ELSE 'Comanda ' END||s.numero,
   jsonb_build_object('versao',1,'tipo','recibo','rotisseria_impressora_propria',true,'empresa',(SELECT nome FROM public.empresas WHERE id=e),'setor','ROTISSERIA','venda',(SELECT numero_venda FROM public.vendas WHERE empresa_id=e AND id=s.venda_id),'data_hora',to_char(s.finalizado_em AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),'itens',arr,'total',(SELECT total FROM public.vendas WHERE empresa_id=e AND id=s.venda_id),'pagamentos',(SELECT jsonb_agg(jsonb_build_object('forma',forma_pagamento,'valor',valor) ORDER BY ordem) FROM public.vendas_pagamentos WHERE empresa_id=e AND venda_id=s.venda_id)),u) INTO pid;
  RETURN jsonb_build_object('job_id',pid);
 ELSIF p_acao='historico' THEN
  IF NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Sem permissão para consultar vendas.' USING errcode='42501'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.criado_em DESC),'[]') FROM (SELECT v.*,s.numero comanda,s.origem,s.solicitante,s.id sessao_id,c.nome cliente_nome FROM public.vendas v JOIN private.rotisseria_sessoes s ON s.empresa_id=v.empresa_id AND s.venda_id=v.id LEFT JOIN public.clientes c ON c.empresa_id=v.empresa_id AND c.id=v.cliente_id WHERE v.empresa_id=e AND v.tipo='rotisseria' AND (nullif(p_dados->>'de','') IS NULL OR v.criado_em>=(p_dados->>'de')::date::timestamp AT TIME ZONE 'America/Sao_Paulo') AND (nullif(p_dados->>'ate','') IS NULL OR v.criado_em<((p_dados->>'ate')::date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo') ORDER BY v.criado_em DESC LIMIT 100 OFFSET greatest(0,coalesce((p_dados->>'pagina')::int,0))*100) x);
 ELSIF p_acao='caixa_dados' THEN
  IF NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Sem permissão para consultar caixa.' USING errcode='42501'; END IF;
  SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' AND status='aberto';
  RETURN jsonb_build_object('caixa',CASE WHEN c.id IS NOT NULL THEN private.caixa_json(c) ELSE NULL END,'resumo',CASE WHEN c.id IS NOT NULL THEN private.rotisseria_caixa_resumo(c) ELSE NULL END,
  'historico',CASE WHEN coalesce((p_dados->>'historico')::boolean,false) THEN (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.aberto_em DESC),'[]') FROM (SELECT * FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' ORDER BY aberto_em DESC LIMIT 30) x) ELSE '[]'::jsonb END);
 ELSE RAISE EXCEPTION 'Ação da Rotisseria inválida.'; END IF;
 INSERT INTO public.rotisseria_sinais(empresa_id) VALUES(e) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.rotisseria_sinais.revisao+1;
 RETURN coalesce(result,'{}');
END $function$;
CREATE OR REPLACE FUNCTION private.rotisseria_cardapio_admin(p_acao text, p_dados jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE e uuid:=private.exigir_empresa_ativa();cfg private.rotisseria_cardapio_config;pid uuid:=(p_dados->>'produto_id')::uuid;result jsonb;
BEGIN
 IF NOT private.empresa_tem_modulo('rotisseria') OR NOT private.perm('rotisseria_configurar') THEN RAISE EXCEPTION 'Sem permissão para configurar o cardápio.' USING errcode='42501';END IF;
 INSERT INTO private.rotisseria_cardapio_config(empresa_id) VALUES(e) ON CONFLICT DO NOTHING;
 SELECT * INTO cfg FROM private.rotisseria_cardapio_config WHERE empresa_id=e FOR UPDATE;
 IF p_acao='cardapio_salvar' THEN
  UPDATE private.rotisseria_cardapio_config SET ativo=(p_dados->>'ativo')::boolean WHERE empresa_id=e;
 ELSIF p_acao='cardapio_produto' THEN
  IF NOT EXISTS(SELECT 1 FROM public.produtos WHERE empresa_id=e AND id=pid AND ativo AND tipo_fiscal='produto') THEN RAISE EXCEPTION 'Produto indisponível nesta empresa.';END IF;
  IF coalesce((p_dados->>'disponivel')::boolean,false) THEN
   UPDATE private.rotisseria_cardapio_config SET produtos=ARRAY(SELECT DISTINCT x FROM unnest(produtos||pid) x) WHERE empresa_id=e;
  ELSE UPDATE private.rotisseria_cardapio_config SET produtos=array_remove(produtos,pid) WHERE empresa_id=e;END IF;
 ELSIF p_acao<>'cardapio_dados' THEN RAISE EXCEPTION 'Ação inválida.';END IF;
 SELECT * INTO cfg FROM private.rotisseria_cardapio_config WHERE empresa_id=e;
 result:=jsonb_build_object('ativo',cfg.ativo,'token',cfg.token,'total_disponiveis',cardinality(cfg.produtos),'produtos',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.nome,x.id),'[]') FROM (SELECT p.id,p.nome,p.unidade_comercial,coalesce(f.foto,(SELECT z->>'foto' FROM private.rotisseria_config rc CROSS JOIN LATERAL jsonb_array_elements(rc.produtos) z WHERE rc.empresa_id=e AND z->>'id'=p.id::text LIMIT 1),'') foto,p.id=ANY(cfg.produtos) disponivel,cl.categoria_id FROM public.produtos p LEFT JOIN private.rotisseria_fotos f ON f.empresa_id=e AND f.produto_id=p.id LEFT JOIN private.rotisseria_cardapio_classificacao cl ON cl.empresa_id=e AND cl.produto_id=p.id WHERE p.empresa_id=e AND p.ativo AND p.tipo_fiscal='produto' AND p.nome ILIKE '%'||left(coalesce(p_dados->>'busca',''),100)||'%' ORDER BY p.nome,p.id LIMIT 21 OFFSET greatest(0,coalesce((p_dados->>'pagina')::int,0))*20) x));
 RETURN result||private.rotisseria_cardapio_extras(e,true);
END $function$;
CREATE OR REPLACE FUNCTION private.rotisseria_cardapio_publico(p_acao text, p_token text, p_dados jsonb DEFAULT '{}'::jsonb, p_chave uuid DEFAULT NULL::uuid, p_ip text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
DECLARE cfg private.rotisseria_cardapio_config;e uuid;s private.rotisseria_sessoes;env private.rotisseria_cardapio_envios;p public.produtos;c private.rotisseria_catalogo;
 x jsonb;result jsonb;snapshot jsonb;rows jsonb:='[]';q numeric;total numeric:=0;num int;line_no int:=0;lim int;segredo text;nome text:=btrim(coalesce(p_dados->>'nome',''));fone text:=regexp_replace(coalesce(p_dados->>'telefone',''),'[^0-9]','','g');
BEGIN
 IF p_acao NOT IN ('catalogo','confirmar','acompanhar') OR p_acao IS NULL OR p_token !~ '^[a-f0-9]{64}$' OR p_ip !~ '^[a-f0-9]{64}$' OR octet_length(p_dados::text)>55000 THEN RAISE EXCEPTION 'Solicitação inválida.';END IF;
 SELECT cc.* INTO cfg FROM private.rotisseria_cardapio_config cc JOIN public.empresas ee ON ee.id=cc.empresa_id AND ee.status_conta='aprovado' AND NOT ee.bloqueado WHERE cc.token=p_token AND cc.ativo AND EXISTS(SELECT 1 FROM public.empresa_modulos em WHERE em.empresa_id=cc.empresa_id AND em.modulo='rotisseria' AND em.ativo);
 IF cfg.empresa_id IS NULL THEN RAISE EXCEPTION 'Cardápio indisponível.';END IF;e:=cfg.empresa_id;
 IF p_acao='confirmar' THEN
  IF p_chave IS NULL THEN RAISE EXCEPTION 'Chave de envio obrigatória.';END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':rotisseria-envio:'||p_chave::text,0));
  SELECT * INTO env FROM private.rotisseria_cardapio_envios WHERE empresa_id=e AND chave=p_chave;
  IF env.chave IS NOT NULL THEN
   IF env.solicitacao IS DISTINCT FROM p_dados THEN RAISE EXCEPTION 'Este envio já existe com outros dados. Repita o conteúdo original.';END IF;
   RETURN env.resultado||jsonb_build_object('repetido',true);
  END IF;
 END IF;
 DELETE FROM private.rotisseria_cardapio_limites WHERE empresa_id=e AND bucket<clock_timestamp()-interval '1 day';
 INSERT INTO private.rotisseria_cardapio_limites(empresa_id,ip,bucket,acao,contador) VALUES(e,p_ip,date_trunc('minute',clock_timestamp()),p_acao,1) ON CONFLICT(empresa_id,bucket,ip,acao) DO UPDATE SET contador=rotisseria_cardapio_limites.contador+1 RETURNING contador INTO lim;
 IF lim>(CASE WHEN p_acao='confirmar' THEN 6 ELSE 120 END) THEN RAISE EXCEPTION 'Muitas solicitações. Aguarde um minuto.';END IF;
 IF p_acao='catalogo' THEN
  RETURN jsonb_build_object('nome',(SELECT ee.nome FROM public.empresas ee WHERE ee.id=e),'produtos',(SELECT coalesce(jsonb_agg(x.produto ORDER BY x.nome,x.id),'[]') FROM (SELECT p.id,p.nome,private.rotisseria_cardapio_produto(e,p.id)||jsonb_build_object('categoria',cl.categoria_id) produto FROM public.produtos p LEFT JOIN private.rotisseria_catalogo c ON c.empresa_id=e AND c.produto_id=p.id LEFT JOIN private.rotisseria_cardapio_classificacao cl ON cl.empresa_id=e AND cl.produto_id=p.id WHERE p.empresa_id=e AND p.id=ANY(cfg.produtos) AND p.ativo AND (c.id IS NULL OR c.ativo) AND (nullif(p_dados->>'categoria','') IS NULL OR cl.categoria_id IN (SELECT ct.id FROM private.rotisseria_cardapio_categorias ct WHERE ct.empresa_id=e AND (ct.id=(p_dados->>'categoria')::uuid OR ct.pai=(p_dados->>'categoria')::uuid))) AND p.nome ILIKE '%'||left(coalesce(p_dados->>'busca',''),100)||'%' ORDER BY p.nome,p.id LIMIT 13 OFFSET greatest(0,coalesce((p_dados->>'pagina')::int,0))*12) x))||private.rotisseria_cardapio_extras(e,false);
 ELSIF p_acao='acompanhar' THEN
  SELECT * INTO env FROM private.rotisseria_cardapio_envios WHERE empresa_id=e AND chave=p_chave AND resultado->>'segredo'=p_dados->>'segredo';
  IF env.chave IS NULL OR length(coalesce(p_dados->>'segredo',''))<>64 THEN RAISE EXCEPTION 'Pedido não encontrado.';END IF;
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=env.sessao_id;
  RETURN jsonb_build_object('numero',s.numero,'estado',s.estado,'total',(private.rotisseria_saldo(s.id,e)->>'total')::numeric,'saldo',(private.rotisseria_saldo(s.id,e)->>'saldo')::numeric);
 END IF;
 IF length(nome) NOT BETWEEN 2 AND 100 OR length(fone) NOT BETWEEN 10 AND 13 OR length(coalesce(p_dados->>'observacao',''))>500 OR jsonb_typeof(p_dados->'itens') IS DISTINCT FROM 'array' OR jsonb_array_length(p_dados->'itens') NOT BETWEEN 1 AND 30 THEN RAISE EXCEPTION 'Informe nome, telefone e de 1 a 30 itens.';END IF;
 -- Validate all quantities, prices and recipes before allocating the sequential order.
 FOR x IN SELECT value FROM jsonb_array_elements(p_dados->'itens') LOOP
  line_no:=line_no+1;q:=(x->>'quantidade')::numeric;
  SELECT * INTO p FROM public.produtos WHERE empresa_id=e AND id=(x->>'produto_id')::uuid AND id=ANY(cfg.produtos) AND ativo AND tipo_fiscal='produto' FOR SHARE;
  IF p.id IS NULL OR q IS NULL OR q<=0 OR q>100 OR q<>round(q,4) OR (x->>'preco')::numeric IS DISTINCT FROM p.preco_venda THEN RAISE EXCEPTION 'Produto, quantidade ou preço mudou. Revise o cardápio antes de enviar.';END IF;
  IF NOT(p.venda_granel OR upper(p.unidade_comercial) IN ('KG','K','QUILO')) AND q<>trunc(q) THEN RAISE EXCEPTION 'Informe uma quantidade inteira para %.',p.nome;END IF;
  SELECT * INTO c FROM private.rotisseria_catalogo WHERE empresa_id=e AND produto_id=p.id;
  snapshot:=NULL;
  IF c.id IS NOT NULL THEN
   IF c.tipo='combo' AND q<>1 THEN RAISE EXCEPTION 'Inclua cada combo separadamente.';END IF;
   snapshot:=private.rotisseria_resolver_catalogo(e,p.id,(x->>'catalogo_versao')::int,coalesce(x->'escolhas','[]'),coalesce(x->'acompanhamentos','[]'));
  ELSE
   IF coalesce(x->'escolhas','[]')<>'[]'::jsonb OR coalesce(x->'acompanhamentos','[]')<>'[]'::jsonb THEN RAISE EXCEPTION 'Escolhas inválidas para este produto.';END IF;
  END IF;
  rows:=rows||jsonb_build_array(jsonb_build_object('produto_id',p.id,'nome',p.nome,'unidade',p.unidade_comercial,'quantidade',q,'preco',p.preco_venda,'composicao',snapshot));
  total:=total+round(q*p.preco_venda,2);
 END LOOP;
 IF (p_dados->>'total')::numeric IS DISTINCT FROM total OR total<=0 THEN RAISE EXCEPTION 'O total mudou. Revise seu pedido.';END IF;
 UPDATE private.rotisseria_cardapio_config SET ultimo_pedido=ultimo_pedido+1 WHERE empresa_id=e RETURNING ultimo_pedido INTO num;
 INSERT INTO private.rotisseria_sessoes(empresa_id,numero,origem,solicitante) VALUES(e,num,'cardapio',jsonb_build_object('nome',nome,'telefone',fone,'observacao',coalesce(p_dados->>'observacao',''))) RETURNING * INTO s;
 line_no:=0;
 FOR x IN SELECT value FROM jsonb_array_elements(rows) LOOP
  line_no:=line_no+1;
  INSERT INTO private.rotisseria_itens(empresa_id,sessao_id,produto_id,nome,unidade,quantidade,preco,chave,origem_publica,composicao)
  VALUES(e,s.id,(x->>'produto_id')::uuid,x->>'nome',coalesce(x->>'unidade','UN'),(x->>'quantidade')::numeric,(x->>'preco')::numeric,md5(p_chave::text||':'||line_no::text)::uuid,true,nullif(x->'composicao','null'::jsonb));
 END LOOP;
 segredo:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');result:=jsonb_build_object('numero',num,'segredo',segredo,'total',total,'estado','aberta');
 INSERT INTO private.rotisseria_cardapio_envios(empresa_id,chave,sessao_id,solicitacao,resultado) VALUES(e,p_chave,s.id,p_dados,result);
 INSERT INTO public.rotisseria_sinais(empresa_id) VALUES(e) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.rotisseria_sinais.revisao+1;
 RETURN result;
END $function$;
COMMIT;
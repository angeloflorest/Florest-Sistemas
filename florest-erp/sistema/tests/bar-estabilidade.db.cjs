// Comparação de estoque/itens no PostgreSQL isolado; nenhuma escrita em produção.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {PGlite}=require(process.env.PGLITE_PATH||'/tmp/erp-perf-pg/node_modules/@electric-sql/pglite');
const dir=path.join(__dirname,'fixtures/bar-estabilidade'),read=n=>fs.readFileSync(path.join(dir,n),'utf8');
const migration=fs.readFileSync(path.join(__dirname,'../../../supabase/migrations/20261122205034_bar_estabilidade_pedidos.sql'),'utf8');
const id=n=>'00000000-0000-0000-0000-'+String(n).padStart(12,'0'),E=id(1),M=id(2),C=id(3),K=id(4);
async function setup(updated){const db=new PGlite();await db.exec(`
 CREATE SCHEMA auth;CREATE SCHEMA private;CREATE ROLE anon;CREATE ROLE authenticated;
 CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$SELECT '${id(9)}'::uuid$$;
 CREATE FUNCTION private.exigir_empresa_ativa() RETURNS uuid LANGUAGE sql AS $$SELECT '${E}'::uuid$$;
 CREATE FUNCTION private.empresa_tem_modulo(text) RETURNS boolean LANGUAGE sql AS $$SELECT true$$;
 CREATE FUNCTION private.perm(text) RETURNS boolean LANGUAGE sql AS $$SELECT current_setting('test.allowed',true) IS DISTINCT FROM 'no'$$;
 CREATE FUNCTION private.bar_reabertura_guardar(uuid,uuid) RETURNS void LANGUAGE sql AS $$SELECT$$;
 CREATE FUNCTION private.bar_reabertura_sincronizar(uuid,uuid) RETURNS void LANGUAGE sql AS $$SELECT$$;
 CREATE FUNCTION private.produtos_exigir_ativos(uuid,uuid[]) RETURNS void LANGUAGE sql AS $$SELECT$$;
 CREATE FUNCTION private.produto_exigir_ativo(uuid,uuid) RETURNS void LANGUAGE sql AS $$SELECT$$;
 CREATE TABLE private.bar_reaberturas(empresa_id uuid,comanda_id uuid,ativa boolean);
 `);
 for(const x of [...JSON.parse(read('schema.json')),...JSON.parse(read('extra-schema.json'))])await db.exec(`CREATE TABLE public.${x.relname}(${x.cols})`);
 await db.exec(`ALTER TABLE empresas ADD PRIMARY KEY(id);ALTER TABLE bar_pedidos ADD UNIQUE(empresa_id,idempotencia_key);
 CREATE FUNCTION private.bar_mesa_abrir_interna(m uuid,p integer) RETURNS uuid LANGUAGE plpgsql AS $$DECLARE c uuid:=gen_random_uuid();BEGIN INSERT INTO bar_comandas(id,empresa_id,mesa_id,status)VALUES(c,'${E}',m,'aberta');UPDATE bar_mesas SET status='ocupada',comanda_atual_id=c WHERE id=m;RETURN c;END$$;
 INSERT INTO empresas(id)VALUES('${E}');INSERT INTO bar_mesas(id,empresa_id,numero,status,comanda_atual_id)VALUES('${M}','${E}',1,'ocupada','${C}');INSERT INTO bar_comandas(id,empresa_id,mesa_id,status)VALUES('${C}','${E}','${M}','aberta');
 INSERT INTO configuracoes_empresa(empresa_id,permitir_venda_sem_estoque)VALUES('${E}',false);
 `);
 for(const n of ['enviar','lancar','pagar','pagar-valor','estornar'])await db.exec(read(n+'-antes.sql'));
 if(updated)await db.exec(migration);
 for(let n=10;n<15;n++)await db.query("INSERT INTO produtos(id,empresa_id,nome,preco_venda,quantidade_estoque,ativo)VALUES($1,$2,$3,$4,100,true)",[id(n),E,'Produto '+n,n+0.99]);
 for(let n=10;n<15;n++)await db.query("INSERT INTO bar_produtos(id,empresa_id,produto_id,tipo,destino_operacional,ativo_cardapio)VALUES($1,$2,$3,$4,'bar',true)",[id(n+100),E,id(n),[11,12].includes(n)?'composto':'simples']);
 await db.exec(`INSERT INTO bar_produtos_componentes(empresa_id,bar_produto_id,componente_produto_id,quantidade,baixar_estoque)VALUES('${E}','${id(111)}','${id(10)}',2,true);
 INSERT INTO bar_produto_grupos(id,empresa_id,bar_produto_id,nome,quantidade_escolhas)VALUES('${id(20)}','${E}','${id(112)}','Escolha',2);
 INSERT INTO bar_produto_grupo_opcoes(empresa_id,grupo_id,produto_id)VALUES('${E}','${id(20)}','${id(13)}'),('${E}','${id(20)}','${id(14)}');`);
 return db;
}
async function snapshot(db){const data={};for(const t of ['produtos','bar_pedidos_itens','bar_pedidos_itens_baixas','bar_pedidos_itens_escolhas']){
 const rows=(await db.query(`SELECT to_jsonb(t) d FROM ${t} t`)).rows.map(x=>x.d);for(const row of rows)for(const k of ['id','pedido_id','pedido_item_id'])if(t!=='produtos'||k!=='id')delete row[k];data[t]=rows.sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b)));}return data;}
async function main(){const old=await setup(false),now=await setup(true);
 const items=[{bar_produto_id:id(110),quantidade:2.12345,observacao:'  gelado  '},{bar_produto_id:id(111),quantidade:3},{bar_produto_id:id(112),quantidade:2,escolhas:[{grupo_id:id(20),produto_id:id(13)},{grupo_id:id(20),produto_id:id(14)}]},{bar_produto_id:id(112),quantidade:1,escolhas:[{grupo_id:id(20),produto_id:id(13)},{grupo_id:id(20),produto_id:id(13)}]}];
 for(const db of [old,now])await db.query('SELECT * FROM bar_pedido_lancar($1,$2,$3)',[M,JSON.stringify(items),K]);
 assert.deepEqual(await snapshot(now),await snapshot(old),'Itens, preços, observação, escolhas e baixa devem ser idênticos');
 const before=await snapshot(now),original=(await now.query('SELECT * FROM bar_pedidos')).rows[0];
 for(let i=0;i<3;i++)assert.equal((await now.query('SELECT * FROM bar_pedido_lancar($1,$2,$3)',[M,JSON.stringify(items),K])).rows[0].pedido_id,original.id);
 assert.deepEqual(await snapshot(now),before,'Reenvio não pode baixar estoque');
 await now.query("UPDATE bar_mesas SET status='livre',comanda_atual_id=NULL WHERE id=$1",[M]);
 assert.equal((await now.query('SELECT * FROM bar_pedido_lancar($1,$2,$3)',[M,JSON.stringify(items),K])).rows[0].comanda_id,C);
 assert.equal((await now.query('SELECT status FROM bar_mesas WHERE id=$1',[M])).rows[0].status,'livre');
 await assert.rejects(now.query('SELECT * FROM bar_pedido_lancar($1,$2,$3)',[M,JSON.stringify(items.slice(0,1)),K]),/outro conteúdo/);
 await assert.rejects(now.query('SELECT * FROM bar_pedido_lancar($1,$2,$3)',[M,JSON.stringify([{...items[0],_comanda_esperada:C}]),id(30)]),/mesa mudou/i);
 const saved=await snapshot(now);
 for(const bad of [[{bar_produto_id:id(110),quantidade:1000}],[{bar_produto_id:id(112),quantidade:1,escolhas:[{grupo_id:id(20),produto_id:id(13)}]}],[{bar_produto_id:id(900),quantidade:1}],[]]){
 await assert.rejects(now.query('SELECT * FROM bar_pedido_lancar($1,$2,$3)',[M,JSON.stringify(bad),id(31)]));assert.deepEqual(await snapshot(now),saved,'Falha deve reverter tudo');assert.equal((await now.query('SELECT status FROM bar_mesas WHERE id=$1',[M])).rows[0].status,'livre');}
 await now.exec("SET test.allowed='no'");await assert.rejects(now.query('SELECT * FROM bar_pedido_lancar($1,$2,$3)',[M,JSON.stringify(items),K]),/permissão/);
 // Segurança do armazenamento: nenhum cliente recebe acesso à tabela privada.
 assert.equal((await now.query("SELECT has_table_privilege('authenticated','private.bar_envios','SELECT') p")).rows[0].p,false);
 assert.equal((await now.query("SELECT relrowsecurity FROM pg_class WHERE oid='private.bar_envios'::regclass")).rows[0].relrowsecurity,true);
 await old.close();await now.close();console.log('OK PostgreSQL: resultados idênticos ao original; repetição; mesa reutilizada; payload alterado; estoque insuficiente; escolhas inválidas; rollback; permissão e RLS.');
}main().catch(e=>{console.error(e);process.exitCode=1});

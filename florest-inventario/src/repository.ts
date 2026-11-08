import type {Count,Inventory,Profile,Product} from './domain';
export const schema=`
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS inventarios(id TEXT PRIMARY KEY,empresa_id TEXT NOT NULL,operador_id TEXT NOT NULL,operador_nome TEXT NOT NULL,empresa_nome TEXT NOT NULL,numero INTEGER NOT NULL,aberto_em TEXT NOT NULL,fechado_em TEXT,status TEXT NOT NULL CHECK(status IN ('aberto','fechado')),UNIQUE(empresa_id,numero));
CREATE UNIQUE INDEX IF NOT EXISTS inventario_aberto ON inventarios(empresa_id,operador_id) WHERE status='aberto';
CREATE TABLE IF NOT EXISTS contagens(id TEXT PRIMARY KEY,inventario_id TEXT NOT NULL REFERENCES inventarios(id),empresa_id TEXT NOT NULL,operador_id TEXT NOT NULL,produto TEXT NOT NULL,quantidade REAL NOT NULL CHECK(quantidade>=0),criado_em TEXT NOT NULL,confirmado_em TEXT,status TEXT NOT NULL,mensagem TEXT NOT NULL DEFAULT '',observado TEXT);
CREATE INDEX IF NOT EXISTS contagens_inventario ON contagens(inventario_id,criado_em,id);
CREATE UNIQUE INDEX IF NOT EXISTS contagem_pendente ON contagens(empresa_id,operador_id) WHERE status IN ('pendente','conferir');
`;
export interface DB {execAsync(sql:string):Promise<void>;runAsync(sql:string,...params:any[]):Promise<unknown>;getFirstAsync<T>(sql:string,...params:any[]):Promise<T|null>;getAllAsync<T>(sql:string,...params:any[]):Promise<T[]>;}
function decode(row:any):Count{return {...row,produto:JSON.parse(row.produto),observado:row.observado?JSON.parse(row.observado):undefined};}
export class Repository {
 constructor(private db:DB,readonly profile:Profile){}
 async init(){await this.db.execAsync(schema);}
 async list():Promise<Inventory[]>{return this.db.getAllAsync<Inventory>('SELECT * FROM inventarios WHERE empresa_id=? AND operador_id=? ORDER BY numero DESC',this.profile.empresa_id,this.profile.id);}
 async open(id:string):Promise<Inventory>{
  await this.db.runAsync(`INSERT INTO inventarios(id,empresa_id,operador_id,operador_nome,empresa_nome,numero,aberto_em,status) SELECT ?,?,?,?,?,COALESCE(MAX(numero),0)+1,?,'aberto' FROM inventarios WHERE empresa_id=?`,id,this.profile.empresa_id,this.profile.id,this.profile.nome,this.profile.empresas.nome,new Date().toISOString(),this.profile.empresa_id);
  return (await this.list()).find(v=>v.id===id)!;
 }
 async rows(id:string):Promise<Count[]>{
  return (await this.db.getAllAsync<any>('SELECT * FROM contagens WHERE inventario_id=? AND empresa_id=? AND operador_id=? ORDER BY criado_em,id',id,this.profile.empresa_id,this.profile.id)).map(decode);
 }
 async pending():Promise<Count|null>{const row=await this.db.getFirstAsync<any>("SELECT * FROM contagens WHERE empresa_id=? AND operador_id=? AND status IN ('pendente','conferir') LIMIT 1",this.profile.empresa_id,this.profile.id);return row?decode(row):null;}
 async prepare(id:string,inv:Inventory,snapshot:Product,amount:number):Promise<Count>{
  if(inv.empresa_id!==this.profile.empresa_id||inv.operador_id!==this.profile.id||snapshot.empresa_id!==this.profile.empresa_id)throw Error('Empresa ou operador incompatível.');
  const row:Count={id,inventario_id:inv.id,empresa_id:this.profile.empresa_id,operador_id:this.profile.id,produto:snapshot,quantidade:amount,criado_em:new Date().toISOString(),confirmado_em:null,status:'pendente',mensagem:''};
  await this.db.runAsync(`INSERT INTO contagens(id,inventario_id,empresa_id,operador_id,produto,quantidade,criado_em,status) SELECT ?,?,?,?,?,?,?,'pendente' FROM inventarios WHERE id=? AND empresa_id=? AND operador_id=? AND status='aberto'`,id,inv.id,row.empresa_id,row.operador_id,JSON.stringify(snapshot),amount,row.criado_em,inv.id,row.empresa_id,row.operador_id);
  const saved=await this.db.getFirstAsync<{id:string}>('SELECT id FROM contagens WHERE id=?',id);if(!saved)throw Error('O inventário não está aberto.');return row;
 }
 async result(row:Count,status:Count['status'],message:string,observed?:Product){
  await this.db.runAsync('UPDATE contagens SET status=?,mensagem=?,observado=?,confirmado_em=? WHERE id=? AND empresa_id=? AND operador_id=?',status,message,observed?JSON.stringify(observed):null,status==='confirmado'?new Date().toISOString():null,row.id,this.profile.empresa_id,this.profile.id);
 }
 async close(inv:Inventory){
  if(await this.pending())throw Error('Resolva a contagem pendente antes de finalizar.');
  await this.db.runAsync("UPDATE inventarios SET status='fechado',fechado_em=? WHERE id=? AND empresa_id=? AND operador_id=? AND status='aberto'",new Date().toISOString(),inv.id,this.profile.empresa_id,this.profile.id);
 }
}

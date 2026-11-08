import type {Count,Inventory,Product} from './domain';
export interface Journal {prepare(id:string,inv:Inventory,p:Product,n:number):Promise<Count>;result(row:Count,status:Count['status'],message:string,observed?:Product):Promise<void>;pending():Promise<Count|null>;}
export class Counting {
 private busy=false;
 constructor(private journal:Journal,private update:(p:Product,n:number)=>Promise<Product>){}
 async confirm(id:string,inv:Inventory,p:Product,n:number){
  if(this.busy)throw Error('Aguarde a contagem em andamento.');this.busy=true;
  try{if(await this.journal.pending())throw Error('Resolva a contagem pendente antes de continuar.');const row=await this.journal.prepare(id,inv,p,n);return await this.send(row);}finally{this.busy=false;}
 }
 async retry(row:Count){if(this.busy)throw Error('Aguarde a operação atual.');this.busy=true;try{const pending=await this.journal.pending();if(!pending||pending.id!==row.id)throw Error('Esta tentativa já foi resolvida.');return await this.send(pending);}finally{this.busy=false;}}
 private async send(row:Count){
  try{
   const updated=await this.update(row.produto,row.quantidade);
   // Persist the acknowledged stock before allowing another count.
   await this.journal.result(row,'confirmado','Estoque confirmado pelo ERP.',updated);
   return updated;
  }catch(e){await this.journal.result(row,'conferir',(e as Error)?.message||'Sem confirmação. Confira antes de continuar.').catch(()=>{});throw e;}
 }
}

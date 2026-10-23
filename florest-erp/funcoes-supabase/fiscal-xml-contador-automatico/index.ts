import { createClient } from "npm:@supabase/supabase-js@2";
import JSZip from "npm:jszip@3.10.1";
const cors={"Content-Type":"application/json"};
const respond=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:cors});
async function safeEqual(a:string,b:string){if(a.length!==b.length)return false;const x=new TextEncoder().encode(a),y=new TextEncoder().encode(b);return crypto.subtle.timingSafeEqual?crypto.subtle.timingSafeEqual(x,y):x.reduce((v,z,i)=>v|(z^y[i]),0)===0;}
Deno.serve(async req=>{
 if(req.method!=="POST")return respond({erro:"Metodo nao permitido"},405);
 const expected=Deno.env.get("FISCAL_CTG_CRON_SECRET")??"";
 const supplied=req.headers.get("x-florest-cron-secret")??"";
 if(expected.length<24||!await safeEqual(supplied,expected))return respond({erro:"Nao autorizado"},401);
 const now=new Date(); const month=now.getUTCMonth();const year=now.getUTCFullYear();
 const competencia=new Date(Date.UTC(year,month-1,1)).toISOString().slice(0,7);
 const inicio=competencia+"-01",fim=new Date(Date.UTC(year,month,1)).toISOString().slice(0,10);
 const admin=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
 const key=Deno.env.get("RESEND_API_KEY");if(!key)return respond({erro:"RESEND_API_KEY ausente"},503);
 const {data:contadores,error:ce}=await admin.from("fiscal_contadores").select("empresa_id,email").eq("envio_automatico",true);
 if(ce)return respond({erro:"Falha ao buscar contadores"},500);
 let enviados=0,ignorados=0,falhas=0;
 for(const c of contadores??[]){
  try{
   if(typeof c.email!=="string"||!/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(c.email)){falhas++;continue;}
   const {data:previous,error:prevErr}=await admin.from("fiscal_pacotes_xml").select("id").eq("empresa_id",c.empresa_id).eq("competencia",inicio).eq("status","enviado").eq("destinatario",c.email).limit(1);
   if(prevErr){falhas++;continue;}if(previous?.length){ignorados++;continue;}
   const {data:docs,error:e1}=await admin.from("documentos_fiscais").select("id,numero,chave_acesso,status,c_stat,xml_conteudo").eq("empresa_id",c.empresa_id).gte("created_at",inicio).lt("created_at",fim).limit(1001);
   const {data:ins,error:e2}=await admin.from("notas_entrada").select("id,numero,chave_acesso,xml_conteudo").eq("empresa_id",c.empresa_id).gte("data_emissao",inicio).lt("data_emissao",fim).limit(1001);
   if(e1||e2||(docs?.length??0)>1000||(ins?.length??0)>1000){falhas++;continue;}
   const zip=new JSZip();const pendentes:unknown[]=[];let quantidade=0,bytesTotal=0;
   function add(folder:string,d:any){const xml=d.xml_conteudo;
     if(typeof xml!=="string"||!xml.trim().startsWith("<")||!xml.includes("infNFe")){pendentes.push({tipo:folder,id:d.id,numero:d.numero,motivo:"xml_ausente"});return;}
     bytesTotal+=xml.length;if(bytesTotal>25_000_000)throw Error("zip_grande");
     zip.file(folder+"/"+String(d.chave_acesso??d.numero??d.id).replace(/[^0-9a-zA-Z_-]/g,"").slice(0,60)+"_"+d.id+".xml",xml);quantidade++;
   }
   for(const d of docs??[])if(["100","150"].includes(d.c_stat)||["autorizada","autorizado","cancelada"].includes(d.status))add("emitidas",d);
   for(const d of ins??[])add("entradas",d);
   const manifesto={competencia,geradoEm:new Date().toISOString(),quantidade,pendentes,observacao:"Pacote automatico: contem apenas XMLs presentes no ERP; XMLs ausentes e documentos externos exigem conferencia."};
   zip.file("manifesto.json",JSON.stringify(manifesto,null,2));
   const bytes=await zip.generateAsync({type:"uint8array",compression:"DEFLATE",compressionOptions:{level:6}});
   if(bytes.length>20_000_000){falhas++;continue;}
   let bin="";for(const b of bytes)bin+=String.fromCharCode(b);
   const response=await fetch("https://api.resend.com/emails",{method:"POST",headers:{"Authorization":"Bearer "+key,"Content-Type":"application/json","Idempotency-Key":"florest-xml-"+c.empresa_id+"-"+competencia},body:JSON.stringify({
    from:"Florest ERP <fiscal@florestsistemas.com.br>",to:[c.email],subject:"XMLs fiscais - "+competencia+" - Florest ERP",
    text:"Envio automatico mensal. XMLs incluidos: "+quantidade+". Documentos com XML ausente: "+pendentes.length+". Consulte o manifesto.json dentro do ZIP. Se nao houver XMLs, o ZIP contem somente o manifesto.",
    attachments:[{filename:"xml-contador-"+competencia+".zip",content:btoa(bin)}]
   })});
   const data=await response.json().catch(()=>({}));
   if(!response.ok||!data.id){falhas++;continue;}
   const {error:he}=await admin.from("fiscal_pacotes_xml").insert({empresa_id:c.empresa_id,competencia:inicio,status:"enviado",qtd_xml:quantidade,qtd_pendentes:pendentes.length,destinatario:c.email,enviado_em:new Date().toISOString(),manifesto:{...manifesto,resend_id:data.id,automatico:true}});
   if(he){falhas++;continue;}enviados++;
  }catch{falhas++;}
 }
 return respond({competencia,enviados,ignorados,falhas});
});
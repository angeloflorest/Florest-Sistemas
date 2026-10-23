import { createClient } from "npm:@supabase/supabase-js@2";
import JSZip from "npm:jszip@3.10.1";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization,apikey,content-type", "Access-Control-Allow-Methods": "POST,OPTIONS" };
const json = (body: unknown, status=200) => new Response(JSON.stringify(body), {status, headers:{...cors,"Content-Type":"application/json"}});
Deno.serve(async req => {
 if(req.method==="OPTIONS") return new Response(null,{status:204,headers:cors});
 if(req.method!=="POST") return json({erro:"Metodo nao permitido"},405);
 const auth=req.headers.get("Authorization");
 if(!auth?.startsWith("Bearer ")) return json({erro:"Nao autenticado"},401);
 const client=createClient(url,anon,{global:{headers:{Authorization:auth}}});
 const {data:{user},error:ue}=await client.auth.getUser();
 if(ue||!user) return json({erro:"Sessao invalida"},401);
 const {data:perfil,error:pe}=await client.from("perfis").select("empresa_id,papel,permissoes,ativo").eq("id",user.id).single();
 if(pe||!perfil?.ativo||!(perfil.papel==="proprietario"||(Array.isArray(perfil.permissoes)&&perfil.permissoes.includes("fiscal"))))return json({erro:"Sem permissao fiscal"},403);
 const body=await req.json().catch(()=>null);
 const competencia=body?.competencia;
 if(typeof competencia!=="string"||!/^[0-9]{4}-(0[1-9]|1[0-2])$/.test(competencia))return json({erro:"Competencia deve ser AAAA-MM"},400);
 const inicio=competencia+"-01";
 const [ano,mes]=competencia.split("-").map(Number);
 const fim=new Date(Date.UTC(ano,mes,1)).toISOString().slice(0,10);
 const admin=createClient(url,service);
 const empresa=perfil.empresa_id;
 const {data:emitidas,error:e1}=await admin.from("documentos_fiscais").select("id,tipo_documento,status,numero,serie,chave_acesso,protocolo,c_stat,xml_conteudo,dh_emissao,created_at").eq("empresa_id",empresa).gte("created_at",inicio).lt("created_at",fim).limit(1001);
 const {data:entradas,error:e2}=await admin.from("notas_entrada").select("id,numero,serie,chave_acesso,xml_conteudo,data_emissao,data_entrada").eq("empresa_id",empresa).gte("data_emissao",inicio).lt("data_emissao",fim).limit(1001);
 if(e1||e2)return json({erro:"Falha ao consultar documentos"},500);
 if((emitidas?.length??0)>1000||(entradas?.length??0)>1000)return json({erro:"Volume acima de 1000 documentos; solicite exportacao por lote"},413);
 const zip=new JSZip();const pendentes:unknown[]=[];let quantidade=0;let totalBytes=0;
 const nomes=new Set<string>();
 function adicionar(pasta:string,numero:unknown,chave:unknown,xml:unknown,id:string){
   if(typeof xml!=="string"||!xml.trim().startsWith("<")||!xml.includes("infNFe"))return false;
   totalBytes+=xml.length;
   if(totalBytes>25_000_000)throw Error("limite_tamanho");
   const nomeBase=String(chave??numero??id).replace(/[^0-9A-Za-z_-]/g,"").slice(0,60)||id;
   let nome=pasta+"/"+nomeBase+".xml";if(nomes.has(nome))nome=pasta+"/"+nomeBase+"_"+id+".xml";nomes.add(nome);
   zip.file(nome,xml);quantidade++;return true;
 }
 try{
   for(const d of emitidas??[]){
     const autorizado=d.c_stat==="100"||d.c_stat==="150"||d.status==="autorizada"||d.status==="autorizado";
     if(!autorizado){continue;}
     if(!adicionar("emitidas",d.numero,d.chave_acesso,d.xml_conteudo,d.id))pendentes.push({tipo:"emitida",id:d.id,numero:d.numero,motivo:"xml_ausente"});
   }
   for(const d of entradas??[]){
     if(!adicionar("entradas",d.numero,d.chave_acesso,d.xml_conteudo,d.id))pendentes.push({tipo:"entrada",id:d.id,numero:d.numero,motivo:"xml_ausente"});
   }
 }catch{return json({erro:"Tamanho maximo de 25MB excedido"},413);}
 const manifesto={competencia,geradoEm:new Date().toISOString(),quantidade,pendentes,observacao:"Inclui somente XMLs presentes no ERP. Conferir cancelamentos e documentos externos antes de entregar ao contador."};
 zip.file("manifesto.json",JSON.stringify(manifesto,null,2));
 const {data:contador}=await admin.from("fiscal_contadores").select("email").eq("empresa_id",empresa).maybeSingle();
 const enviar=body?.acao==="enviar";
 if(enviar){
   
   
   if(typeof contador?.email!=="string"||!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(contador.email))return json({erro:"Cadastre um e-mail valido para o contador"},422);
   if(!Deno.env.get("RESEND_API_KEY"))return json({erro:"RESEND_API_KEY nao configurada"},503);
   const {data:anterior}=await admin.from("fiscal_pacotes_xml").select("id").eq("empresa_id",empresa).eq("competencia",inicio).eq("status","enviado").eq("destinatario",contador.email).limit(1);
   if(anterior?.length && body?.confirmarReenvio!==true)return json({erro:"Este mes ja foi enviado para este contador. Confirme o reenvio.",reenvio:true},409);
   const bytes=await zip.generateAsync({type:"uint8array",compression:"DEFLATE",compressionOptions:{level:6}});
   if(bytes.byteLength>20_000_000)return json({erro:"Anexo excede limite de 20MB"},413);
   let bin="";for(const b of bytes)bin+=String.fromCharCode(b);
   const base64=btoa(bin);
   const resposta=await fetch("https://api.resend.com/emails",{method:"POST",headers:{"Authorization":"Bearer "+Deno.env.get("RESEND_API_KEY"),"Content-Type":"application/json"},body:JSON.stringify({
     from:"Florest ERP <fiscal@florestsistemas.com.br>",
     to:[contador.email],
     subject:"XMLs fiscais - "+competencia+" - Florest ERP",
     text:"Segue o pacote de XMLs fiscais da competencia "+competencia+". XMLs incluidos: "+quantidade+". Documentos com XML ausente: "+pendentes.length+". Se nao houver XMLs, o ZIP contem somente o manifesto.json. Verifique o manifesto para identificar arquivos ausentes e documentos nao incluidos.",
     attachments:[{filename:"xml-contador-"+competencia+".zip",content:base64}]
   })});
   const retorno=await resposta.json().catch(()=>({}));
   if(!resposta.ok||!retorno?.id)return json({erro:"Falha no envio pelo Resend",codigo:resposta.status},502);
   const {error:historicoErro}=await admin.from("fiscal_pacotes_xml").insert({empresa_id:empresa,competencia:inicio,status:"enviado",qtd_xml:quantidade,qtd_pendentes:pendentes.length,destinatario:contador.email,enviado_em:new Date().toISOString(),manifesto:{...manifesto,resend_id:retorno.id}});
   return json({sucesso:true,resend_id:retorno.id,quantidade,destinatario:contador.email,historico_registrado:!historicoErro,pendentes:pendentes.length});
 }
 await admin.from("fiscal_pacotes_xml").insert({empresa_id:empresa,competencia:inicio,status:pendentes.length?"pendente_xml":"preparado",qtd_xml:quantidade,qtd_pendentes:pendentes.length,destinatario:contador?.email??null,manifesto});
 if(body?.acao==="resumo")return json(manifesto);
 const bytes=await zip.generateAsync({type:"uint8array",compression:"DEFLATE",compressionOptions:{level:6}});
 return new Response(bytes,{status:200,headers:{...cors,"Content-Type":"application/zip","Content-Disposition":'attachment; filename="xml-contador-'+competencia+'.zip"',"Cache-Control":"no-store"}});
});
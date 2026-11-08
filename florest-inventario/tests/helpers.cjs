const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript');
function load(name,mocks={}){
 const file=path.join(__dirname,'..','src',name+'.ts');const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;const exports={};
 vm.runInNewContext(js,{exports,require:k=>Object.hasOwn(mocks,k)?mocks[k]:k.startsWith('./')?load(k.slice(2),mocks):require(k),console,URL,AbortController,setTimeout,clearTimeout,atob,fetch:global.fetch,process:{env:mocks.$env||{}}},{filename:file});return exports;
}
const profile={id:'u1',empresa_id:'e1',nome:'Angelo',papel:'funcionario',permissoes:['estoque'],ativo:true,empresas:{nome:'Florest',status_conta:'aprovado',bloqueado:false}};
const product={id:'p1',empresa_id:'e1',nome:'Coca-Cola 2 litros',codigo:'123',gtin:'7891234567895',unidade_comercial:'UN',quantidade_estoque:12,atualizado_em:'2026-11-08T15:00:00.000Z',ativo:true,tipo_fiscal:'produto'};
const inventory={id:'i1',empresa_id:'e1',operador_id:'u1',operador_nome:'Angelo',empresa_nome:'Florest',numero:1,aberto_em:'2026-11-08T14:00:00.000Z',fechado_em:null,status:'aberto'};
module.exports={load,profile,product,inventory};

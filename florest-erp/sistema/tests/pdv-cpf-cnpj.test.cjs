'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
function setup(){
 const nodes=new Map();const el=id=>{if(!nodes.has(id)){const classes=new Set();nodes.set(id,{value:'',textContent:'',attributes:{},classList:{add:x=>classes.add(x),remove:x=>classes.delete(x),contains:x=>classes.has(x),toggle:(x,on)=>on?classes.add(x):classes.delete(x)},setAttribute(k,v){this.attributes[k]=v}})}return nodes.get(id)};
 const ctx=vm.createContext({$:el,somenteDigitos:v=>String(v??'').replace(/\D/g,'')});
 vm.runInContext(html.slice(html.indexOf('function cpfValido('),html.indexOf('const PDV_COLUNAS')),ctx);
 return {el,ctx,run:s=>vm.runInContext(s,ctx)};
}
for(const value of ['52998224725','529.982.247-25','04252011000110','04.252.011/0001-10','00000000000191','00.000.000/0001-91'])test('aceita documento válido '+value,()=>{const t=setup();t.el('pdv-cpf-nota').value=value;assert.equal(t.run('pdxValidarCpfNota()'),true);assert.equal(t.el('pdx-cpf-nota-erro').textContent,'');assert.equal(t.el('pdv-cpf-nota').attributes['aria-invalid'],'false')});
for(const value of ['52998224724','04252011000111','11111111111','11111111111111','00000000000000','123','ABC52998224725','ABC','0425201100011'])test('recusa documento inválido '+value,()=>{const t=setup();t.el('pdv-cpf-nota').value=value;assert.equal(t.run('pdxValidarCpfNota()'),false);assert.match(t.el('pdx-cpf-nota-erro').textContent,/CPF ou CNPJ inválido/);assert.equal(t.el('pdv-cpf-nota').classList.contains('pdx-cpf-nota-invalida'),true)});
test('documento continua opcional e limpar remove o erro',()=>{const t=setup();t.el('pdv-cpf-nota').value='123';t.run('pdxValidarCpfNota()');t.el('pdv-cpf-nota').value='';assert.equal(t.run('pdxValidarCpfNota()'),true);assert.equal(t.el('pdv-cpf-nota').classList.contains('pdx-cpf-nota-invalida'),false)});
test('CNPJ mantém zeros à esquerda e normaliza só pontuação',()=>{const t=setup();t.ctx.valor='00.000.000/0001-91';assert.equal(t.run('normalizarDocumentoNota(valor)'),'00000000000191');t.ctx.valor='ABC52998224725';assert.equal(t.run('normalizarDocumentoNota(valor)'),'ABC52998224725')});
test('campo aceita CNPJ formatado e informa ambos os documentos',()=>{assert.match(html,/<label for="pdv-cpf-nota">CPF\/CNPJ na nota:<\/label>/);assert.match(html,/<input[^>]+id="pdv-cpf-nota"[^>]+maxlength="18"/)});
test('venda à vista e a prazo mantêm o documento normalizado no contrato existente',()=>{const source=html.slice(html.indexOf("$('btn-finalizar-venda').addEventListener('click', async () =>"),html.indexOf('// ---------- PDV em tela cheia:'));assert.match(source,/const cpfNota = normalizarDocumentoNota/);assert.equal((source.match(/p_cpf_nota: cpfNota/g)||[]).length,2)});
test('seleção de cliente aceita CNPJ e pesquisa por documento',()=>{const source=html.slice(html.indexOf('function pdxRenderClientes(){'),html.indexOf('function pdxRenderClientes(){')+2400);assert.match(source,/documentoNotaValido\(cpfDoCliente\)/);assert.match(source,/pdvClientesCpf.get\(o.value\).*includes\(documentoBusca\)/)});

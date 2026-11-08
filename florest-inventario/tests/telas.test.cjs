const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript');const React=require('react'),Renderer=require('react-test-renderer');const {DatabaseSync}=require('node:sqlite');const {load,profile,product}=require('./helpers.cjs');
global.IS_REACT_ACT_ENVIRONMENT=true;
const {act}=Renderer;
const tick=()=>new Promise(r=>setImmediate(r));
function setup(){
 const sql=new DatabaseSync(':memory:');const db={execAsync:async s=>sql.exec(s),runAsync:async(s,...p)=>sql.prepare(s).run(...p),getFirstAsync:async(s,...p)=>sql.prepare(s).get(...p)||null,getAllAsync:async(s,...p)=>sql.prepare(s).all(...p)};
 const alerts=[];let writes=0,uuid=0;
 const c={auth:{getUser:async()=>({data:{user:{id:profile.id}},error:null}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),startAutoRefresh(){},stopAutoRefresh(){}}};
 const rn=Object.fromEntries(['ActivityIndicator','Image','SafeAreaView','Text','TouchableOpacity','View'].map(k=>[k,k]));rn.Modal=({visible,children,...props})=>visible?React.createElement('Modal',props,children):null;rn.Alert={alert:(...a)=>alerts.push(a)};rn.AppState={addEventListener:()=>({remove(){}})};rn.StyleSheet={create:x=>x};
 const mocks={react:React,'react/jsx-runtime':require('react/jsx-runtime'),'react-native-url-polyfill/auto':{},'react-native':rn,'expo-status-bar':{StatusBar:'StatusBar'},'expo-camera':{CameraView:'CameraView',useCameraPermissions:()=>[{granted:true},async()=>({granted:true})]},'expo-crypto':{randomUUID:()=>`uuid-${++uuid}`},'expo-sqlite':{openDatabaseAsync:async()=>db},'expo-file-system/legacy':{},'expo-sharing':{},'./src/KeyboardForm':{KeyboardInput:'TextInput',KeyboardScroll:'ScrollView'},'./src/domain':load('domain'),'./src/repository':load('repository'),'./src/counting':load('counting'),'./assets/logo-florest.png':1,'./src/api':{client:c,loadProfile:async()=>profile,readableError:e=>e.message,searchProducts:async()=>[product],readProduct:async()=>product,updateStock:async(p,q,pr,amount)=>{writes++;return {...pr,quantidade_estoque:amount};}}};
 const file=path.join(__dirname,'../App.tsx'),exports={};const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true}}).outputText;
 vm.runInNewContext(js,{exports,require:k=>{if(k in mocks)return mocks[k];throw Error('Módulo não previsto: '+k);},console,setTimeout,clearTimeout},{filename:file});
 return {App:exports.default,alerts,db,get writes(){return writes;}};
}
async function settle(){for(let n=0;n<4;n++)await tick();}
async function press(root,label){const btn=root.findAllByType('TouchableOpacity').find(n=>n.findAllByType('Text').some(t=>t.children.join('')===label));assert.ok(btn,'Botão ausente: '+label);assert.ok(!btn.props.disabled,'Botão desabilitado: '+label);await act(async()=>{await btn.props.onPress();await settle();});}
test('telas abrem inventário, confirmam uma contagem e fecham sem reaplicar estoque',async()=>{
 const ctx=setup();let screen;await act(async()=>{screen=Renderer.create(React.createElement(ctx.App));await settle();});
 await press(screen.root,'Abrir inventário');
 await act(async()=>{screen.root.findByProps({accessibilityLabel:'Pesquisar produto'}).props.onChangeText('Coca');});
 await press(screen.root,'Buscar produto');await press(screen.root,'Coca-Cola 2 litros');
 await act(async()=>{screen.root.findByProps({accessibilityLabel:'Quantidade contada'}).props.onChangeText('50');});
 await press(screen.root,'Confirmar e atualizar estoque');assert.equal(ctx.writes,0,'Não deve gravar antes da confirmação explícita');
 const confirmation=ctx.alerts.at(-1);assert.equal(confirmation[0],'Atualizar estoque agora?');
 await act(async()=>{confirmation[2].find(b=>b.text==='Confirmar contagem').onPress();await settle();});assert.equal(ctx.writes,1);
 await press(screen.root,'Finalizar inventário');await act(async()=>{ctx.alerts.at(-1)[2].find(b=>b.text==='Finalizar').onPress();await settle();});assert.equal(ctx.writes,1);
 const saved=await ctx.db.getFirstAsync('SELECT * FROM inventarios');assert.equal(saved.status,'fechado');const row=await ctx.db.getFirstAsync('SELECT * FROM contagens');assert.equal(row.quantidade,50);assert.equal(row.status,'confirmado');
 await act(async()=>screen.unmount());
});

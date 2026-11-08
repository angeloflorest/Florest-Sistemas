'use strict';
const fs=require('fs'),path=require('path'),cp=require('child_process');
for(const dir of ['src','scripts','tests'])for(const name of fs.readdirSync(dir,{recursive:true})){const f=path.join(dir,name);if(fs.statSync(f).isFile()&&(f.endsWith('.cjs')||f.endsWith('erp-bar.js')||f.endsWith('desktop-adapter.js'))){const r=cp.spawnSync(process.execPath,['--check',f],{stdio:'inherit'});if(r.status)process.exit(r.status);}}
console.log('Sintaxe validada');

"use strict";
const fs=require("node:fs"),path=require("node:path");
const K=require("../src/renderer/keyboard.js");
const html=`<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Manual de atalhos - Florest PDV</title><style>
:root{font-family:Arial,Helvetica,sans-serif;color:#0b2a4d;background:#edf2f7}
*{box-sizing:border-box}body{margin:0 auto;padding:30px 24px;max-width:900px}
main{background:white;padding:32px 38px;border:1px solid #dce4ed;border-radius:12px}
header{border-bottom:4px solid #f8c820;padding-bottom:15px;margin-bottom:24px}
header small{color:#526478;text-transform:uppercase;letter-spacing:1px}
h1{font-size:27px;margin:7px 0}p,li{font-size:14px;line-height:1.5}li{margin-bottom:6px}
table{width:100%;border-collapse:collapse;margin:20px 0;font-size:14px}
th{background:#0b2a4d;color:#f8c820;text-align:left}
td,th{padding:9px 12px;border-bottom:1px solid #e2e8f0}
td:first-child{width:28%}tbody tr:nth-child(even){background:#f4f7fa}
.note{color:#526478;font-size:12px;margin-top:22px}
button{background:#f8c820;border:0;padding:11px 18px;border-radius:6px;color:#0b2a4d;font-weight:bold;cursor:pointer;margin-bottom:18px}
@media print{@page{size:A4;margin:14mm}body{padding:0;background:white;max-width:none}main{border:0;padding:0}button{display:none}p,li,table{font-size:11px}li{margin-bottom:3px}td,th{padding:6px 9px}header{margin-bottom:12px}h1{font-size:23px}table{margin:12px 0}tr{break-inside:avoid}.note{font-size:10px}}
</style></head><body><button onclick="window.print()">Imprimir / salvar em PDF</button><main><header><small>Florest Sistemas</small><h1>Manual de atalhos - Florest PDV</h1><p>Consulta rápida para vender pelo teclado</p></header>${K.manualBody()}<p class="note">F10 fica livre. F11 e F12 não foram alterados. O manual também está disponível dentro do aplicativo pelo F1.</p></main></body></html>`;
const dir=path.resolve(__dirname,"../dist");fs.mkdirSync(dir,{recursive:true});
fs.writeFileSync(path.join(dir,"Manual-Florest-PDV.html"),html);
console.log("Manual gerado a partir dos mesmos atalhos do PDV.");

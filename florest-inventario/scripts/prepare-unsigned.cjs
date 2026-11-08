const fs=require('node:fs');
const file='android/app/build.gradle';
const text=fs.readFileSync(file,'utf8');
const release=/(release\s*\{[\s\S]*?)signingConfig signingConfigs\.debug/;
if(!release.test(text))throw Error('Formato Gradle diferente do esperado; não foi removida a assinatura de teste.');
fs.writeFileSync(file,text.replace(release,'$1// Assinatura de distribuição aplicada fora do CI, com a chave privada do proprietário.'));

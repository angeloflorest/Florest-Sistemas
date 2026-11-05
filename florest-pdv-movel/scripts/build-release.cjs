const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
process.chdir(root);
function fail(message) { throw Error(message); }
function run(program, args, capture = false, env = process.env) {
  // cmd.exe is necessary for npm/Gradle .cmd/.bat on Windows; only fixed commands
  // go through it. External paths and keystore passwords are passed via env.
  const batch = process.platform === 'win32' && /\.(cmd|bat)$/i.test(program);
  if (batch && [program, ...args].some(value => /["%\r\n!&|<>^]/.test(value))) fail('Comando contém caracteres não permitidos pelo CMD.');
  const command = batch ? 'cmd.exe' : program;
  const commandArgs = batch ? ['/d', '/s', '/c', `""${program}" ${args.map(arg => `"${arg}"`).join(' ')}"`] : args;
  const result = spawnSync(command, commandArgs, { cwd: root, env, encoding: 'utf8', stdio: capture ? 'pipe' : 'inherit', windowsVerbatimArguments: batch, windowsHide: true });
  if (result.error || result.status !== 0) fail(`Falha em ${path.basename(program)} (código ${result.status ?? 'indisponível'}). ${result.error?.message || ''}`);
  return (result.stdout || '') + (result.stderr || '');
}
function loadEnv() {
  // Never execute .env as shell code. Existing process variables take priority.
  for (const name of ['.env.local', '.env']) {
    const file = path.join(root, name);
    if (!fs.existsSync(file)) continue;
    for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
      const match = line.match(/^\s*(EXPO_PUBLIC_[A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
      if (!match || process.env[match[1]] !== undefined) continue;
      let value = match[2];
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
      process.env[match[1]] = value;
    }
  }
}
function certificate(output) {
  const match = output.match(/Signer #1 certificate SHA-256 digest:\s*([a-f0-9]+)/i);
  if (!match) fail('Não foi possível identificar o certificado do APK.');
  return match[1].toLowerCase();
}
function packageInfo(output) {
  const match = output.match(/package: name='([^']+)' versionCode='(\d+)'/);
  if (!match) fail('Não foi possível identificar pacote e versão do APK.');
  return { name: match[1], versionCode: Number(match[2]) };
}
function main() {
  if (process.platform !== 'win32') fail('Este gerador automatizado deve ser executado no Windows configurado pelo proprietário.');
  loadEnv();
  const javaHome = process.env.JAVA_HOME;
  const java = run(javaHome ? path.join(javaHome, 'bin', 'java.exe') : 'java', ['-version'], true);
  if (!/version "17[.\"]/.test(java)) fail('Ative o JDK 17 (JAVA_HOME e PATH) antes de gerar o APK.');
  if (Number(process.versions.node.split('.')[0]) < 20 || (Number(process.versions.node.split('.')[0]) === 20 && Number(process.versions.node.split('.')[1]) < 19)) fail('Use Node.js 20.19 ou superior.');
  run('npm.cmd', ['--version']);
  const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT;
  if (!sdk || !fs.existsSync(sdk)) fail('Configure ANDROID_HOME com a pasta do Android SDK.');
  process.env.ANDROID_HOME = sdk; process.env.ANDROID_SDK_ROOT = sdk;
  const buildToolsDir = path.join(sdk, 'build-tools');
  const versions = fs.existsSync(buildToolsDir) ? fs.readdirSync(buildToolsDir).filter(v => /^\d+\.\d+\.\d+$/.test(v)).sort((a,b) => a.localeCompare(b, undefined, { numeric: true })).reverse() : [];
  const tools = versions.map(v => path.join(buildToolsDir, v)).find(p => fs.existsSync(path.join(p, 'apksigner.bat')) && fs.existsSync(path.join(p, 'aapt.exe')));
  if (!tools) fail('Instale Android SDK Build-Tools (apksigner e aapt) pelo Android Studio.');
  const url = process.env.EXPO_PUBLIC_SUPABASE_URL || '', key = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY || '';
  if (!/^https:\/\/[^\s/]+\.supabase\.co\/?$/.test(url) || /SEU-|COLE_AQUI/i.test(url)) fail('Preencha EXPO_PUBLIC_SUPABASE_URL em .env.local.');
  let publicKey = key.startsWith('sb_publishable_') && key.length > 25;
  if (!publicKey) { try { publicKey = JSON.parse(Buffer.from(key.split('.')[1], 'base64url')).role === 'anon'; } catch {} }
  if (!publicKey) fail('Informe somente a chave pública publishable/anon. Chaves service_role e secret são proibidas.');
  const manifest = process.env.EXPO_PUBLIC_UPDATE_MANIFEST_URL;
  if (manifest && (!/^https:\/\//.test(manifest) || /SEU-|example\./i.test(manifest))) fail('Informe um manifesto HTTPS real ou deixe EXPO_PUBLIC_UPDATE_MANIFEST_URL vazio.');
  for (const name of ['FLOREST_KEYSTORE_PATH','FLOREST_KEYSTORE_PASSWORD','FLOREST_KEY_ALIAS','FLOREST_KEY_PASSWORD','FLOREST_EXISTING_APK']) {
    if (!process.env[name]) fail(`Configure ${name} no ambiente do Windows. Nunca coloque senhas em arquivos versionados.`);
  }
  const keystore = path.resolve(process.env.FLOREST_KEYSTORE_PATH), previous = path.resolve(process.env.FLOREST_EXISTING_APK);
  if (!fs.existsSync(keystore) || !fs.existsSync(previous)) fail('Keystore ou APK anteriormente instalado não encontrado.');
  if (keystore.startsWith(root + path.sep)) fail('Guarde o keystore fora da pasta do aplicativo e do Git.');
  process.env.FLOREST_KEYSTORE_PATH = keystore;
  // Paths are env-expanded inside fixed cmd commands, enclosed in quotes.
  // Reject cmd metacharacters rather than interpolating user-controlled commands.
  for (const p of [tools, previous, root]) if (/["%\r\n!&|<>^]/.test(p)) fail('Use caminhos sem caracteres especiais de CMD para o projeto, SDK e APK anterior.');
  const signer = path.join(tools, 'apksigner.bat'), aapt = path.join(tools, 'aapt.exe');
  const expected = certificate(run(signer, ['verify', '--print-certs', previous], true));
  const old = packageInfo(run(aapt, ['dump', 'badging', previous], true));
  const config = JSON.parse(fs.readFileSync('app.json')).expo;
  if (old.name !== config.android.package) fail('O APK anterior não pertence ao pacote Florest PDV Móvel.');
  if (Number(config.android.versionCode) <= old.versionCode) fail(`Aumente android.versionCode em app.json para um valor maior que ${old.versionCode}. O pacote deve permanecer igual.`);
  console.log('Instalando dependências conforme package-lock.json…');
  run('npm.cmd', ['ci', '--no-audit', '--no-fund']);
  run('npm.cmd', ['run', 'check']); run('npm.cmd', ['test']);
  process.env.CI = '1';
  run('npx.cmd', ['--no-install', 'expo', 'install', '--check']);
  run('npx.cmd', ['--no-install', 'expo', 'prebuild', '--platform', 'android', '--no-install']);
  const gradle = path.join(root, 'android', 'app', 'build.gradle');
  const signing = require('../plugins/with-release-signing.cjs');
  fs.writeFileSync(gradle, signing.configureRelease(fs.readFileSync(gradle, 'utf8')));
  const output = path.join(root, 'android', 'app', 'build', 'outputs', 'apk', 'release', 'app-release.apk');
  // Remove only the intermediate APK to ensure an old artifact cannot be delivered.
  // The last verified APK-GERADO is preserved until the new build passes every check.
  if (fs.existsSync(output)) fs.unlinkSync(output);
  run(path.join(root, 'android', 'gradlew.bat'), ['-p', 'android', ':app:assembleRelease', '--no-daemon', '--max-workers=2']);
  if (!fs.existsSync(output)) fail('Gradle não produziu app-release.apk.');
  if (certificate(run(signer, ['verify', '--print-certs', output], true)) !== expected) fail('Assinatura incompatível com o APK anterior. Nenhum instalador foi entregue. Use o keystore original.');
  const built = packageInfo(run(aapt, ['dump', 'badging', output], true));
  if (built.name !== old.name || built.versionCode !== Number(config.android.versionCode)) fail('Identificador ou versão incorretos no APK.');
  const listing = run(javaHome ? path.join(javaHome, 'bin', 'jar.exe') : 'jar', ['tf', output], true);
  if (!/^assets\/index.android.bundle\r?$/m.test(listing)) fail('APK sem bundle JavaScript incorporado. Não instale.');
  const manifestText = run(aapt, ['dump', 'permissions', output], true);
  if (!manifestText.includes('android.permission.CAMERA')) fail('APK sem permissão de câmera.');
  const out = path.join(root, 'APK-GERADO'); fs.mkdirSync(out, { recursive: true });
  const target = path.join(out, 'Florest-PDV-Movel.apk');
  const staging = target + '.novo'; fs.copyFileSync(output, staging);
  if (fs.existsSync(target)) fs.copyFileSync(target, path.join(out, `Florest-PDV-Movel-anterior-${Date.now()}.apk`));
  fs.renameSync(staging, target);
  console.log(`\nAPK RELEASE verificado: ${target}\nAssinatura compatível com o APK anterior; JavaScript incorporado. Nenhuma publicação foi executada.`);
}
if (require.main === module) { try { main(); } catch (e) { console.error('\nERRO: ' + e.message + '\nO APK anterior em APK-GERADO foi preservado.'); process.exitCode = 1; } }
module.exports = { certificate, packageInfo, loadEnv };

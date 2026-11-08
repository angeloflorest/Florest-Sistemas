function buildSettings(root, totalMemory, platform = process.platform) {
  if (platform === 'win32' && root.length > 60) {
    throw Error('Caminho longo demais para CMake/Ninja. Copie o projeto para C:\\pdv, sem node_modules nem android, e execute novamente. Preserve a pasta original, .env.local, keystore e APK anterior.');
  }
  const lowMemory = totalMemory <= 6 * 1024 ** 3;
  return {
    lowMemory,
    gradleArgs: ['-p', 'android', ':app:assembleRelease', '--no-daemon', `--max-workers=${lowMemory ? 1 : 2}`,
      ...(lowMemory ? ['-Dorg.gradle.parallel=false', '-Dorg.gradle.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=384m', '-Pkotlin.compiler.execution.strategy=in-process'] : [])],
    nodeOptions: lowMemory ? '--max-old-space-size=768' : null,
  };
}
function packageTool(program, args, nodeExecutable, exists, platform = process.platform) {
  if (platform !== 'win32' || !['npm.cmd', 'npx.cmd'].includes(program)) return null;
  const path = require('node:path').win32;
  const cli = path.join(path.dirname(nodeExecutable), 'node_modules', 'npm', 'bin', program === 'npm.cmd' ? 'npm-cli.js' : 'npx-cli.js');
  if (!exists(cli)) throw Error('Não foi encontrado o npm da instalação do Node: ' + cli + '. Confira a instalação do Node; não copie npm para a pasta do projeto.');
  return { command: nodeExecutable, args: [cli, ...args] };
}
module.exports = { buildSettings, packageTool };

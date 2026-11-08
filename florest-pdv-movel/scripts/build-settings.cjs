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
module.exports = { buildSettings };

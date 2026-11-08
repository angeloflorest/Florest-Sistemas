const { test } = require('node:test');
const assert = require('node:assert/strict');
const { buildSettings, packageTool } = require('../scripts/build-settings.cjs');
test('Windows recusa o caminho longo do erro antes de iniciar compilação', () => {
  assert.throws(() => buildSettings('C:\\Users\\angelo\\Desktop\\Florest-Sistemas-main\\Florest-Sistemas-main\\florest-pdv-movel', 4 * 1024 ** 3, 'win32'), /CMake\/Ninja/);
});
test('4 GB limita Gradle e memória; PC maior mantém dois workers', () => {
  const small = buildSettings('C:\\pdv', 4 * 1024 ** 3, 'win32');
  assert.ok(small.gradleArgs.includes('--max-workers=1'));
  assert.ok(small.gradleArgs.includes('-Dorg.gradle.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=384m'));
  assert.equal(small.nodeOptions, '--max-old-space-size=768');
  const large = buildSettings('C:\\pdv', 16 * 1024 ** 3, 'win32');
  assert.ok(large.gradleArgs.includes('--max-workers=2'));
  assert.equal(large.nodeOptions, null);
});
test('npm e npx usam a instalação Node em Program Files, sem depender do diretório atual', () => {
  const node = 'C:\\Program Files\\nodejs\\node.exe';
  for (const [wrapper, cli] of [['npm.cmd', 'npm-cli.js'], ['npx.cmd', 'npx-cli.js']]) {
    const expected = 'C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\' + cli;
    const result = packageTool(wrapper, ['--version'], node, file => file === expected, 'win32');
    assert.deepEqual(result, { command: node, args: [expected, '--version'] });
  }
  assert.throws(() => packageTool('npm.cmd', [], node, () => false, 'win32'), /instalação do Node/);
  assert.equal(packageTool('C:\\pdv030\\android\\gradlew.bat', [], node, () => false, 'win32'), null);
});

const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), ts = require('typescript');
function load(name, mocks = {}) {
  const filename = path.join(__dirname, '..', 'src', name + '.ts');
  const code = ts.transpileModule(fs.readFileSync(filename, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  const context = { exports, require: key => {
    if (Object.hasOwn(mocks, key)) return mocks[key];
    if (key.startsWith('./')) return load(key.slice(2), mocks);
    throw Error('Unexpected module: ' + key);
  }, console, URL, AbortController, setTimeout, clearTimeout, fetch: mocks.$fetch || global.fetch, atob, process: { env: mocks.$env || {} } };
  vm.runInNewContext(code, context, { filename });
  return exports;
}
module.exports = { load };

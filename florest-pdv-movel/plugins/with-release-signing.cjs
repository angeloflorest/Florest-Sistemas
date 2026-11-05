const { withAppBuildGradle } = require('@expo/config-plugins');
function configureRelease(source) {
  if (source.includes('// FLOREST_RELEASE_SIGNING')) {
    if (!/release\s*\{[^}]*signingConfig signingConfigs\.florestRelease/.test(source)) throw Error('A configuração Release existente foi alterada. Confira a assinatura antes de compilar.');
    return source;
  }
  const opening = /signingConfigs\s*\{/;
  const release = /(release\s*\{(?:(?:\s|\/\/[^\n]*\n))*)signingConfig signingConfigs\.debug/;
  if (!opening.test(source) || !release.test(source)) throw Error('Formato Gradle desconhecido. Assinatura Release não foi configurada; compilação interrompida.');
  source = source.replace(opening, `signingConfigs {
        // FLOREST_RELEASE_SIGNING — secrets supplied only through the build process.
        florestRelease {
            def signingPath = System.getenv('FLOREST_KEYSTORE_PATH')
            if (signingPath) {
                storeFile file(signingPath)
                storePassword System.getenv('FLOREST_KEYSTORE_PASSWORD')
                keyAlias System.getenv('FLOREST_KEY_ALIAS')
                keyPassword System.getenv('FLOREST_KEY_PASSWORD')
            }
        }`);
  source = source.replace(release, '$1signingConfig signingConfigs.florestRelease');
  return source;
}
module.exports = config => withAppBuildGradle(config, result => {
  if (result.modResults.language !== 'groovy') throw Error('O projeto exige configuração Gradle Groovy para assinatura.');
  result.modResults.contents = configureRelease(result.modResults.contents);
  return result;
});
module.exports.configureRelease = configureRelease;

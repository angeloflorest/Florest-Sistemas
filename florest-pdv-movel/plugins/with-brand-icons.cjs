const { withAndroidManifest } = require('@expo/config-plugins');
const fs = require('node:fs/promises');
const path = require('node:path');
// Configure Android's drawable inset rather than modifying the official artwork.
// Keeps the entire eagle inside circular/squircle launcher masks.
module.exports = config => withAndroidManifest(config, async result => {
  const directory = path.join(result.modRequest.platformProjectRoot, 'app/src/main/res/mipmap-anydpi-v26');
  const xml = `<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/iconBackground"/>
    <foreground>
        <inset android:drawable="@mipmap/ic_launcher_foreground" android:inset="18%"/>
    </foreground>
</adaptive-icon>`;
  await fs.mkdir(directory, { recursive: true });
  await Promise.all(['ic_launcher.xml', 'ic_launcher_round.xml'].map(name => fs.writeFile(path.join(directory, name), xml)));
  return result;
});

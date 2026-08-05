const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const https = require('https');

async function ensureKubectl() {
  const binDir = path.join(__dirname, '../bin');
  
  // Add binDir to PATH if not already present
  if (!process.env.PATH.includes(binDir)) {
    process.env.PATH = `${binDir}${path.delimiter}${process.env.PATH}`;
  }

  // Check if kubectl is available system-wide or in local bin
  try {
    execSync('kubectl version --client', { stdio: 'ignore' });
    return true;
  } catch (e) {}

  const kubectlName = process.platform === 'win32' ? 'kubectl.exe' : 'kubectl';
  const kubectlPath = path.join(binDir, kubectlName);

  if (fs.existsSync(kubectlPath)) {
    return true;
  }

  console.log('[KubeManage] kubectl CLI not found on server system PATH.');
  console.log('[KubeManage] Auto-downloading standalone kubectl binary for server...');

  if (!fs.existsSync(binDir)) {
    fs.mkdirSync(binDir, { recursive: true });
  }

  const arch = process.arch === 'arm64' ? 'arm64' : 'amd64';
  const platform = process.platform === 'win32' ? 'windows' : (process.platform === 'darwin' ? 'darwin' : 'linux');
  const ext = process.platform === 'win32' ? '.exe' : '';
  const url = `https://dl.k8s.io/release/v1.30.0/bin/${platform}/${arch}/kubectl${ext}`;

  return new Promise((resolve) => {
    function download(downloadUrl) {
      https.get(downloadUrl, (res) => {
        if (res.statusCode === 301 || res.statusCode === 302) {
          return download(res.headers.location);
        }
        if (res.statusCode !== 200) {
          console.error(`[KubeManage] Download failed HTTP Status: ${res.statusCode}`);
          return resolve(false);
        }

        const file = fs.createWriteStream(kubectlPath);
        res.pipe(file);
        file.on('finish', () => {
          file.close();
          if (process.platform !== 'win32') {
            try { fs.chmodSync(kubectlPath, '755'); } catch (err) {}
          }
          console.log('=================================================');
          console.log('  ✓ Standalone kubectl CLI Downloaded Successfully!');
          console.log(`  Path: ${kubectlPath}`);
          console.log('=================================================');
          resolve(true);
        });
      }).on('error', (err) => {
        console.error('[KubeManage] Failed to download kubectl:', err.message);
        resolve(false);
      });
    }

    download(url);
  });
}

module.exports = {
  ensureKubectl
};

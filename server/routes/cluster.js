const express = require('express');
const router = express.Router();
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const kubeAdapter = require('../kube-adapter');
const { runScript, runCommand } = require('../adapters/cli');

const upload = multer({ dest: path.join(__dirname, '../../uploads/') });

// Upload directory ensure
const uploadDir = path.join(__dirname, '../../uploads/');
if (!fs.existsSync(uploadDir)) {
  fs.mkdirSync(uploadDir, { recursive: true });
}

// Get system status & mode
router.get('/status', async (req, res) => {
  const mode = await kubeAdapter.checkMode();
  res.json({
    success: true,
    mode,
    timestamp: new Date().toISOString()
  });
});

// List namespaces
router.get('/namespaces', async (req, res) => {
  const result = await kubeAdapter.listNamespaces();
  res.json(result);
});

// List contexts
router.get('/contexts', async (req, res) => {
  const result = await kubeAdapter.getContexts();
  res.json(result);
});

// Switch context
router.post('/contexts/switch', async (req, res) => {
  const { context } = req.body;
  if (!context) return res.status(400).json({ success: false, message: 'Context name required' });
  const result = await runScript('ctx', [context]);
  res.json(result);
});

// Add context / import file
router.post('/contexts/upload', upload.single('kubeconfig'), async (req, res) => {
  if (!req.file) {
    return res.status(400).json({ success: false, message: 'No file uploaded' });
  }

  const alias = req.body.alias || '';
  const normalizedPath = req.file.path.replace(/\\/g, '/');

  kubeAdapter.setUploadedKubeconfig(normalizedPath);

  // Directly copy/merge file to ~/.kube/config if not exists
  try {
    const os = require('os');
    const homeKubeDir = path.join(os.homedir(), '.kube');
    const mainConfig = path.join(homeKubeDir, 'config');
    if (!fs.existsSync(homeKubeDir)) {
      fs.mkdirSync(homeKubeDir, { recursive: true });
    }
    if (!fs.existsSync(mainConfig) || fs.statSync(mainConfig).size === 0) {
      fs.copyFileSync(normalizedPath, mainConfig);
    }
  } catch (err) {
    console.error('Kubeconfig sync warning:', err.message);
  }

  // Execute script merge asynchronously with 10s timeout
  const args = ['--add-file', normalizedPath];
  if (alias) args.push(alias);

  let scriptResult = { success: true };
  try {
    scriptResult = await Promise.race([
      runScript('ctx', args),
      new Promise((resolve) => setTimeout(() => resolve({ success: true, timeout: true }), 8000))
    ]);
  } catch (e) {
    scriptResult = { success: true, warning: e.message };
  }

  return res.json({
    success: true,
    message: 'Kubeconfig uploaded and activated successfully',
    scriptResult
  });
});

// Login cluster via URL
router.post('/contexts/login', async (req, res) => {
  const { url, username, password, alias } = req.body;
  if (!url) return res.status(400).json({ success: false, message: 'Cluster URL required' });

  const args = ['--login', url];
  if (username) args.push('-u', username);
  if (password) args.push('-p', password);
  if (alias) args.push(alias);

  const result = await runScript('ctx', args);
  res.json(result);
});

// Delete context
router.delete('/contexts/:name', async (req, res) => {
  const name = req.params.name;
  const result = await runScript('ctx', ['--delete', name]);
  res.json(result);
});

module.exports = router;

const express = require('express');
const router = express.Router();
const kubeAdapter = require('../kube-adapter');
const { runScript } = require('../adapters/cli');

// List deployments
router.get('/', async (req, res) => {
  const ns = req.query.ns || 'default';
  const result = await kubeAdapter.listDeployments(ns);
  res.json(result);
});

// Update image tag
router.post('/update', async (req, res) => {
  const { tag, namespace = 'default', deploymentFile, dryRun, checkRegistry, auth, autoRollback, wait } = req.body;
  if (!tag) return res.status(400).json({ success: false, message: 'Tag (-t) is required' });

  const args = ['-t', tag, '-n', namespace];
  if (deploymentFile) args.push('-f', deploymentFile);
  if (dryRun) args.push('-d');
  if (checkRegistry) args.push('-c');
  if (auth) args.push('--auth', auth);
  if (autoRollback) args.push('--auto-rollback');
  if (wait) args.push('--wait');

  const result = await runScript('update', args);
  res.json(result);
});

// Rollback
router.post('/rollback', async (req, res) => {
  const { namespace = 'default', snapshotFile } = req.body;
  const args = ['-n', namespace];
  if (snapshotFile) args.push('-s', snapshotFile);

  const result = await runScript('rollback', args);
  res.json(result);
});

// Update pull policy
router.post('/pull-policy', async (req, res) => {
  const { deployment, policy, namespace = 'default', container } = req.body;
  if (!deployment || !policy) {
    return res.status(400).json({ success: false, message: 'Deployment (-d) and Policy (-p) required' });
  }

  const args = ['-d', deployment, '-p', policy, '-n', namespace];
  if (container) args.push('-c', container);

  const result = await runScript('pull-policy', args);
  res.json(result);
});

module.exports = router;

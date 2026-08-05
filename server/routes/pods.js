const express = require('express');
const router = express.Router();
const kubeAdapter = require('../kube-adapter');
const { runScript } = require('../adapters/cli');

// List pods
router.get('/', async (req, res) => {
  const ns = req.query.ns || 'default';
  const result = await kubeAdapter.listPods(ns);
  res.json(result);
});

// Restart pods by regex pattern
router.post('/restart', async (req, res) => {
  const { pattern, namespace = 'default' } = req.body;
  if (!pattern) {
    return res.status(400).json({ success: false, message: 'Pattern (-p) required' });
  }

  const result = await runScript('restart', ['-p', pattern, '-n', namespace]);
  res.json(result);
});

module.exports = router;

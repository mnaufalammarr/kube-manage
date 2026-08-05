const express = require('express');
const router = express.Router();
const { runScript } = require('../adapters/cli');

router.post('/', async (req, res) => {
  const { namespace = 'default', envPair, configMap, key, value, oldStr, newStr, deployment, restart } = req.body;

  const args = ['-n', namespace];
  if (envPair) args.push('-e', envPair);
  if (configMap) args.push('-cm', configMap);
  if (key) args.push('-k', key);
  if (value) args.push('-v', value);
  if (oldStr && newStr) args.push('--old', oldStr, '--new', newStr);
  if (deployment) args.push('-d', deployment);
  if (restart) args.push('-r');

  const result = await runScript('config', args);
  res.json(result);
});

module.exports = router;

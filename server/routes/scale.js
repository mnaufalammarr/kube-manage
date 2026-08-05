const express = require('express');
const router = express.Router();
const { runScript } = require('../adapters/cli');

router.post('/', async (req, res) => {
  const { namespace = 'default', deployment, replicas, all, file } = req.body;
  
  if (replicas === undefined || replicas === null) {
    return res.status(400).json({ success: false, message: 'Replicas count required' });
  }

  const args = ['-n', namespace, '-r', String(replicas)];
  if (all) {
    args.push('--all');
  } else if (file) {
    args.push('-f', file);
  } else if (deployment) {
    args.push('-d', deployment);
  } else {
    return res.status(400).json({ success: false, message: 'Specify deployment (-d), file (-f), or all (--all)' });
  }

  const result = await runScript('scale', args);
  res.json(result);
});

module.exports = router;

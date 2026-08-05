const express = require('express');
const router = express.Router();
const { runScript } = require('../adapters/cli');

router.post('/', async (req, res) => {
  const { namespace = 'default', deployment, file, all, cpuReq, memReq, cpuLim, memLim, container } = req.body;

  const args = ['-n', namespace];
  if (all) args.push('--all');
  else if (file) args.push('-f', file);
  else if (deployment) args.push('-d', deployment);

  if (cpuReq) args.push('--cpu-req', cpuReq);
  if (memReq) args.push('--mem-req', memReq);
  if (cpuLim) args.push('--cpu-lim', cpuLim);
  if (memLim) args.push('--mem-lim', memLim);
  if (container) args.push('-c', container);

  const result = await runScript('resources', args);
  res.json(result);
});

module.exports = router;

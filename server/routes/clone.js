const express = require('express');
const router = express.Router();
const { runScript } = require('../adapters/cli');

router.post('/', async (req, res) => {
  const { sourceNs, targetNs, pvcRenameMap, pvcFilter, withPvcData, skipPvc, onlyResource } = req.body;

  if (!sourceNs || !targetNs) {
    return res.status(400).json({ success: false, message: 'Source (-s) and Target (-n) namespace required' });
  }

  const args = ['-s', sourceNs, '-n', targetNs];
  if (pvcRenameMap) args.push('-r', pvcRenameMap);
  if (pvcFilter) args.push('-v', pvcFilter);
  if (withPvcData) args.push('-p');
  if (skipPvc) args.push('-x');
  if (onlyResource) args.push('--only', onlyResource);

  const result = await runScript('clone', args);
  res.json(result);
});

module.exports = router;

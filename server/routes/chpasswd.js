const express = require('express');
const router = express.Router();
const { runScript } = require('../adapters/cli');

router.post('/', async (req, res) => {
  const { user, secretName, secretNs, idp } = req.body;

  const args = [];
  if (user) args.push('-u', user);
  if (secretName) args.push('-s', secretName);
  if (secretNs) args.push('--secret-ns', secretNs);
  if (idp) args.push('--idp', idp);

  const result = await runScript('chpasswd', args);
  res.json(result);
});

module.exports = router;

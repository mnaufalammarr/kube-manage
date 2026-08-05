const express = require('express');
const router = express.Router();
const { runScript } = require('../adapters/cli');

router.post('/', async (req, res) => {
  const { user = 'admin-user', namespace = 'default', duration = '8760h', permanent } = req.body;

  const args = ['-u', user, '-n', namespace];
  if (permanent) {
    args.push('--permanent');
  } else if (duration) {
    args.push('--duration', duration);
  }

  const result = await runScript('token', args);
  res.json(result);
});

module.exports = router;

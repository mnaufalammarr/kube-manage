const express = require('express');
const router = express.Router();
const { runScript, getKubectlJson } = require('../adapters/cli');

router.get('/', async (req, res) => {
  const ns = req.query.ns || 'default';
  const result = await getKubectlJson(`get hpa -n ${ns}`);
  if (result.success) {
    const hpas = (result.data.items || []).map(h => ({
      name: h.metadata.name,
      target: h.spec.scaleTargetRef ? `${h.spec.scaleTargetRef.kind}/${h.spec.scaleTargetRef.name}` : '',
      minReplicas: h.spec.minReplicas || 1,
      maxReplicas: h.spec.maxReplicas || 1,
      currentReplicas: h.status.currentReplicas || 0,
      desiredReplicas: h.status.desiredReplicas || 0,
      currentCpuUtilization: h.status.currentCPUUtilizationPercentage || '-'
    }));
    return res.json({ success: true, hpas });
  }
  res.json({ success: false, hpas: [], error: result.error });
});

router.post('/', async (req, res) => {
  const { namespace = 'default', deployment, file, all, min, max, cpuPercent, memPercent, deleteMode } = req.body;

  const args = ['-n', namespace];
  if (all) args.push('--all');
  else if (file) args.push('-f', file);
  else if (deployment) args.push('-d', deployment);

  if (deleteMode) {
    args.push('--delete');
  } else {
    if (min) args.push('--min', String(min));
    if (max) args.push('--max', String(max));
    if (cpuPercent) args.push('--cpu-percent', String(cpuPercent));
    if (memPercent) args.push('--mem-percent', String(memPercent));
  }

  const result = await runScript('hpa', args);
  res.json(result);
});

module.exports = router;

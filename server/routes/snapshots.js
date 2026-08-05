const express = require('express');
const router = express.Router();
const fs = require('fs');
const path = require('path');
const os = require('os');
const { runScript } = require('../adapters/cli');

const SNAPSHOT_DIR = path.join(os.homedir(), '.kube-update-snapshots');

router.get('/', (req, res) => {
  if (!fs.existsSync(SNAPSHOT_DIR)) {
    return res.json({ success: true, snapshots: [] });
  }

  try {
    const files = fs.readdirSync(SNAPSHOT_DIR)
      .filter(f => f.startsWith('snapshot_') && f.endsWith('.env'))
      .map(f => {
        const filePath = path.join(SNAPSHOT_DIR, f);
        const content = fs.readFileSync(filePath, 'utf8');
        const lines = content.split('\n');
        
        let namespace = '';
        let timestamp = '';
        let newTag = '';

        lines.forEach(l => {
          if (l.startsWith('NAMESPACE=')) namespace = l.split('=')[1].trim();
          if (l.startsWith('TIMESTAMP=')) timestamp = l.split('=')[1].trim();
          if (l.startsWith('NEW_TAG=')) newTag = l.split('=')[1].trim();
        });

        const stats = fs.statSync(filePath);

        return {
          filename: f,
          path: filePath,
          namespace: namespace || 'default',
          timestamp: timestamp || stats.mtime.toISOString(),
          newTag: newTag || '-'
        };
      })
      .sort((a, b) => b.timestamp.localeCompare(a.timestamp));

    res.json({ success: true, snapshots: files });
  } catch (e) {
    res.json({ success: false, snapshots: [], error: e.message });
  }
});

module.exports = router;

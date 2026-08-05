require('dotenv').config();
const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const path = require('path');
const cors = require('cors');
const { verifyToken } = require('./auth');
const { ensureKubectl } = require('./ensure-kubectl');

const authRoutes = require('./routes/auth');
const clusterRoutes = require('./routes/cluster');
const deploymentsRoutes = require('./routes/deployments');
const podsRoutes = require('./routes/pods');
const scaleRoutes = require('./routes/scale');
const resourcesRoutes = require('./routes/resources');
const hpaRoutes = require('./routes/hpa');
const configRoutes = require('./routes/config');
const snapshotsRoutes = require('./routes/snapshots');
const cloneRoutes = require('./routes/clone');
const tokenRoutes = require('./routes/token');
const chpasswdRoutes = require('./routes/chpasswd');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// Custom cookie parser middleware
app.use((req, res, next) => {
  req.cookies = {};
  const cookieHeader = req.headers.cookie;
  if (cookieHeader) {
    cookieHeader.split(';').forEach(cookie => {
      const parts = cookie.split('=');
      req.cookies[parts[0].trim()] = (parts[1] || '').trim();
    });
  }
  next();
});

app.disable('etag');

app.use(cors({
  origin: true,
  credentials: true
}));

app.use('/api', (req, res, next) => {
  res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Expires', '0');
  next();
});

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Serve static frontend files
app.use(express.static(path.join(__dirname, '../public')));

// WebSocket connection handling
wss.on('connection', (ws) => {
  ws.send(JSON.stringify({ type: 'sys', data: 'Connected to KubeManage WebSocket Log Stream' }));
  ws.on('message', (message) => {
    // Handling incoming commands if needed
  });
});

// Broadcast helper
app.set('wss', wss);

// Public Routes
app.use('/api/auth', authRoutes);

// Protected Routes
app.use('/api/cluster', verifyToken, clusterRoutes);
app.use('/api/deployments', verifyToken, deploymentsRoutes);
app.use('/api/pods', verifyToken, podsRoutes);
app.use('/api/scale', verifyToken, scaleRoutes);
app.use('/api/resources', verifyToken, resourcesRoutes);
app.use('/api/hpa', verifyToken, hpaRoutes);
app.use('/api/config', verifyToken, configRoutes);
app.use('/api/snapshots', verifyToken, snapshotsRoutes);
app.use('/api/clone', verifyToken, cloneRoutes);
app.use('/api/token', verifyToken, tokenRoutes);
app.use('/api/chpasswd', verifyToken, chpasswdRoutes);

// Fallback to index.html for SPA routing
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, '../public/index.html'));
});

const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || '0.0.0.0';

ensureKubectl().then(() => {
  server.listen(PORT, HOST, () => {
    console.log(`=================================================`);
    console.log(`  🚀 KubeManage Web UI Dashboard Running!`);
    console.log(`  Local: http://localhost:${PORT}`);
    console.log(`  Network: http://0.0.0.0:${PORT}`);
    console.log(`  Default User: admin / admin123`);
    console.log(`=================================================`);
  });
});

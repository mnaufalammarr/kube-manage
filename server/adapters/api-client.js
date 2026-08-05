const fs = require('fs');
const path = require('path');

// Safe loader for @kubernetes/client-node
let k8s = null;
try {
  k8s = require('@kubernetes/client-node');
} catch (e) {
  console.log('[KubeAdapter] @kubernetes/client-node not installed yet, falling back to CLI adapter');
}

let customKubeconfigPath = null;

function setCustomKubeconfig(filePath) {
  customKubeconfigPath = filePath;
}

function getKubeConfig() {
  if (!k8s) return null;
  const kc = new k8s.KubeConfig();
  if (customKubeconfigPath && fs.existsSync(customKubeconfigPath)) {
    kc.loadFromFile(customKubeconfigPath);
  } else if (process.env.KUBECONFIG_PATH && fs.existsSync(process.env.KUBECONFIG_PATH)) {
    kc.loadFromFile(process.env.KUBECONFIG_PATH);
  } else {
    try {
      kc.loadFromDefault();
    } catch (e) {
      return null;
    }
  }
  return kc;
}

async function listPodsApi(namespace = 'default') {
  const kc = getKubeConfig();
  if (!kc) throw new Error('Kubeconfig unavailable for API mode');
  const k8sApi = kc.makeApiClient(k8s.CoreV1Api);
  const res = await k8sApi.listNamespacedPod(namespace);
  return res.body;
}

async function listDeploymentsApi(namespace = 'default') {
  const kc = getKubeConfig();
  if (!kc) throw new Error('Kubeconfig unavailable for API mode');
  const appsApi = kc.makeApiClient(k8s.AppsV1Api);
  const res = await appsApi.listNamespacedDeployment(namespace);
  return res.body;
}

async function listNamespacesApi() {
  const kc = getKubeConfig();
  if (!kc) throw new Error('Kubeconfig unavailable for API mode');
  const k8sApi = kc.makeApiClient(k8s.CoreV1Api);
  const res = await k8sApi.listNamespace();
  return res.body;
}

module.exports = {
  setCustomKubeconfig,
  getKubeConfig,
  listPodsApi,
  listDeploymentsApi,
  listNamespacesApi
};

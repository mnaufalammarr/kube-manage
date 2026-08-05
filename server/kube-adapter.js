const cliAdapter = require('./adapters/cli');
const apiClientAdapter = require('./adapters/api-client');
const fs = require('fs');
const path = require('path');

let activeKubeconfigUpload = null;

function setUploadedKubeconfig(filePath) {
  activeKubeconfigUpload = filePath;
  apiClientAdapter.setCustomKubeconfig(filePath);
}

async function checkMode() {
  const envMode = process.env.KUBE_MODE || 'auto';
  if (envMode === 'cli') return 'cli';
  if (envMode === 'api') return 'api';

  // Auto detect kubectl/oc CLI availability
  const checkRes = await cliAdapter.runCommand('kubectl version --client || oc version --client');
  if (checkRes.success) {
    return 'cli';
  }
  return 'api';
}

async function listNamespaces() {
  const mode = await checkMode();
  if (mode === 'cli') {
    const res = await cliAdapter.runCommand('kubectl get namespaces -o jsonpath="{.items[*].metadata.name}" || oc get projects -o jsonpath="{.items[*].metadata.name}"');
    if (res.success && res.output) {
      const nsList = res.output.split(/\s+/).filter(Boolean);
      return { success: true, namespaces: nsList };
    }
  }
  
  // Try API client mode
  try {
    const nsBody = await apiClientAdapter.listNamespacesApi();
    const nsList = (nsBody.items || []).map(item => item.metadata.name);
    return { success: true, namespaces: nsList };
  } catch (e) {
    return { success: false, error: e.message || 'Failed to fetch namespaces' };
  }
}

async function listPods(namespace = 'default') {
  const mode = await checkMode();
  if (mode === 'cli') {
    const res = await cliAdapter.getKubectlJson(`get pods -n ${namespace}`);
    if (res.success) {
      const pods = (res.data.items || []).map(p => {
        const containers = (p.spec.containers || []).map(c => ({
          name: c.name,
          image: c.image
        }));
        return {
          name: p.metadata.name,
          status: p.status.phase,
          ready: `${(p.status.containerStatuses || []).filter(c => c.ready).length}/${containers.length}`,
          restarts: (p.status.containerStatuses || []).reduce((acc, c) => acc + (c.restartCount || 0), 0),
          age: p.metadata.creationTimestamp,
          containers
        };
      });
      return { success: true, pods };
    }
  }

  try {
    const data = await apiClientAdapter.listPodsApi(namespace);
    const pods = (data.items || []).map(p => {
      const containers = (p.spec.containers || []).map(c => ({
        name: c.name,
        image: c.image
      }));
      return {
        name: p.metadata.name,
        status: p.status.phase,
        ready: `${(p.status.containerStatuses || []).filter(c => c.ready).length}/${containers.length}`,
        restarts: (p.status.containerStatuses || []).reduce((acc, c) => acc + (c.restartCount || 0), 0),
        age: p.metadata.creationTimestamp,
        containers
      };
    });
    return { success: true, pods };
  } catch (e) {
    return { success: false, error: e.message };
  }
}

async function listDeployments(namespace = 'default') {
  const mode = await checkMode();
  if (mode === 'cli') {
    const res = await cliAdapter.getKubectlJson(`get deployments -n ${namespace}`);
    if (res.success) {
      const deployments = (res.data.items || []).map(d => ({
        name: d.metadata.name,
        replicas: d.spec.replicas || 0,
        readyReplicas: d.status.readyReplicas || 0,
        updatedReplicas: d.status.updatedReplicas || 0,
        availableReplicas: d.status.availableReplicas || 0,
        containers: (d.spec.template.spec.containers || []).map(c => ({
          name: c.name,
          image: c.image,
          pullPolicy: c.imagePullPolicy || 'IfNotPresent',
          resources: c.resources || {}
        }))
      }));
      return { success: true, deployments };
    }
  }

  try {
    const data = await apiClientAdapter.listDeploymentsApi(namespace);
    const deployments = (data.items || []).map(d => ({
      name: d.metadata.name,
      replicas: d.spec.replicas || 0,
      readyReplicas: d.status.readyReplicas || 0,
      updatedReplicas: d.status.updatedReplicas || 0,
      availableReplicas: d.status.availableReplicas || 0,
      containers: (d.spec.template.spec.containers || []).map(c => ({
        name: c.name,
        image: c.image,
        pullPolicy: c.imagePullPolicy || 'IfNotPresent',
        resources: c.resources || {}
      }))
    }));
    return { success: true, deployments };
  } catch (e) {
    return { success: false, error: e.message };
  }
}

async function getContexts() {
  const res = await cliAdapter.runCommand('kubectl config get-contexts -o name || oc config get-contexts -o name');
  const currentRes = await cliAdapter.runCommand('kubectl config current-context || oc config current-context');
  
  if (res.success) {
    const contexts = res.output.split(/\s+/).filter(Boolean);
    const current = currentRes.output ? currentRes.output.trim() : '';
    return { success: true, contexts, current };
  }
  return { success: false, contexts: [], current: '', error: res.error };
}

module.exports = {
  checkMode,
  setUploadedKubeconfig,
  listNamespaces,
  listPods,
  listDeployments,
  getContexts,
  cliAdapter
};

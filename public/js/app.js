/**
 * KubeManage SPA Router & Logic
 */

const state = {
  user: null,
  token: localStorage.getItem('token') || null,
  currentNamespace: 'default',
  currentContext: '',
  ws: null,
  namespaces: ['default']
};

// --- Toast System ---
function showToast(message, type = 'info') {
  const container = document.getElementById('toast-container');
  if (!container) return;
  const toast = document.createElement('div');
  toast.className = `toast ${type}`;
  toast.innerText = message;
  container.appendChild(toast);
  setTimeout(() => toast.remove(), 4000);
}

// --- API Helpers ---
async function apiCall(endpoint, method = 'GET', data = null) {
  const options = {
    method,
    credentials: 'include',
    headers: {
      'Content-Type': 'application/json'
    }
  };

  if (state.token) {
    options.headers['Authorization'] = `Bearer ${state.token}`;
  }

  if (data && !(data instanceof FormData)) {
    options.body = JSON.stringify(data);
  } else if (data instanceof FormData) {
    delete options.headers['Content-Type'];
    options.body = data;
  }

  try {
    const response = await fetch(`/api${endpoint}`, options);
    if (response.status === 401) {
      handleUnauthorized();
      return { success: false, message: 'Session expired' };
    }
    return await response.json();
  } catch (err) {
    showToast(`Network error: ${err.message}`, 'error');
    return { success: false, message: err.message };
  }
}

function handleUnauthorized() {
  state.user = null;
  state.token = null;
  localStorage.removeItem('token');
  document.getElementById('login-container').classList.remove('hidden');
  document.getElementById('app-layout').classList.add('hidden');
}

// --- WebSocket Setup ---
function setupWebSocket() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = `${protocol}//${window.location.host}`;
  
  state.ws = new WebSocket(wsUrl);
  const termBody = document.getElementById('terminal-body');
  const wsStatus = document.getElementById('ws-status-text');

  state.ws.onopen = () => {
    if (wsStatus) wsStatus.innerHTML = '<span style="color:var(--accent-green);">● WebSocket Connected</span>';
  };

  state.ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      if (termBody) {
        const line = document.createElement('div');
        if (msg.type === 'log_err') line.className = 'log-err';
        line.textContent = msg.data;
        termBody.appendChild(line);
        termBody.scrollTop = termBody.scrollHeight;
      }
    } catch (e) {
      if (termBody) termBody.textContent += '\n' + event.data;
    }
  };

  state.ws.onclose = () => {
    if (wsStatus) wsStatus.innerHTML = '<span style="color:var(--accent-red);">○ WebSocket Disconnected</span>';
    setTimeout(setupWebSocket, 3000);
  };
}

// --- Global Data Loading ---
async function loadGlobalData() {
  // Load namespaces
  const nsRes = await apiCall('/cluster/namespaces');
  if (nsRes.success && nsRes.namespaces) {
    state.namespaces = nsRes.namespaces;
    const nsSelect = document.getElementById('ns-select');
    if (nsSelect) {
      nsSelect.innerHTML = nsRes.namespaces.map(ns => `<option value="${ns}" ${ns === state.currentNamespace ? 'selected' : ''}>${ns}</option>`).join('');
    }
  }

  // Load contexts
  const ctxRes = await apiCall('/cluster/contexts');
  if (ctxRes.success) {
    state.currentContext = ctxRes.current || 'active';
    const ctxBadge = document.getElementById('current-cluster-name');
    if (ctxBadge) ctxBadge.innerText = `Context: ${state.currentContext}`;
  }
}

// --- Router ---
function navigate() {
  const rawHash = window.location.hash.replace('#', '');
  const hash = rawHash || 'dashboard';
  
  // Highlight active sidebar menu
  document.querySelectorAll('.nav-item').forEach(item => {
    if (item.getAttribute('data-page') === hash) {
      item.classList.add('active');
    } else {
      item.classList.remove('active');
    }
  });

  const main = document.getElementById('main-content');
  if (!main) return;

  try {
    switch (hash) {
      case 'dashboard':
        renderDashboard(main);
        break;
      case 'pods':
        renderPods(main);
        break;
      case 'deployments':
        renderDeployments(main);
        break;
      case 'scale':
        renderScale(main);
        break;
      case 'snapshots':
        renderSnapshots(main);
        break;
      case 'resources':
        renderResources(main);
        break;
      case 'hpa':
        renderHpa(main);
        break;
      case 'config':
        renderConfig(main);
        break;
      case 'context':
        renderContext(main);
        break;
      case 'clone':
        renderClone(main);
        break;
      case 'token':
        renderToken(main);
        break;
      case 'chpasswd':
        renderChpasswd(main);
        break;
      default:
        renderDashboard(main);
    }
  } catch (err) {
    console.error('Navigation error:', err);
    showToast('Failed to load page: ' + err.message, 'error');
  }
}

// =========================================================================
// PAGE RENDERERS
// =========================================================================

// --- 1. DASHBOARD ---
async function renderDashboard(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">Cluster Overview</h2>
      <button id="refresh-dashboard-btn" class="btn btn-secondary">Refresh</button>
    </div>

    <div class="metrics-grid">
      <div class="metric-card">
        <div class="metric-info">
          <h3>Deployments</h3>
          <div id="m-deployments" class="metric-value">--</div>
        </div>
        <div class="metric-icon blue">📦</div>
      </div>
      <div class="metric-card">
        <div class="metric-info">
          <h3>Running Pods</h3>
          <div id="m-pods" class="metric-value">--</div>
        </div>
        <div class="metric-icon green">⚡</div>
      </div>
      <div class="metric-card">
        <div class="metric-info">
          <h3>Active HPAs</h3>
          <div id="m-hpas" class="metric-value">--</div>
        </div>
        <div class="metric-icon purple">📈</div>
      </div>
      <div class="metric-card">
        <div class="metric-info">
          <h3>Snapshots</h3>
          <div id="m-snapshots" class="metric-value">--</div>
        </div>
        <div class="metric-icon amber">💾</div>
      </div>
    </div>

    <div class="card-section">
      <h3 class="card-title">Deployments in '${state.currentNamespace}'</h3>
      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Deployment Name</th>
              <th>Replicas (Ready/Desired)</th>
              <th>Containers & Images</th>
              <th>Image Pull Policy</th>
            </tr>
          </thead>
          <tbody id="dashboard-dep-table">
            <tr><td colspan="4">Loading deployments...</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  `;

  document.getElementById('refresh-dashboard-btn').onclick = () => renderDashboard(container);

  // Fetch metric data
  const depRes = await apiCall(`/deployments?ns=${state.currentNamespace}`);
  const podRes = await apiCall(`/pods?ns=${state.currentNamespace}`);
  const hpaRes = await apiCall(`/hpa?ns=${state.currentNamespace}`);
  const snapRes = await apiCall('/snapshots');

  if (depRes.success) {
    document.getElementById('m-deployments').innerText = depRes.deployments.length;
    const tbody = document.getElementById('dashboard-dep-table');
    if (depRes.deployments.length === 0) {
      tbody.innerHTML = '<tr><td colspan="4">No deployments found in this namespace.</td></tr>';
    } else {
      tbody.innerHTML = depRes.deployments.map(d => `
        <tr>
          <td><strong>${d.name}</strong></td>
          <td><span class="badge ${d.readyReplicas === d.replicas ? 'badge-success' : 'badge-warning'}">${d.readyReplicas}/${d.replicas}</span></td>
          <td>${d.containers.map(c => `<div><code>${c.name}</code>: <span style="color:var(--accent-cyan);">${c.image}</span></div>`).join('')}</td>
          <td>${d.containers.map(c => `<span class="badge badge-info">${c.pullPolicy}</span>`).join(' ')}</td>
        </tr>
      `).join('');
    }
  }

  if (podRes.success) {
    document.getElementById('m-pods').innerText = podRes.pods.length;
  }

  if (hpaRes.success) {
    document.getElementById('m-hpas').innerText = hpaRes.hpas.length;
  }

  if (snapRes.success) {
    document.getElementById('m-snapshots').innerText = snapRes.snapshots.length;
  }
}

// --- 2. PODS LIST ---
async function renderPods(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">Pods List</h2>
      <button id="refresh-pods-btn" class="btn btn-secondary">Refresh</button>
    </div>

    <div class="card-section">
      <h3 class="card-title">Restart Pods by Pattern</h3>
      <form id="restart-pods-form" style="display:flex; gap:12px; align-items:flex-end;">
        <div class="form-group" style="flex:1; margin-bottom:0;">
          <label>Regex Pattern (e.g. ^app-penjaminan-)</label>
          <input type="text" id="restart-pattern-input" class="input-field" placeholder="Pattern regex" required>
        </div>
        <button type="submit" class="btn btn-danger">Restart Matching Pods</button>
      </form>
    </div>

    <div class="card-section">
      <h3 class="card-title">Pods in '${state.currentNamespace}'</h3>
      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Pod Name</th>
              <th>Status</th>
              <th>Ready</th>
              <th>Restarts</th>
              <th>Container & Image</th>
            </tr>
          </thead>
          <tbody id="pods-table">
            <tr><td colspan="5">Loading pods...</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  `;

  document.getElementById('refresh-pods-btn').onclick = () => renderPods(container);

  document.getElementById('restart-pods-form').onsubmit = async (e) => {
    e.preventDefault();
    const pattern = document.getElementById('restart-pattern-input').value;
    if (!confirm(`Are you sure you want to restart pods matching '${pattern}' in '${state.currentNamespace}'?`)) return;
    
    showToast('Executing pod restart...', 'info');
    const res = await apiCall('/pods/restart', 'POST', { pattern, namespace: state.currentNamespace });
    if (res.success) {
      showToast('Pods restarted successfully!', 'success');
      renderPods(container);
    } else {
      showToast(res.error || 'Failed to restart pods', 'error');
    }
  };

  const res = await apiCall(`/pods?ns=${state.currentNamespace}`);
  const tbody = document.getElementById('pods-table');
  if (res.success && res.pods) {
    if (res.pods.length === 0) {
      tbody.innerHTML = '<tr><td colspan="5">No pods found.</td></tr>';
    } else {
      tbody.innerHTML = res.pods.map(p => `
        <tr>
          <td><strong>${p.name}</strong></td>
          <td><span class="badge ${p.status === 'Running' ? 'badge-success' : 'badge-danger'}">${p.status}</span></td>
          <td>${p.ready}</td>
          <td>${p.restarts}</td>
          <td>${p.containers.map(c => `<div><code>${c.name}</code>: <span style="color:var(--accent-cyan);">${c.image}</span></div>`).join('')}</td>
        </tr>
      `).join('');
    }
  } else {
    tbody.innerHTML = `<tr><td colspan="5" style="color:var(--accent-red);">${res.error || 'Error fetching pods'}</td></tr>`;
  }
}

// --- 3. DEPLOYMENTS (Update / Rollback / Pull Policy) ---
async function renderDeployments(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">Deployments Management</h2>
    </div>

    <div class="tabs">
      <button class="tab-btn active" data-tab="update">Update Image Tag</button>
      <button class="tab-btn" data-tab="rollback">Rollback Snapshot</button>
      <button class="tab-btn" data-tab="pullpolicy">Pull Policy</button>
    </div>

    <div id="tab-content"></div>
  `;

  const tabs = container.querySelectorAll('.tab-btn');
  tabs.forEach(tab => {
    tab.onclick = () => {
      tabs.forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      renderDeploymentTab(tab.getAttribute('data-tab'));
    };
  });

  renderDeploymentTab('update');
}

async function renderDeploymentTab(tabName) {
  const content = document.getElementById('tab-content');
  if (!content) return;

  if (tabName === 'update') {
    content.innerHTML = `
      <div class="card-section">
        <h3 class="card-title">Update Deployment Image Tag</h3>
        <form id="update-form" class="form-grid">
          <div class="form-group">
            <label>New Image Tag (-t)</label>
            <input type="text" id="up-tag" class="input-field" placeholder="e.g. v3.0.0" required>
          </div>
          <div class="form-group">
            <label>Deployment File (-f, optional)</label>
            <input type="text" id="up-file" class="input-field" placeholder="Path file.txt">
          </div>
          <div class="form-group">
            <label>Registry Auth (user:pass, optional)</label>
            <input type="text" id="up-auth" class="input-field" placeholder="admin:pass">
          </div>
          <div class="form-group" style="grid-column: 1 / -1; display:flex; gap:20px;">
            <label><input type="checkbox" id="up-dry"> Dry Run (-d)</label>
            <label><input type="checkbox" id="up-check"> Check Registry Tag (-c)</label>
            <label><input type="checkbox" id="up-autorollback" checked> Auto Rollback (--auto-rollback)</label>
            <label><input type="checkbox" id="up-wait" checked> Wait Rollout (--wait)</label>
          </div>
          <div style="grid-column: 1 / -1;">
            <button type="submit" class="btn btn-primary">Execute Tag Update</button>
          </div>
        </form>
      </div>
    `;

    document.getElementById('update-form').onsubmit = async (e) => {
      e.preventDefault();
      const payload = {
        tag: document.getElementById('up-tag').value,
        namespace: state.currentNamespace,
        deploymentFile: document.getElementById('up-file').value,
        auth: document.getElementById('up-auth').value,
        dryRun: document.getElementById('up-dry').checked,
        checkRegistry: document.getElementById('up-check').checked,
        autoRollback: document.getElementById('up-autorollback').checked,
        wait: document.getElementById('up-wait').checked
      };

      showToast('Executing deployment update...', 'info');
      const res = await apiCall('/deployments/update', 'POST', payload);
      if (res.success) {
        showToast('Update command finished!', 'success');
      } else {
        showToast(res.error || 'Update failed', 'error');
      }
    };
  } else if (tabName === 'rollback') {
    content.innerHTML = `
      <div class="card-section">
        <h3 class="card-title">Rollback Deployment</h3>
        <form id="rollback-form">
          <div class="form-group">
            <label>Snapshot File Path (-s, optional)</label>
            <input type="text" id="rb-file" class="input-field" placeholder="Leave empty for latest snapshot">
          </div>
          <button type="submit" class="btn btn-danger">Execute Rollback</button>
        </form>
      </div>
    `;

    document.getElementById('rollback-form').onsubmit = async (e) => {
      e.preventDefault();
      const snapshotFile = document.getElementById('rb-file').value;
      if (!confirm('Are you sure you want to rollback to this snapshot?')) return;

      showToast('Executing rollback...', 'info');
      const res = await apiCall('/deployments/rollback', 'POST', {
        namespace: state.currentNamespace,
        snapshotFile
      });
      if (res.success) {
        showToast('Rollback finished!', 'success');
      } else {
        showToast(res.error || 'Rollback failed', 'error');
      }
    };
  } else if (tabName === 'pullpolicy') {
    content.innerHTML = `
      <div class="card-section">
        <h3 class="card-title">Update Image Pull Policy</h3>
        <form id="pull-policy-form" class="form-grid">
          <div class="form-group">
            <label>Deployment Name (-d)</label>
            <input type="text" id="pp-deploy" class="input-field" placeholder="e.g. app-penjaminan" required>
          </div>
          <div class="form-group">
            <label>Policy (-p)</label>
            <select id="pp-policy" class="input-field">
              <option value="Always">Always</option>
              <option value="IfNotPresent">IfNotPresent</option>
              <option value="Never">Never</option>
            </select>
          </div>
          <div class="form-group">
            <label>Container Name (-c, optional)</label>
            <input type="text" id="pp-container" class="input-field" placeholder="First container by default">
          </div>
          <div style="grid-column: 1 / -1;">
            <button type="submit" class="btn btn-primary">Apply Pull Policy</button>
          </div>
        </form>
      </div>
    `;

    document.getElementById('pull-policy-form').onsubmit = async (e) => {
      e.preventDefault();
      const payload = {
        deployment: document.getElementById('pp-deploy').value,
        policy: document.getElementById('pp-policy').value,
        container: document.getElementById('pp-container').value,
        namespace: state.currentNamespace
      };

      showToast('Updating image pull policy...', 'info');
      const res = await apiCall('/deployments/pull-policy', 'POST', payload);
      if (res.success) {
        showToast('Pull policy updated!', 'success');
      } else {
        showToast(res.error || 'Failed to update pull policy', 'error');
      }
    };
  }
}

// --- 4. SCALE ---
async function renderScale(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">Scale Deployment Replicas</h2>
    </div>

    <div class="card-section">
      <form id="scale-form" class="form-grid">
        <div class="form-group">
          <label>Target Deployment</label>
          <input type="text" id="scale-deploy" class="input-field" placeholder="Deployment name (or leave empty if checking --all)">
        </div>
        <div class="form-group">
          <label>New Replicas Count (-r)</label>
          <input type="number" id="scale-replicas" class="input-field" placeholder="e.g. 3" min="0" required>
        </div>
        <div class="form-group" style="grid-column: 1 / -1;">
          <label><input type="checkbox" id="scale-all"> Scale ALL deployments in namespace (--all)</label>
        </div>
        <div style="grid-column: 1 / -1;">
          <button type="submit" class="btn btn-primary">Apply Scale</button>
        </div>
      </form>
    </div>
  `;

  document.getElementById('scale-form').onsubmit = async (e) => {
    e.preventDefault();
    const deployment = document.getElementById('scale-deploy').value;
    const replicas = document.getElementById('scale-replicas').value;
    const all = document.getElementById('scale-all').checked;

    if (!all && !deployment) {
      showToast('Please specify a deployment name or check --all', 'error');
      return;
    }

    if (!confirm(`Confirm scaling to ${replicas} replicas?`)) return;

    showToast('Executing scale command...', 'info');
    const res = await apiCall('/scale', 'POST', {
      namespace: state.currentNamespace,
      deployment,
      replicas,
      all
    });

    if (res.success) {
      showToast('Scale completed!', 'success');
    } else {
      showToast(res.error || 'Scale failed', 'error');
    }
  };
}

// --- 5. SNAPSHOTS ---
async function renderSnapshots(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">Update Snapshots</h2>
      <button id="refresh-snap-btn" class="btn btn-secondary">Refresh</button>
    </div>

    <div class="card-section">
      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Snapshot File</th>
              <th>Namespace</th>
              <th>Tag Updated</th>
              <th>Timestamp</th>
              <th>Action</th>
            </tr>
          </thead>
          <tbody id="snapshots-table">
            <tr><td colspan="5">Loading snapshots...</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  `;

  document.getElementById('refresh-snap-btn').onclick = () => renderSnapshots(container);

  const res = await apiCall('/snapshots');
  const tbody = document.getElementById('snapshots-table');

  if (res.success && res.snapshots) {
    if (res.snapshots.length === 0) {
      tbody.innerHTML = '<tr><td colspan="5">No snapshots saved yet.</td></tr>';
    } else {
      tbody.innerHTML = res.snapshots.map(s => `
        <tr>
          <td><code>${s.filename}</code></td>
          <td>${s.namespace}</td>
          <td><span class="badge badge-info">${s.newTag}</span></td>
          <td>${s.timestamp}</td>
          <td>
            <button class="btn btn-secondary do-rollback-btn" data-path="${s.path}">Rollback to this</button>
          </td>
        </tr>
      `).join('');

      document.querySelectorAll('.do-rollback-btn').forEach(btn => {
        btn.onclick = async () => {
          const filePath = btn.getAttribute('data-path');
          if (!confirm(`Rollback using snapshot file ${filePath}?`)) return;
          showToast('Executing rollback...', 'info');
          const rbRes = await apiCall('/deployments/rollback', 'POST', {
            namespace: state.currentNamespace,
            snapshotFile: filePath
          });
          if (rbRes.success) showToast('Rollback successful!', 'success');
          else showToast(rbRes.error || 'Rollback failed', 'error');
        };
      });
    }
  }
}

// --- 6. RESOURCES (CPU & Memory) ---
async function renderResources(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">CPU & Memory Limits</h2>
    </div>

    <div class="card-section">
      <form id="resources-form" class="form-grid">
        <div class="form-group">
          <label>Target Deployment</label>
          <input type="text" id="res-deploy" class="input-field" placeholder="Deployment name">
        </div>
        <div class="form-group">
          <label>CPU Request (--cpu-req)</label>
          <input type="text" id="res-cpureq" class="input-field" placeholder="e.g. 100m">
        </div>
        <div class="form-group">
          <label>Memory Request (--mem-req)</label>
          <input type="text" id="res-memreq" class="input-field" placeholder="e.g. 256Mi">
        </div>
        <div class="form-group">
          <label>CPU Limit (--cpu-lim)</label>
          <input type="text" id="res-cpulim" class="input-field" placeholder="e.g. 500m">
        </div>
        <div class="form-group">
          <label>Memory Limit (--mem-lim)</label>
          <input type="text" id="res-memlim" class="input-field" placeholder="e.g. 512Mi">
        </div>
        <div class="form-group" style="grid-column: 1 / -1;">
          <label><input type="checkbox" id="res-all"> Apply to ALL deployments in namespace (--all)</label>
        </div>
        <div style="grid-column: 1 / -1;">
          <button type="submit" class="btn btn-primary">Apply Resource Settings</button>
        </div>
      </form>
    </div>
  `;

  document.getElementById('resources-form').onsubmit = async (e) => {
    e.preventDefault();
    const payload = {
      namespace: state.currentNamespace,
      deployment: document.getElementById('res-deploy').value,
      cpuReq: document.getElementById('res-cpureq').value,
      memReq: document.getElementById('res-memreq').value,
      cpuLim: document.getElementById('res-cpulim').value,
      memLim: document.getElementById('res-memlim').value,
      all: document.getElementById('res-all').checked
    };

    showToast('Applying resource limits...', 'info');
    const res = await apiCall('/resources', 'POST', payload);
    if (res.success) showToast('Resources updated!', 'success');
    else showToast(res.error || 'Failed to update resources', 'error');
  };
}

// --- 7. HPA (Horizontal Pod Autoscaler) ---
async function renderHpa(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">Horizontal Pod Autoscaler (HPA)</h2>
    </div>

    <div class="card-section">
      <form id="hpa-form" class="form-grid">
        <div class="form-group">
          <label>Deployment Name</label>
          <input type="text" id="hpa-deploy" class="input-field" placeholder="Target deployment">
        </div>
        <div class="form-group">
          <label>Min Replicas (--min)</label>
          <input type="number" id="hpa-min" class="input-field" value="1">
        </div>
        <div class="form-group">
          <label>Max Replicas (--max)</label>
          <input type="number" id="hpa-max" class="input-field" value="5">
        </div>
        <div class="form-group">
          <label>Target CPU % (--cpu-percent)</label>
          <input type="number" id="hpa-cpu" class="input-field" value="80">
        </div>
        <div class="form-group">
          <label>Target Memory % (--mem-percent)</label>
          <input type="number" id="hpa-mem" class="input-field" placeholder="Optional">
        </div>
        <div class="form-group" style="grid-column: 1 / -1; display:flex; gap:20px;">
          <label><input type="checkbox" id="hpa-all"> Apply to ALL deployments (--all)</label>
          <label><input type="checkbox" id="hpa-del"> Delete HPA (--delete)</label>
        </div>
        <div style="grid-column: 1 / -1;">
          <button type="submit" class="btn btn-primary">Configure HPA</button>
        </div>
      </form>
    </div>
  `;

  document.getElementById('hpa-form').onsubmit = async (e) => {
    e.preventDefault();
    const payload = {
      namespace: state.currentNamespace,
      deployment: document.getElementById('hpa-deploy').value,
      min: document.getElementById('hpa-min').value,
      max: document.getElementById('hpa-max').value,
      cpuPercent: document.getElementById('hpa-cpu').value,
      memPercent: document.getElementById('hpa-mem').value,
      all: document.getElementById('hpa-all').checked,
      deleteMode: document.getElementById('hpa-del').checked
    };

    showToast('Executing HPA operation...', 'info');
    const res = await apiCall('/hpa', 'POST', payload);
    if (res.success) showToast('HPA operation completed!', 'success');
    else showToast(res.error || 'HPA failed', 'error');
  };
}

// --- 8. CONFIG / ENV ---
async function renderConfig(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">ConfigMap & Environment Variables</h2>
    </div>

    <div class="card-section">
      <h3 class="card-title">Set Deployment Env Pair (-e KEY=VALUE)</h3>
      <form id="config-env-form" class="form-grid">
        <div class="form-group">
          <label>Environment Pair (-e)</label>
          <input type="text" id="cfg-env" class="input-field" placeholder="e.g. JAVA_TOOL_OPTIONS=-Xmx512m" required>
        </div>
        <div class="form-group">
          <label>Target Deployment (-d, optional)</label>
          <input type="text" id="cfg-dep" class="input-field" placeholder="Leave empty for all deployments">
        </div>
        <div class="form-group" style="grid-column: 1 / -1;">
          <label><input type="checkbox" id="cfg-restart" checked> Auto Restart Rollout (-r)</label>
        </div>
        <div style="grid-column: 1 / -1;">
          <button type="submit" class="btn btn-primary">Apply Environment Variable</button>
        </div>
      </form>
    </div>
  `;

  document.getElementById('config-env-form').onsubmit = async (e) => {
    e.preventDefault();
    const payload = {
      namespace: state.currentNamespace,
      envPair: document.getElementById('cfg-env').value,
      deployment: document.getElementById('cfg-dep').value,
      restart: document.getElementById('cfg-restart').checked
    };

    showToast('Updating config...', 'info');
    const res = await apiCall('/config', 'POST', payload);
    if (res.success) showToast('Config updated successfully!', 'success');
    else showToast(res.error || 'Failed to update config', 'error');
  };
}

// --- 9. CONTEXT ---
async function renderContext(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">Cluster Context Manager</h2>
    </div>

    <div class="card-section">
      <h3 class="card-title">Import Kubeconfig File (--add-file)</h3>
      <form id="upload-kubeconfig-form" style="display:flex; gap:12px; align-items:flex-end;">
        <div class="form-group" style="flex:1; margin-bottom:0;">
          <label>Select Kubeconfig File (.yaml / .config)</label>
          <input type="file" id="kc-file-input" class="input-field" required>
        </div>
        <div class="form-group" style="flex:1; margin-bottom:0;">
          <label>Context Alias Name (optional)</label>
          <input type="text" id="kc-alias-input" class="input-field" placeholder="e.g. prod-cluster">
        </div>
        <button type="submit" class="btn btn-primary">Upload & Merge</button>
      </form>
    </div>

    <div class="card-section">
      <h3 class="card-title">Available Contexts</h3>
      <div id="contexts-list">Loading contexts...</div>
    </div>
  `;

  document.getElementById('upload-kubeconfig-form').onsubmit = async (e) => {
    e.preventDefault();
    const fileInput = document.getElementById('kc-file-input');
    const aliasInput = document.getElementById('kc-alias-input').value;
    if (!fileInput.files[0]) return;

    const formData = new FormData();
    formData.append('kubeconfig', fileInput.files[0]);
    if (aliasInput) formData.append('alias', aliasInput);

    showToast('Uploading kubeconfig...', 'info');
    const res = await apiCall('/cluster/contexts/upload', 'POST', formData);
    if (res.success) {
      showToast('Kubeconfig uploaded & context activated!', 'success');
      fileInput.value = '';
      await loadGlobalData();
      renderContext(container);
    } else {
      showToast(res.error || res.message || 'Failed to upload kubeconfig', 'error');
    }
  };

  const res = await apiCall('/cluster/contexts');
  const ctxDiv = document.getElementById('contexts-list');
  if (res.success && res.contexts) {
    ctxDiv.innerHTML = res.contexts.map(c => `
      <div style="display:flex; justify-content:space-between; align-items:center; padding:10px; border-bottom:1px solid var(--border-color);">
        <div>
          <strong>${c}</strong> ${c === res.current ? '<span class="badge badge-success">ACTIVE</span>' : ''}
        </div>
        <div style="display:flex; gap:8px;">
          ${c !== res.current ? `<button class="btn btn-secondary switch-ctx-btn" data-ctx="${c}">Switch to</button>` : ''}
          <button class="btn btn-danger del-ctx-btn" data-ctx="${c}">Delete</button>
        </div>
      </div>
    `).join('');

    document.querySelectorAll('.switch-ctx-btn').forEach(btn => {
      btn.onclick = async () => {
        const target = btn.getAttribute('data-ctx');
        showToast(`Switching context to ${target}...`, 'info');
        const sRes = await apiCall('/cluster/contexts/switch', 'POST', { context: target });
        if (sRes.success) {
          showToast('Switched context!', 'success');
          loadGlobalData();
          renderContext(container);
        } else {
          showToast(sRes.error || 'Switch failed', 'error');
        }
      };
    });

    document.querySelectorAll('.del-ctx-btn').forEach(btn => {
      btn.onclick = async () => {
        const target = btn.getAttribute('data-ctx');
        if (!confirm(`Delete context '${target}'?`)) return;
        const dRes = await apiCall(`/cluster/contexts/${encodeURIComponent(target)}`, 'DELETE');
        if (dRes.success) {
          showToast('Context deleted', 'success');
          loadGlobalData();
          renderContext(container);
        }
      };
    });
  }
}

// --- 10. CLONE ---
async function renderClone(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">Clone Namespace / Project</h2>
    </div>

    <div class="card-section">
      <form id="clone-form" class="form-grid">
        <div class="form-group">
          <label>Source Namespace (-s)</label>
          <input type="text" id="clone-src" class="input-field" placeholder="e.g. jaguars" required>
        </div>
        <div class="form-group">
          <label>Target Namespace (-n)</label>
          <input type="text" id="clone-target" class="input-field" placeholder="e.g. jaguars-dev" required>
        </div>
        <div class="form-group">
          <label>Resource Filter (--only, optional)</label>
          <input type="text" id="clone-only" class="input-field" placeholder="e.g. service, deployment">
        </div>
        <div class="form-group">
          <label>PVC Rename Map (-r, optional)</label>
          <input type="text" id="clone-rename" class="input-field" placeholder="old-pvc:new-pvc">
        </div>
        <div class="form-group" style="grid-column: 1 / -1; display:flex; gap:20px;">
          <label><input type="checkbox" id="clone-pvcdata"> Duplicate PVC data via CSI VolumeSnapshot (-p)</label>
          <label><input type="checkbox" id="clone-skippvc"> Skip PVC creation (-x)</label>
        </div>
        <div style="grid-column: 1 / -1;">
          <button type="submit" class="btn btn-primary">Start Clone Process</button>
        </div>
      </form>
    </div>
  `;

  document.getElementById('clone-form').onsubmit = async (e) => {
    e.preventDefault();
    const payload = {
      sourceNs: document.getElementById('clone-src').value,
      targetNs: document.getElementById('clone-target').value,
      onlyResource: document.getElementById('clone-only').value,
      pvcRenameMap: document.getElementById('clone-rename').value,
      withPvcData: document.getElementById('clone-pvcdata').checked,
      skipPvc: document.getElementById('clone-skippvc').checked
    };

    if (!confirm(`Clone namespace '${payload.sourceNs}' to '${payload.targetNs}'?`)) return;

    showToast('Starting clone process...', 'info');
    const res = await apiCall('/clone', 'POST', payload);
    if (res.success) showToast('Clone completed successfully!', 'success');
    else showToast(res.error || 'Clone failed', 'error');
  };
}

// --- 11. TOKEN ---
async function renderToken(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">Generate Bearer Token</h2>
    </div>

    <div class="card-section">
      <form id="token-form" class="form-grid">
        <div class="form-group">
          <label>ServiceAccount Name (-u)</label>
          <input type="text" id="token-user" class="input-field" value="admin-user" required>
        </div>
        <div class="form-group">
          <label>Duration (--duration)</label>
          <input type="text" id="token-duration" class="input-field" value="8760h">
        </div>
        <div class="form-group" style="grid-column: 1 / -1;">
          <label><input type="checkbox" id="token-permanent"> Create Permanent Secret Token (--permanent)</label>
        </div>
        <div style="grid-column: 1 / -1;">
          <button type="submit" class="btn btn-primary">Generate Token</button>
        </div>
      </form>
    </div>
  `;

  document.getElementById('token-form').onsubmit = async (e) => {
    e.preventDefault();
    const payload = {
      user: document.getElementById('token-user').value,
      namespace: state.currentNamespace,
      duration: document.getElementById('token-duration').value,
      permanent: document.getElementById('token-permanent').checked
    };

    showToast('Generating token...', 'info');
    const res = await apiCall('/token', 'POST', payload);
    if (res.success) showToast('Token generated! Check console stream below.', 'success');
    else showToast(res.error || 'Token generation failed', 'error');
  };
}

// --- 12. CHPASSWD ---
async function renderChpasswd(container) {
  container.innerHTML = `
    <div class="page-header">
      <h2 class="page-title">Change OpenShift User Password (HTPasswd)</h2>
    </div>

    <div class="card-section">
      <form id="chpasswd-form" class="form-grid">
        <div class="form-group">
          <label>Target Username (-u)</label>
          <input type="text" id="cp-user" class="input-field" placeholder="Username to change password" required>
        </div>
        <div class="form-group">
          <label>HTPasswd Secret Name (-s)</label>
          <input type="text" id="cp-secret" class="input-field" value="htpass-secret">
        </div>
        <div class="form-group">
          <label>Secret Namespace (--secret-ns)</label>
          <input type="text" id="cp-secns" class="input-field" value="openshift-config">
        </div>
        <div style="grid-column: 1 / -1;">
          <button type="submit" class="btn btn-primary">Update Password</button>
        </div>
      </form>
    </div>
  `;

  document.getElementById('chpasswd-form').onsubmit = async (e) => {
    e.preventDefault();
    const payload = {
      user: document.getElementById('cp-user').value,
      secretName: document.getElementById('cp-secret').value,
      secretNs: document.getElementById('cp-secns').value
    };

    showToast('Updating password...', 'info');
    const res = await apiCall('/chpasswd', 'POST', payload);
    if (res.success) showToast('Password updated!', 'success');
    else showToast(res.error || 'Failed to change password', 'error');
  };
}

// =========================================================================
// INITIALIZATION
// =========================================================================
document.addEventListener('DOMContentLoaded', async () => {
  // Global router listeners
  window.addEventListener('hashchange', () => navigate());

  document.querySelectorAll('.nav-item').forEach(item => {
    item.addEventListener('click', (e) => {
      const page = item.getAttribute('data-page');
      if (page) {
        window.location.hash = page;
        navigate();
      }
    });
  });

  // Login form handler
  const loginForm = document.getElementById('login-form');
  if (loginForm) {
    loginForm.onsubmit = async (e) => {
      e.preventDefault();
      const username = document.getElementById('login-username').value;
      const password = document.getElementById('login-password').value;

      const res = await apiCall('/auth/login', 'POST', { username, password });
      if (res.success) {
        state.user = res.user;
        state.token = res.token;
        if (res.token) {
          localStorage.setItem('token', res.token);
        }
        document.getElementById('login-container').classList.add('hidden');
        document.getElementById('app-layout').classList.remove('hidden');
        document.getElementById('user-display-name').innerText = res.user.name || res.user.username;
        setupWebSocket();
        await loadGlobalData();
        navigate();
      } else {
        showToast(res.message || 'Login failed', 'error');
      }
    };
  }

  // Logout button
  const logoutBtn = document.getElementById('logout-btn');
  if (logoutBtn) {
    logoutBtn.onclick = async () => {
      await apiCall('/auth/logout', 'POST');
      handleUnauthorized();
    };
  }

  // Namespace selector listener
  const nsSelect = document.getElementById('ns-select');
  if (nsSelect) {
    nsSelect.onchange = (e) => {
      state.currentNamespace = e.target.value;
      showToast(`Namespace changed to '${state.currentNamespace}'`, 'info');
      navigate();
    };
  }

  // Check auth session
  const authRes = await apiCall('/auth/me');
  if (authRes.success && authRes.user) {
    state.user = authRes.user;
    document.getElementById('login-container').classList.add('hidden');
    document.getElementById('app-layout').classList.remove('hidden');
    document.getElementById('user-display-name').innerText = authRes.user.name || authRes.user.username;
    setupWebSocket();
    await loadGlobalData();
    navigate();
  }
});

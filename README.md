# KubeManage Dashboard & CLI

Web UI Dashboard and CLI tool for managing Kubernetes & OpenShift clusters.

![Theme](https://img.shields.io/badge/Theme-Flat%20Dark-blue)
![Node](https://img.shields.io/badge/Node.js-v20-green)
![Docker](https://img.shields.io/badge/Docker-Ready-cyan)

---

## 🚀 Quick Start (Local Node.js)

```bash
# 1. Install dependencies
npm install

# 2. Start server
npm run dev

# 3. Open browser: http://localhost:3000
# Default login: admin / admin123
```

---

## 🐳 Running with Docker

```bash
# Build image
docker build -t kubemanage:latest .

# Run container (mount your ~/.kube/config into container)
docker run -d \
  -p 3000:3000 \
  -v ~/.kube/config:/root/.kube/config:ro \
  --name kubemanage \
  kubemanage:latest
```

---

## 🛠️ Key Features

- 📊 **Dashboard**: Cluster metrics, deployment statuses, and running pods.
- ⚡ **Pods Management**: View pod details and restart pods by regex pattern.
- 📦 **Deployments**: Image tag updates with auto-rollback, check registry tags, and image pull policy management.
- ⚖️ **Scale**: Single or batch replica scaling.
- 💾 **Snapshots**: Save and restore rollback `.env` snapshots with 1-click.
- 🔋 **CPU/Memory Limits**: Update container resource requests and limits.
- 📈 **HPA**: Horizontal Pod Autoscaler configuration (min/max replicas, CPU/Memory %).
- ⚙️ **ConfigMap & Env**: Set deployment environment variables or batch replace strings across ConfigMaps/Secrets.
- 🌐 **Cluster Context**: Switch active context, upload/import `kubeconfig` files, or login via URL.
- 👥 **Clone Namespace**: Duplicate resources across namespaces with PVC claim renames.
- 🔑 **Token Generator**: Create 1-year or permanent Bearer tokens for ServiceAccounts.
- 🔒 **Change Password**: Update OpenShift HTPasswd passwords.
- 📟 **Terminal Stream**: Real-time console log streaming via WebSockets.

---

## 🔒 Security & Password Hashing

To change default admin password, generate a bcrypt hash using:

```bash
npm run hash-password yourNewPassword
```

Copy the hash output into `server/users.json`.

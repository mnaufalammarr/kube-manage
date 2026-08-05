const { exec, execFile, spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const SCRIPT_PATH = path.resolve(__dirname, '../../scripts/kube-manage.sh');

function runCommand(commandStr, options = {}) {
  return new Promise((resolve, reject) => {
    exec(commandStr, { maxBuffer: 10 * 1024 * 1024, ...options }, (error, stdout, stderr) => {
      if (error) {
        return resolve({ success: false, error: stderr || stdout || error.message, code: error.code });
      }
      resolve({ success: true, output: stdout.trim(), stderr: stderr.trim() });
    });
  });
}

function runScript(mode, args = [], wsStream = null) {
  return new Promise((resolve) => {
    // Detect bash execution environment
    const isWin = process.platform === 'win32';
    let cmd = 'bash';
    let fullArgs = [SCRIPT_PATH, mode, ...args];

    if (isWin && !fs.existsSync('C:\\Program Files\\Git\\bin\\bash.exe') && !fs.existsSync('C:\\msys64\\usr\\bin\\bash.exe')) {
      // In windows powershell environment without git bash, fallback to wsl or bash
      cmd = 'wsl';
      fullArgs = ['bash', SCRIPT_PATH.replace(/\\/g, '/'), mode, ...args];
    }

    const proc = spawn(cmd, fullArgs, { shell: true });
    let output = '';
    let errorOutput = '';

    proc.stdout.on('data', (data) => {
      const chunk = data.toString();
      output += chunk;
      if (wsStream) {
        wsStream.send(JSON.stringify({ type: 'log', data: chunk }));
      }
    });

    proc.stderr.on('data', (data) => {
      const chunk = data.toString();
      errorOutput += chunk;
      if (wsStream) {
        wsStream.send(JSON.stringify({ type: 'log_err', data: chunk }));
      }
    });

    proc.on('close', (code) => {
      if (code === 0) {
        resolve({ success: true, output, code });
      } else {
        resolve({ success: false, output: output || errorOutput, error: errorOutput, code });
      }
    });

    proc.on('error', (err) => {
      resolve({ success: false, error: err.message });
    });
  });
}

// Direct kubectl JSON queries helper
async function getKubectlJson(argsStr) {
  const result = await runCommand(`kubectl ${argsStr} -o json`);
  if (!result.success) {
    // try oc
    const ocResult = await runCommand(`oc ${argsStr} -o json`);
    if (ocResult.success) {
      try {
        return { success: true, data: JSON.parse(ocResult.output) };
      } catch (e) {
        return { success: false, error: 'Failed to parse JSON output' };
      }
    }
    return { success: false, error: result.error };
  }
  try {
    return { success: true, data: JSON.parse(result.output) };
  } catch (e) {
    return { success: false, error: 'Failed to parse JSON output' };
  }
}

module.exports = {
  runCommand,
  runScript,
  getKubectlJson
};

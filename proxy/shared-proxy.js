#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const SCRIPT_VERSION = "portable-2026-06-20";

function usage() {
  console.error("Usage: node shared-proxy.js <config-file> <websocket-url>");
}

function fileExists(filePath) {
  try {
    return fs.statSync(filePath).isFile();
  } catch {
    return false;
  }
}

function dirExists(dirPath) {
  try {
    return fs.statSync(dirPath).isDirectory();
  } catch {
    return false;
  }
}

function newestPath(paths) {
  return paths
    .filter(Boolean)
    .filter((candidate) => {
      try {
        fs.statSync(candidate);
        return true;
      } catch {
        return false;
      }
    })
    .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)[0];
}

function resolveAnyscaleProxyScript(config) {
  const explicit = config.proxyScriptPath || process.env.ANYSCALE_PROXY_SCRIPT_PATH;
  if (explicit && fileExists(explicit)) {
    return explicit;
  }

  const cursorRoot =
    config.cursorServerRoot ||
    process.env.CURSOR_SERVER_ROOT ||
    path.join(process.env.HOME || "/root", ".cursor-server");
  const extensionsDir = path.join(cursorRoot, "extensions");

  if (!dirExists(extensionsDir)) {
    throw new Error(`Cannot find Cursor extensions dir: ${extensionsDir}`);
  }

  const candidates = fs
    .readdirSync(extensionsDir)
    .filter((name) => /^anyscalecompute\.anyscale-workspaces-.*-universal$/.test(name))
    .map((name) => path.join(extensionsDir, name, "dist", "utils", "sshproxy.js"))
    .filter(fileExists);

  const proxyScriptPath = newestPath(candidates);
  if (!proxyScriptPath) {
    throw new Error(`Cannot find Anyscale sshproxy.js under ${extensionsDir}`);
  }

  return proxyScriptPath;
}

function resolveNodeExecutable(config, proxyScriptPath) {
  const explicit = config.nodeExecutable || process.env.ANYSCALE_NODE_EXECUTABLE;
  if (explicit && fileExists(explicit)) {
    return explicit;
  }

  const cursorRootFromProxy = proxyScriptPath.split(`${path.sep}extensions${path.sep}`)[0];
  const binRoot = path.join(cursorRootFromProxy, "bin", "linux-x64");
  if (dirExists(binRoot)) {
    const bundledNodes = fs
      .readdirSync(binRoot)
      .map((name) => path.join(binRoot, name, "node"))
      .filter(fileExists);
    const bundledNode = newestPath(bundledNodes);
    if (bundledNode) {
      return bundledNode;
    }
  }

  if (process.execPath && fileExists(process.execPath)) {
    return process.execPath;
  }

  const whichNode = spawnSync("command", ["-v", "node"], {
    shell: true,
    encoding: "utf8",
  });
  const nodePath = whichNode.stdout && whichNode.stdout.trim();
  if (nodePath && fileExists(nodePath)) {
    return nodePath;
  }

  throw new Error("Cannot resolve a Node.js executable");
}

function requireString(config, key) {
  if (!config[key] || typeof config[key] !== "string") {
    throw new Error(`Missing required config string: ${key}`);
  }
  return config[key];
}

function main() {
  if (process.argv.length < 4) {
    usage();
    process.exit(1);
  }

  const configFile = process.argv[2];
  const websocketUrl = process.argv[3];
  const config = JSON.parse(fs.readFileSync(configFile, "utf8"));

  const apiHost = requireString(config, "apiHost");
  const sessionId = requireString(config, "sessionId");
  const cliToken = requireString(config, "cliToken");
  const proxyScriptPath = resolveAnyscaleProxyScript(config);
  const nodeExecutable = resolveNodeExecutable(config, proxyScriptPath);

  process.env.ANYSCALE_CLI_TOKEN = cliToken;
  if (config.headerHook) {
    process.env.ANYSCALE_SSH_HEADER_HOOK = config.headerHook;
  }

  console.error(`[shared-proxy ${SCRIPT_VERSION}] node=${nodeExecutable}`);
  console.error(`[shared-proxy ${SCRIPT_VERSION}] proxy=${proxyScriptPath}`);

  const child = spawn(nodeExecutable, [proxyScriptPath, websocketUrl, apiHost, sessionId], {
    stdio: "inherit",
    env: process.env,
  });

  child.on("exit", (code, signal) => {
    if (signal) {
      process.kill(process.pid, signal);
      return;
    }
    process.exit(code || 0);
  });

  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.on(signal, () => child.kill(signal));
  }
}

try {
  main();
} catch (error) {
  console.error("Failed to start shared proxy:", error && error.message ? error.message : error);
  process.exit(1);
}

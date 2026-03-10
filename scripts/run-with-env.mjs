#!/usr/bin/env node
import { spawn } from "node:child_process";

const args = process.argv.slice(2);

const env = { ...process.env };
let commandIndex = 0;

for (; commandIndex < args.length; commandIndex += 1) {
  const arg = args[commandIndex];
  if (!/^[A-Za-z_][A-Za-z0-9_]*=.*/.test(arg)) break;
  const equalsIndex = arg.indexOf("=");
  const key = arg.slice(0, equalsIndex);
  const value = arg.slice(equalsIndex + 1);
  env[key] = value;
}

const command = args[commandIndex];
if (!command) {
  console.error("run-with-env: missing command");
  process.exit(1);
}

const commandArgs = args.slice(commandIndex + 1);
const child = spawn(command, commandArgs, {
  stdio: "inherit",
  env,
  shell: process.platform === "win32",
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});

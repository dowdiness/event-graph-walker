#!/usr/bin/env node

import { readFileSync } from "node:fs";
import {
  checkoutSimpleString,
  createOpLog,
  localDelete,
  localInsert,
  mergeOplogInto,
} from "reference-frh";

const [tracePath] = process.argv.slice(2);
if (!tracePath) {
  throw new Error("usage: node reference_driver.mjs TRACE");
}

const replicas = new Map();
const replicaOrder = [];

function requiredReplica(name, lineNumber) {
  const replica = replicas.get(name);
  if (!replica) {
    throw new Error(`line ${lineNumber}: unknown replica ${name}`);
  }
  return replica;
}

function texts() {
  return replicaOrder.map((name) => checkoutSimpleString(replicas.get(name)));
}

function emit(step) {
  process.stdout.write(`${step}\t${texts().join("\t")}\n`);
}

const lines = readFileSync(tracePath, "utf8").split(/\r?\n/);
let step = 0;
for (let index = 0; index < lines.length; index += 1) {
  const line = lines[index].trim();
  if (line === "" || line.startsWith("#")) continue;
  const parts = line.split(/\s+/);
  const lineNumber = index + 1;
  switch (parts[0]) {
    case "replica": {
      const name = parts[1];
      if (!name || parts.length !== 2 || replicas.has(name)) {
        throw new Error(`line ${lineNumber}: invalid replica command`);
      }
      replicas.set(name, createOpLog());
      replicaOrder.push(name);
      break;
    }
    case "insert": {
      if (parts.length !== 4) {
        throw new Error(`line ${lineNumber}: invalid insert command`);
      }
      localInsert(
        requiredReplica(parts[1], lineNumber),
        parts[1],
        Number.parseInt(parts[2], 10),
        parts[3],
      );
      break;
    }
    case "delete": {
      if (parts.length !== 3) {
        throw new Error(`line ${lineNumber}: invalid delete command`);
      }
      localDelete(
        requiredReplica(parts[1], lineNumber),
        parts[1],
        Number.parseInt(parts[2], 10),
      );
      break;
    }
    case "sync":
    case "sync-duplicate": {
      if (parts.length !== 3) {
        throw new Error(`line ${lineNumber}: invalid sync command`);
      }
      mergeOplogInto(
        requiredReplica(parts[2], lineNumber),
        requiredReplica(parts[1], lineNumber),
      );
      break;
    }
    case "expect-converged": {
      if (parts.length < 3) {
        throw new Error(`line ${lineNumber}: invalid convergence command`);
      }
      const expected = checkoutSimpleString(requiredReplica(parts[1], lineNumber));
      for (const name of parts.slice(2)) {
        const actual = checkoutSimpleString(requiredReplica(name, lineNumber));
        if (actual !== expected) {
          throw new Error(
            `line ${lineNumber}: expected ${name} to converge to ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
          );
        }
      }
      break;
    }
    default:
      throw new Error(`line ${lineNumber}: unknown command ${parts[0]}`);
  }
  step += 1;
  emit(step);
}

#!/usr/bin/env node

import fs from "node:fs";
import { ListFugueSimple } from "./node_modules/reference-frh/dist/test/list-fugue-simple.js";

const args = process.argv.slice(2);
const inputPath = args.shift();
let limit;
let orderEmbedding = false;
while (args.length > 0) {
  const option = args.shift();
  if (option === "--limit") {
    limit = Number.parseInt(args.shift() ?? "", 10);
    if (!Number.isSafeInteger(limit) || limit < 1) {
      throw new Error("--limit requires a positive safe integer");
    }
  } else if (option === "--order-embedding") {
    orderEmbedding = true;
  } else {
    throw new Error(`unknown option: ${option}`);
  }
}
if (!inputPath) {
  throw new Error(
    "usage: node corpus_translate.mjs CONFORMANCE_JSON " +
    "[--limit N] [--order-embedding]",
  );
}

const corpus = JSON.parse(fs.readFileSync(inputPath, "utf8"));
const selected = limit === undefined ? corpus : corpus.slice(0, limit);

const rawId = (agent, sequence) => ({ replica_id: agent, sequence });
// Fixed-width UTF-16 code units preserve JavaScript lexical string order.
// The '-' terminator sorts before hex digits, preserving prefix ordering; the
// 16-digit suffix preserves numeric order for every non-negative safe integer.
const orderKey = (agent, sequence) => {
  if (typeof agent !== "string" || agent.length === 0) {
    throw new Error("operation agent must be a non-empty string");
  }
  if (!Number.isSafeInteger(sequence) || sequence < 0) {
    throw new Error(`invalid operation sequence: ${sequence}`);
  }
  let encodedAgent = "";
  for (let i = 0; i < agent.length; i += 1) {
    encodedAgent += agent.charCodeAt(i).toString(16).padStart(4, "0");
  }
  return `${encodedAgent}-${sequence.toString().padStart(16, "0")}`;
};
const moonId = (agent, sequence) => orderEmbedding
  ? rawId(orderKey(agent, sequence), 0)
  : rawId(agent, sequence);
const rawFromFugueId = (id) => id.sender === ""
  ? null
  : moonId(id.sender, id.counter);

function translateRun(run, runIndex) {
  const primitiveByLv = [];
  const rawByLv = [];
  const parentsByLv = [];
  const operations = [];
  const heads = new Set();

  const causalClosure = (frontier) => {
    const seen = new Set();
    const pending = [...frontier];
    while (pending.length > 0) {
      const lv = pending.pop();
      if (seen.has(lv)) continue;
      if (!Number.isSafeInteger(lv) || lv < 0 || lv >= primitiveByLv.length) {
        throw new Error(`run ${runIndex}: invalid parent LV ${lv}`);
      }
      seen.add(lv);
      pending.push(...parentsByLv[lv]);
    }
    return [...seen].sort((a, b) => a - b);
  };

  for (const txn of run.txns) {
    const [spanStart, spanEnd] = txn.span;
    if (spanStart !== primitiveByLv.length) {
      throw new Error(`run ${runIndex}: non-contiguous span starts at ${spanStart}`);
    }

    const branch = new ListFugueSimple("_translator_");
    for (const lv of causalClosure(txn.parents)) {
      branch.receivePrimitive(primitiveByLv[lv]);
    }

    let lv = spanStart;
    let sequence = txn.seqStart;
    for (const [initialPosition, deleteCount, insertContent] of txn.ops) {
      if ((deleteCount > 0) === (insertContent !== "")) {
        throw new Error(`run ${runIndex}: operation must insert or delete`);
      }
      if (deleteCount > 0) {
        for (let i = 0; i < deleteCount; i += 1) {
          branch.deleteOne(initialPosition);
          const primitive = branch.msgsInCausalOrder.at(-1);
          const parents = lv === spanStart ? txn.parents : [lv - 1];
          const target = rawFromFugueId(primitive.id);
          if (target === null) throw new Error(`run ${runIndex}: deleted sentinel`);
          primitiveByLv[lv] = primitive;
          rawByLv[lv] = moonId(txn.agent, sequence);
          parentsByLv[lv] = parents;
          operations.push({
            id: rawByLv[lv],
            parents: parents.map(parent => rawByLv[parent]),
            kind: "delete",
            content: null,
            origin_left: target,
            origin_right: null,
          });
          for (const parent of parents) heads.delete(parent);
          heads.add(lv);
          lv += 1;
          sequence += 1;
        }
      } else {
        let position = initialPosition;
        for (const content of insertContent) {
          branch.insertOneWithReplica(txn.agent, sequence, position, content);
          const primitive = branch.msgsInCausalOrder.at(-1);
          const parents = lv === spanStart ? txn.parents : [lv - 1];
          primitiveByLv[lv] = primitive;
          rawByLv[lv] = moonId(txn.agent, sequence);
          parentsByLv[lv] = parents;
          operations.push({
            id: rawByLv[lv],
            parents: parents.map(parent => rawByLv[parent]),
            kind: "insert",
            content,
            origin_left: rawFromFugueId(primitive.leftOrigin),
            origin_right: rawFromFugueId(primitive.rightOrigin),
          });
          for (const parent of parents) heads.delete(parent);
          heads.add(lv);
          lv += 1;
          sequence += 1;
          position += 1;
        }
      }
    }
    if (lv !== spanEnd) {
      throw new Error(`run ${runIndex}: span ended at ${spanEnd}, generated ${lv}`);
    }
  }

  const finalReference = new ListFugueSimple("_validator_");
  for (const primitive of primitiveByLv) finalReference.receivePrimitive(primitive);
  const translatedText = finalReference.toArray().join("");
  if (translatedText !== run.endContent) {
    throw new Error(
      `run ${runIndex}: Fugue translation produced ${JSON.stringify(translatedText)}, ` +
      `expected ${JSON.stringify(run.endContent)}`,
    );
  }

  return {
    expected: run.endContent,
    message: {
      schema: 1,
      format: "event-graph-walker/text-sync",
      operations,
      heads: [...heads].sort((a, b) => a - b).map(lv => rawByLv[lv]),
    },
  };
}

process.stdout.write(JSON.stringify(selected.map(translateRun)));

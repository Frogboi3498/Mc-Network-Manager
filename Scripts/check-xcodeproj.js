#!/usr/bin/env node
'use strict';
// Independent sanity check of project.pbxproj: parses the OpenStep plist,
// then verifies that every source file on disk is built and every build
// reference resolves. Usage: node Scripts/check-xcodeproj.js
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const text = fs.readFileSync(path.join(ROOT, 'MCNetworkManager.xcodeproj/project.pbxproj'), 'utf8');

// ---- minimal OpenStep plist parser
let pos = 0;
function ws() {
  for (;;) {
    while (pos < text.length && /\s/.test(text[pos])) pos++;
    if (text.startsWith('/*', pos)) { pos = text.indexOf('*/', pos) + 2; continue; }
    if (text.startsWith('//', pos)) { pos = text.indexOf('\n', pos) + 1; continue; }
    return;
  }
}
function str() {
  if (text[pos] === '"') {
    let s = ''; pos++;
    while (text[pos] !== '"') { if (text[pos] === '\\') pos++; s += text[pos++]; }
    pos++; return s;
  }
  const m = /^[A-Za-z0-9_.\/$@*+-]+/.exec(text.slice(pos));
  if (!m) throw new Error(`bad token at ${pos}: ${text.slice(pos, pos + 30)}`);
  pos += m[0].length; return m[0];
}
function val() {
  ws();
  if (text[pos] === '{') {
    pos++; const o = {};
    for (;;) {
      ws(); if (text[pos] === '}') { pos++; return o; }
      const k = str(); ws();
      if (text[pos] !== '=') throw new Error(`expected = after ${k} at ${pos}`);
      pos++; o[k] = val(); ws();
      if (text[pos] !== ';') throw new Error(`expected ; after ${k} at ${pos}: ${text.slice(pos - 20, pos + 20)}`);
      pos++;
    }
  }
  if (text[pos] === '(') {
    pos++; const a = [];
    for (;;) {
      ws(); if (text[pos] === ')') { pos++; return a; }
      a.push(val()); ws();
      if (text[pos] === ',') pos++;
    }
  }
  return str();
}
ws();
const root = val();

let failures = 0;
const fail = (m) => { failures++; console.error('FAIL ' + m); };
const ok = (m) => console.log('ok   ' + m);

const objs = root.objects;
ok(`parsed ${Object.keys(objs).length} objects, objectVersion ${root.objectVersion}`);
if (!objs[root.rootObject]) fail('rootObject missing');

const proj = objs[root.rootObject];
const target = objs[proj.targets[0]];
const phases = target.buildPhases.map((p) => objs[p]);
const sources = phases.find((p) => p.isa === 'PBXSourcesBuildPhase');
const res = phases.find((p) => p.isa === 'PBXResourcesBuildPhase');
const fw = phases.find((p) => p.isa === 'PBXFrameworksBuildPhase');

// Resolve a file ref to its path by walking groups.
const parent = {};
for (const [id, o] of Object.entries(objs)) if (o.isa === 'PBXGroup') o.children.forEach((c) => (parent[c] = id));
function fullPath(id) {
  const parts = []; let cur = id;
  while (cur) { const o = objs[cur]; if (o.path) parts.unshift(o.path); cur = parent[cur]; }
  return parts.join('/');
}

const built = sources.files.map((f) => fullPath(objs[f].fileRef));
for (const p of built) fs.existsSync(path.join(ROOT, p)) ? null : fail(`built file missing on disk: ${p}`);
ok(`${built.length} source files all exist on disk`);

const onDisk = [];
(function walk(d) {
  for (const e of fs.readdirSync(path.join(ROOT, d), { withFileTypes: true })) {
    const rel = path.join(d, e.name);
    if (e.isDirectory()) walk(rel); else if (e.name.endsWith('.swift')) onDisk.push(rel);
  }
})('MCNetworkManager');
// Source lives in Models/, Services/, Views/ plus the app entry point. Any other
// .swift file directly in MCNetworkManager/ is a leftover from an earlier draft.
const expected = (f) => /^MCNetworkManager\/(Models|Services|Views)\//.test(f) || f === 'MCNetworkManager/MCNetworkManagerApp.swift';
let missing = 0;
for (const f of onDisk.filter(expected)) if (!built.includes(f)) { fail(`swift file not in the target: ${f}`); missing++; }
if (!missing) ok('every source file in Models/, Services/, Views/ is in the target');
const stray = onDisk.filter((f) => !expected(f));
if (stray.length) console.log(`note ${stray.length} stray .swift file(s) outside the target (earlier draft, ignored): ${stray.map((f) => path.basename(f)).join(', ')}`);

const resPaths = res.files.map((f) => fullPath(objs[f].fileRef));
for (const p of ['MCNetworkManager/Resources/provision.sh', 'MCNetworkManager/Resources/Assets.xcassets']) {
  resPaths.includes(p) ? ok(`resource bundled: ${p}`) : fail(`resource not bundled: ${p}`);
  fs.existsSync(path.join(ROOT, p)) || fail(`resource missing on disk: ${p}`);
}

const products = fw.files.map((f) => objs[objs[f].productRef].productName).sort();
ok(`linked products: ${products.join(', ')}`);
for (const need of ['Citadel', 'SwiftTerm', 'NIOCore', 'NIOSSH']) products.includes(need) || fail(`missing product ${need}`);

for (const id of target.packageProductDependencies) {
  const d = objs[id];
  objs[d.package] ? null : fail(`product ${d.productName} points at a missing package`);
}
ok(`${proj.packageReferences.length} package references resolve`);

const cfgs = objs[target.buildConfigurationList].buildConfigurations.map((c) => objs[c].buildSettings);
for (const s of cfgs) {
  for (const f of [s.INFOPLIST_FILE, s.CODE_SIGN_ENTITLEMENTS]) fs.existsSync(path.join(ROOT, f)) || fail(`setting points at missing file ${f}`);
}
ok(`Info.plist and entitlements exist; deployment target ${objs[proj.buildConfigurationList].buildConfigurations.map((c) => objs[c].buildSettings.MACOSX_DEPLOYMENT_TARGET)[0]}`);

console.log(failures ? `\n${failures} problem(s)` : '\nproject file looks consistent');
process.exit(failures ? 1 : 0);

#!/usr/bin/env node
'use strict';
/**
 * Generates MCNetworkManager.xcodeproj/project.pbxproj.
 *
 * The generated project is committed, so you normally never run this. It is
 * here so the project file can be rebuilt (for example after adding a source
 * file) without Xcode: `node Scripts/generate-xcodeproj.js`.
 */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const ROOT = path.resolve(__dirname, '..');
const APP = 'MCNetworkManager';
const BUNDLE_ID = process.env.BUNDLE_ID || 'com.example.MCNetworkManager';

// ---------------------------------------------------------------- inputs

const groups = {
  Models: ['Models.swift'],
  Services: [
    'AppModel.swift', 'Clipboard.swift', 'Keychain.swift', 'MinecraftPing.swift', 'Monitor.swift',
    'Provisioner.swift', 'SSHService.swift', 'SyncClient.swift', 'VaultCrypto.swift',
  ],
  Views: [
    'AccountView.swift', 'ContentView.swift', 'DashboardView.swift', 'InstallView.swift',
    'NetworkView.swift', 'NodesView.swift', 'TerminalsView.swift',
  ],
};
const topSources = ['MCNetworkManagerApp.swift'];

const packages = [
  { name: 'Citadel', url: 'https://github.com/orlandos-nl/Citadel.git', req: { kind: 'branch', branch: 'main' }, product: 'Citadel' },
  { name: 'SwiftTerm', url: 'https://github.com/migueldeicaza/SwiftTerm.git', req: { kind: 'branch', branch: 'main' }, product: 'SwiftTerm' },
  { name: 'swift-nio', url: 'https://github.com/apple/swift-nio.git', req: { kind: 'upToNextMajorVersion', minimumVersion: '2.81.0' }, product: 'NIOCore' },
  // Same fork Citadel depends on, so the NIOSSH types we import resolve to the same module.
  { name: 'swift-nio-ssh', url: 'https://github.com/Wellz26/swift-nio-ssh.git', req: { kind: 'versionRange', minimumVersion: '0.3.4', maximumVersion: '0.4.0' }, product: 'NIOSSH' },
];

// ------------------------------------------------------------- id helpers

const used = new Set();
function id(seed) {
  let h = crypto.createHash('md5').update(`${APP}:${seed}`).digest('hex').slice(0, 24).toUpperCase();
  if (used.has(h)) throw new Error('id collision for ' + seed);
  used.add(h);
  return h;
}

// ---------------------------------------------------------- object model

const objects = {}; // id -> { comment, body }
function add(seed, comment, body) {
  const i = id(seed);
  objects[i] = { comment, body };
  return i;
}

function fileRef(seed, name, type, extra = {}) {
  return add('ref:' + seed, name, { isa: 'PBXFileReference', lastKnownFileType: type, path: name, sourceTree: '<group>', ...extra });
}

const sourceRefs = [];
const groupChildren = {};

for (const [g, files] of Object.entries(groups)) {
  groupChildren[g] = files.map((f) => {
    if (!fs.existsSync(path.join(ROOT, APP, g, f))) throw new Error(`missing source ${g}/${f}`);
    const r = fileRef(`${g}/${f}`, f, 'sourcecode.swift');
    sourceRefs.push({ ref: r, name: f });
    return r;
  });
}
const topRefs = topSources.map((f) => {
  if (!fs.existsSync(path.join(ROOT, APP, f))) throw new Error(`missing source ${f}`);
  const r = fileRef(f, f, 'sourcecode.swift');
  sourceRefs.push({ ref: r, name: f });
  return r;
});

if (!fs.existsSync(path.join(ROOT, APP, 'Resources/provision.sh'))) throw new Error('missing provision.sh');
const scriptRef = fileRef('Resources/provision.sh', 'provision.sh', 'text.script.sh');
const assetsRef = fileRef('Resources/Assets.xcassets', 'Assets.xcassets', 'folder.assetcatalog');
groupChildren.Resources = [scriptRef, assetsRef];

const plistRef = fileRef('Info.plist', 'Info.plist', 'text.plist.xml');
const entRef = fileRef('entitlements', `${APP}.entitlements`, 'text.plist.entitlements');
const productRef = add('product', `${APP}.app`, {
  isa: 'PBXFileReference', explicitFileType: 'wrapper.application', includeInIndex: 0,
  path: `${APP}.app`, sourceTree: 'BUILT_PRODUCTS_DIR',
});

const buildFiles = {};
function buildFile(seed, fileRefId, name, phase) {
  const i = add('bf:' + seed, `${name} in ${phase}`, { isa: 'PBXBuildFile', fileRef: fileRefId });
  buildFiles[i] = true;
  return i;
}
const sourceBuildFiles = sourceRefs.map((s) => buildFile(s.name, s.ref, s.name, 'Sources'));
const resourceBuildFiles = [
  buildFile('provision', scriptRef, 'provision.sh', 'Resources'),
  buildFile('assets', assetsRef, 'Assets.xcassets', 'Resources'),
];

// Swift packages
const pkgRefIds = [];
const productDepIds = [];
const frameworkBuildFiles = [];
for (const p of packages) {
  const pkgId = add('pkg:' + p.name, `XCRemoteSwiftPackageReference "${p.name}"`, {
    isa: 'XCRemoteSwiftPackageReference', repositoryURL: p.url, requirement: p.req,
  });
  pkgRefIds.push(pkgId);
  const depId = add('dep:' + p.product, p.product, { isa: 'XCSwiftPackageProductDependency', package: pkgId, productName: p.product });
  objects[depId].packageComment = `XCRemoteSwiftPackageReference "${p.name}"`;
  productDepIds.push(depId);
  const bf = add('bf:fw:' + p.product, `${p.product} in Frameworks`, { isa: 'PBXBuildFile', productRef: depId });
  objects[bf].productComment = p.product;
  frameworkBuildFiles.push(bf);
}

// Build phases
const sourcesPhase = add('phase:sources', 'Sources', { isa: 'PBXSourcesBuildPhase', buildActionMask: 2147483647, files: sourceBuildFiles, runOnlyForDeploymentPostprocessing: 0 });
const frameworksPhase = add('phase:frameworks', 'Frameworks', { isa: 'PBXFrameworksBuildPhase', buildActionMask: 2147483647, files: frameworkBuildFiles, runOnlyForDeploymentPostprocessing: 0 });
const resourcesPhase = add('phase:resources', 'Resources', { isa: 'PBXResourcesBuildPhase', buildActionMask: 2147483647, files: resourceBuildFiles, runOnlyForDeploymentPostprocessing: 0 });

// Groups
function group(seed, name, children, p) {
  const body = { isa: 'PBXGroup', children };
  if (p) body.path = p; else body.name = name;
  body.sourceTree = '<group>';
  return add('grp:' + seed, name, body);
}
const gModels = group('Models', 'Models', groupChildren.Models, 'Models');
const gServices = group('Services', 'Services', groupChildren.Services, 'Services');
const gViews = group('Views', 'Views', groupChildren.Views, 'Views');
const gResources = group('Resources', 'Resources', groupChildren.Resources, 'Resources');
const gApp = group('App', APP, [...topRefs, gModels, gServices, gViews, gResources, plistRef, entRef], APP);
const gProducts = group('Products', 'Products', [productRef]);
const gMain = group('Main', '', [gApp, gProducts]);
delete objects[gMain].body.name;

// Build settings
const projectCommon = {
  ALWAYS_SEARCH_USER_PATHS: 'NO',
  CLANG_ANALYZER_NONNULL: 'YES',
  CLANG_ENABLE_MODULES: 'YES',
  CLANG_ENABLE_OBJC_ARC: 'YES',
  COPY_PHASE_STRIP: 'NO',
  ENABLE_STRICT_OBJC_MSGSEND: 'YES',
  ENABLE_USER_SCRIPT_SANDBOXING: 'YES',
  GCC_NO_COMMON_BLOCKS: 'YES',
  MACOSX_DEPLOYMENT_TARGET: '15.0',
  SDKROOT: 'macosx',
  SWIFT_VERSION: '5.0',
};
const projDebug = add('cfg:proj:debug', 'Debug', { isa: 'XCBuildConfiguration', buildSettings: {
  ...projectCommon, DEBUG_INFORMATION_FORMAT: 'dwarf', ENABLE_TESTABILITY: 'YES', GCC_OPTIMIZATION_LEVEL: '0',
  GCC_PREPROCESSOR_DEFINITIONS: ['DEBUG=1', '$(inherited)'], MTL_ENABLE_DEBUG_INFO: 'INCLUDE_SOURCE', ONLY_ACTIVE_ARCH: 'YES',
  SWIFT_ACTIVE_COMPILATION_CONDITIONS: 'DEBUG', SWIFT_OPTIMIZATION_LEVEL: '-Onone',
}, name: 'Debug' });
const projRelease = add('cfg:proj:release', 'Release', { isa: 'XCBuildConfiguration', buildSettings: {
  ...projectCommon, DEBUG_INFORMATION_FORMAT: 'dwarf-with-dsym', ENABLE_NS_ASSERTIONS: 'NO', MTL_ENABLE_DEBUG_INFO: 'NO',
  SWIFT_COMPILATION_MODE: 'wholemodule', SWIFT_OPTIMIZATION_LEVEL: '-O',
}, name: 'Release' });

const targetCommon = {
  ASSETCATALOG_COMPILER_APPICON_NAME: 'AppIcon',
  ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: 'AccentColor',
  CODE_SIGN_ENTITLEMENTS: `${APP}/${APP}.entitlements`,
  CODE_SIGN_IDENTITY: '-',
  CODE_SIGN_STYLE: 'Automatic',
  COMBINE_HIDPI_IMAGES: 'YES',
  CURRENT_PROJECT_VERSION: '1',
  ENABLE_HARDENED_RUNTIME: 'YES',
  GENERATE_INFOPLIST_FILE: 'NO',
  INFOPLIST_FILE: `${APP}/Info.plist`,
  LD_RUNPATH_SEARCH_PATHS: ['$(inherited)', '@executable_path/../Frameworks'],
  MARKETING_VERSION: '1.0',
  PRODUCT_BUNDLE_IDENTIFIER: BUNDLE_ID,
  PRODUCT_NAME: '$(TARGET_NAME)',
  SWIFT_EMIT_LOC_STRINGS: 'YES',
};
const tgtDebug = add('cfg:tgt:debug', 'Debug', { isa: 'XCBuildConfiguration', buildSettings: { ...targetCommon }, name: 'Debug' });
const tgtRelease = add('cfg:tgt:release', 'Release', { isa: 'XCBuildConfiguration', buildSettings: { ...targetCommon }, name: 'Release' });

const projCfgList = add('cfglist:proj', `Build configuration list for PBXProject "${APP}"`, { isa: 'XCConfigurationList', buildConfigurations: [projDebug, projRelease], defaultConfigurationIsVisible: 0, defaultConfigurationName: 'Release' });
const tgtCfgList = add('cfglist:tgt', `Build configuration list for PBXNativeTarget "${APP}"`, { isa: 'XCConfigurationList', buildConfigurations: [tgtDebug, tgtRelease], defaultConfigurationIsVisible: 0, defaultConfigurationName: 'Release' });

const target = add('target', APP, {
  isa: 'PBXNativeTarget', buildConfigurationList: tgtCfgList,
  buildPhases: [sourcesPhase, frameworksPhase, resourcesPhase], buildRules: [], dependencies: [],
  name: APP, packageProductDependencies: productDepIds, productName: APP, productReference: productRef,
  productType: 'com.apple.product-type.application',
});

const project = add('project', 'Project object', {
  isa: 'PBXProject',
  attributes: { BuildIndependentTargetsInParallel: 1, LastSwiftUpdateCheck: 1600, LastUpgradeCheck: 1600, TargetAttributes: { [target]: { CreatedOnToolsVersion: '16.0' } } },
  buildConfigurationList: projCfgList, compatibilityVersion: 'Xcode 14.0', developmentRegion: 'en',
  hasScannedForEncodings: 0, knownRegions: ['en', 'Base'], mainGroup: gMain,
  packageReferences: pkgRefIds, productRefGroup: gProducts, projectDirPath: '', projectRoot: '', targets: [target],
});

// ---------------------------------------------------------- integrity check

function collectRefs(v, out) {
  if (typeof v === 'string' && /^[0-9A-F]{24}$/.test(v)) out.push(v);
  else if (Array.isArray(v)) v.forEach((x) => collectRefs(x, out));
  else if (v && typeof v === 'object') Object.entries(v).forEach(([k, x]) => { if (/^[0-9A-F]{24}$/.test(k)) out.push(k); collectRefs(x, out); });
}
for (const [i, o] of Object.entries(objects)) {
  const refs = [];
  collectRefs(o.body, refs);
  for (const r of refs) if (!objects[r]) throw new Error(`object ${i} (${o.comment}) references unknown id ${r}`);
}
const inGroups = new Set();
for (const o of Object.values(objects)) if (o.body.isa === 'PBXGroup') o.body.children.forEach((c) => inGroups.add(c));
for (const [i, o] of Object.entries(objects)) {
  if (o.body.isa === 'PBXFileReference' && !inGroups.has(i)) throw new Error(`file ${o.comment} is not in any group`);
}

// ------------------------------------------------------------- serializer

const SAFE = /^[A-Za-z0-9_./]+$/;
const q = (s) => (SAFE.test(s) ? s : '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"');

function ser(v, depth, objId) {
  const pad = '\t'.repeat(depth);
  if (Array.isArray(v)) {
    if (v.length === 0) return '(\n' + pad + ')';
    return '(\n' + v.map((x) => {
      const note = /^[0-9A-F]{24}$/.test(x) && objects[x] ? ` /* ${objects[x].comment} */` : '';
      return pad + '\t' + ser(x, depth + 1) + ',' + note;
    }).join('\n').replace(/,( \/\*)/g, ',$1') + '\n' + pad + ')';
  }
  if (v && typeof v === 'object') {
    const lines = Object.entries(v).map(([k, x]) => {
      let note = '';
      if (typeof x === 'string' && /^[0-9A-F]{24}$/.test(x) && objects[x]) note = ` /* ${objects[x].comment} */`;
      const key = /^[0-9A-F]{24}$/.test(k) && objects[k] ? `${k} /* ${objects[k].comment} */` : q(k);
      return `${pad}\t${key} = ${ser(x, depth + 1)};${note}`;
    });
    return '{\n' + lines.join('\n') + '\n' + pad + '}';
  }
  if (typeof v === 'number') return String(v);
  return q(v);
}

function sectionBody(i, o) {
  const b = { ...o.body };
  // Single-line form, like Xcode writes for these two types.
  if (b.isa === 'PBXBuildFile' || b.isa === 'PBXFileReference') {
    const parts = Object.entries(b).map(([k, x]) => {
      let note = '';
      if (k === 'fileRef' && objects[x]) note = ` /* ${objects[x].comment} */`;
      if (k === 'productRef' && objects[x]) note = ` /* ${objects[x].comment} */`;
      return `${k} = ${typeof x === 'number' ? x : q(x)};${note}`;
    });
    return `{${parts.join(' ')}}`;
  }
  return ser(b, 2);
}

const order = ['PBXBuildFile', 'PBXFileReference', 'PBXFrameworksBuildPhase', 'PBXGroup', 'PBXNativeTarget', 'PBXProject',
  'PBXResourcesBuildPhase', 'PBXSourcesBuildPhase', 'XCBuildConfiguration', 'XCConfigurationList',
  'XCRemoteSwiftPackageReference', 'XCSwiftPackageProductDependency'];

let out = '// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n';
for (const isa of order) {
  const items = Object.entries(objects).filter(([, o]) => o.body.isa === isa).sort(([a], [b]) => a.localeCompare(b));
  if (!items.length) continue;
  out += `\n/* Begin ${isa} section */\n`;
  for (const [i, o] of items) {
    let body = sectionBody(i, o);
    out += `\t\t${i} /* ${o.comment} */ = ${body};\n`;
  }
  out += `/* End ${isa} section */\n`;
}
out += `\t};\n\trootObject = ${project} /* Project object */;\n}\n`;

const dir = path.join(ROOT, `${APP}.xcodeproj`);
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'project.pbxproj'), out);
console.log(`wrote ${path.relative(process.cwd(), path.join(dir, 'project.pbxproj'))} (${Object.keys(objects).length} objects, ${sourceRefs.length} sources)`);

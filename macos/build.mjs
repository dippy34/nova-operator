import {execFileSync} from 'node:child_process';
import {mkdirSync,writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {resolve,join} from 'node:path';
import {paths as defaultPaths} from '../core/paths.mjs';
const xml=value=>value.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));

/// The signed configuration is how the native executor finds its key, nonces, Core and runtime.
/// It comes from the same shared paths as Core, the CLI and the login service.
export function infoPlist(paths=defaultPaths){
  return `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.nova.operator.macos</string><key>CFBundleExecutable</key><string>NovaOperator</string><key>CFBundleName</key><string>Nova Operator</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>0.2.0</string><key>NovaCoreDataDirectory</key><string>${xml(paths.data)}</string><key>NovaCoreRoot</key><string>${xml(paths.root)}</string><key>NovaNodePath</key><string>${xml(paths.runtime)}</string><key>LSUIElement</key><true/><key>NSScreenCaptureUsageDescription</key><string>Nova Operator captures the screen, or only the apps you chose for Nova, so Nova can see what it is doing.</string></dict></plist>`;
}

function build(paths=defaultPaths){
  if(paths.layout!=='development')throw new Error('npm run operator:build builds the development app from a source checkout.');
  const app=paths.operatorApp;
  mkdirSync(join(app,'Contents','MacOS'),{recursive:true});
  writeFileSync(join(app,'Contents','Info.plist'),infoPlist(paths));
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-O','-o',paths.operatorBinary,join(paths.root,'macos','Operator.swift')],{stdio:'inherit'});
  // Explicit identity is local configuration; no signing credentials enter Git.
  const identity=process.env.NOVA_MAC_SIGN_IDENTITY;
  if(!identity)throw new Error('Set NOVA_MAC_SIGN_IDENTITY to your local Apple Development or Developer ID identity');
  execFileSync('/usr/bin/codesign',['--force','--sign',identity,'--identifier','dev.nova.operator.macos',app],{stdio:'inherit'});
  console.log('Built and signed '+app);
}

if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href)build();

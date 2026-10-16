import {realpathSync,existsSync} from 'node:fs';
import {dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
export const sandboxBinary='/usr/bin/sandbox-exec';
const node=realpathSync(process.execPath),core=realpathSync(dirname(fileURLToPath(import.meta.url)));
const literal=value=>JSON.stringify(value);
// Verified on the target Mac, not a claim about future macOS releases. No fallback.
export const brainProfile=`(version 1)
(allow default)
(deny network*)
(deny mach-lookup)
(deny file-write*)
(deny file-read-data)
(allow file-read-data
 (literal "/")
 (literal ${literal(node)}) (subpath ${literal(core)})
 (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom")
 (subpath "/System") (subpath "/usr/lib") (subpath "/usr/share") (subpath "/usr/local/lib"))
(deny process-fork)
(deny process-exec)
(allow process-exec (literal ${literal(node)}))`;
export function workerLaunch() {
 if(process.platform!=='darwin'||!existsSync(sandboxBinary))throw new Error('The verified macOS Brain sandbox is unavailable. AI execution is disabled.');
 return {execPath:sandboxBinary,execArgv:['-p',brainProfile,node]};
}

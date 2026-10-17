// Remote access is private: Core listens on loopback only and Tailscale Serve publishes it
// to Matthew's own tailnet over HTTPS. Funnel (public internet) is never used.
import {execFile} from 'node:child_process';
import {existsSync} from 'node:fs';
import {promisify} from 'node:util';
import {paths} from './paths.mjs';

const execAsync=promisify(execFile);
// Without a terminal, Tailscale.app's binary starts its GUI instead of acting as the CLI.
const run=(binary,args,options)=>execAsync(binary,args,{...options,env:{...process.env,TAILSCALE_BE_CLI:'1'}});
const CANDIDATES=['/Applications/Tailscale.app/Contents/MacOS/Tailscale','/opt/homebrew/bin/tailscale','/usr/local/bin/tailscale'];
export const tailscaleBinary=()=>CANDIDATES.find(path=>existsSync(path))??null;

/// The HTTPS address that proxies to Core, from `tailscale serve status --json`.
export function serveURL(serve,port){
  for(const [host,site] of Object.entries(serve?.Web??{})){
    const proxies=Object.values(site?.Handlers??{}).map(h=>h?.Proxy);
    if(proxies.some(p=>p===`http://127.0.0.1:${port}`||p===`http://localhost:${port}`||p===String(port))){
      const [name,listen]=host.split(':');
      return `https://${name}${listen&&listen!=='443'?`:${listen}`:''}`;
    }
  }
  return null;
}

export async function tailscaleStatus(port=paths.port,{exec=run,binary=tailscaleBinary()}={}){
  if(!binary)return {installed:false,running:false,url:null,dnsName:null};
  const json=async args=>{try{return JSON.parse((await exec(binary,args,{timeout:5000})).stdout);}catch{return null;}};
  const [status,serve]=await Promise.all([json(['status','--json']),json(['serve','status','--json'])]);
  const running=status?.BackendState==='Running';
  return {installed:true,running,dnsName:status?.Self?.DNSName?.replace(/\.$/,'')??null,url:running?serveURL(serve,port):null,funnel:Boolean(serve?.AllowFunnel&&Object.values(serve.AllowFunnel).some(Boolean))};
}

/// Publishes Core to the tailnet only. Tailscale may ask to enable HTTPS for the tailnet first.
export async function enableServe(port=paths.port,{exec=run,binary=tailscaleBinary()}={}){
  if(!binary)throw new Error('Install Tailscale on this Mac first: https://tailscale.com/download/mac');
  try{await exec(binary,['serve','--bg','--https=443',`http://127.0.0.1:${port}`],{timeout:20000});}
  catch(error){
    const said=`${error.stdout??''}${error.stderr??''}`;
    const link=said.match(/https:\/\/login\.tailscale\.com\/\S+/)?.[0];
    throw new Error(link?`Tailscale needs HTTPS turned on for your network. Open ${link}, allow it, then try again.`:'Tailscale could not turn on private access. Open the Tailscale app, make sure you are signed in, and try again.');
  }
  return tailscaleStatus(port,{exec,binary});
}

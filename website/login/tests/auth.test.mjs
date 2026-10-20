import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {webcrypto} from 'node:crypto';
function harness(){
 const nodes=new Map([...readFileSync(new URL('../index.html',import.meta.url),'utf8').matchAll(/id="([^"]+)"/g)].map(x=>[x[1],{id:x[1],value:'',hidden:false,disabled:false,textContent:'button',dataset:{},handlers:{},attributes:{},setAttribute(k,v){this.attributes[k]=v},addEventListener(k,v){this.handlers[k]=v},focus(){},classList:{toggle(){}}}]));
 const calls=[],pending=[],intervals=[];let cookie='';const storage=new Map();
 const document={getElementById:id=>nodes.get(id),querySelectorAll:()=>[],documentElement:{dataset:{}},get cookie(){return cookie},set cookie(v){cookie=v}};
 const context={document,window:{crypto:webcrypto,addEventListener(){},matchMedia:()=>({matches:false,addEventListener(){}})},crypto:webcrypto,navigator:{userAgent:'fixture browser'},localStorage:{getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v)},sessionStorage:{getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)},setInterval:fn=>{intervals.push(fn);return intervals.length},clearInterval(){},setTimeout:()=>1,clearTimeout(){},Date,Uint8Array,TextEncoder,AbortController,DOMException,console,fetch:async(path,options)=>{calls.push({path,options,body:JSON.parse(options.body)});return new Promise(resolve=>pending.push((status,data)=>resolve({status,ok:status>=200&&status<300,text:async()=>JSON.stringify(data)})));}};
 vm.runInNewContext(readFileSync(new URL('../assets/auth.js',import.meta.url),'utf8'),context);
 return{nodes,calls,intervals,respond:(status,data)=>pending.shift()(status,data),async settle(){for(let i=0;i<50;i++)await Promise.resolve()}};
}
const submit=h=>h.nodes.get('form-code-email').handlers.submit({preventDefault(){}});
test('A delayed code request cannot replace a newly selected password view',async()=>{
 const h=harness();h.nodes.get('code-email').value='qa@example.test';submit(h);h.nodes.get('tab-password').handlers.click();h.respond(202,{challenge_id:'fixture'});await h.settle();assert.equal(h.nodes.get('form-password').hidden,false);assert.equal(h.nodes.get('form-code-verify').hidden,true);
});
test('Repeated resend clicks create only one in-flight email request',async()=>{
 const h=harness();h.nodes.get('code-email').value='qa@example.test';submit(h);h.respond(202,{challenge_id:'first'});await h.settle();h.nodes.get('btn-resend').disabled=false;
 h.nodes.get('btn-resend').handlers.click();h.nodes.get('btn-resend').handlers.click();assert.equal(h.calls.length,2);
});
test('Reset policy counts NFC code points, accepts 100 emoji and rejects blank phrases',async()=>{
 const h=harness();h.nodes.get('reset-email').value='qa@example.test';h.nodes.get('form-reset-email').handlers.submit({preventDefault(){}});h.respond(202,{challenge_id:'reset'});await h.settle();h.nodes.get('reset-code').value='12345678';h.nodes.get('reset-password').value=' '.repeat(20);h.nodes.get('form-reset-complete').handlers.submit({preventDefault(){}});assert.equal(h.calls.length,1);
 h.nodes.get('reset-password').value='😀'.repeat(100);h.nodes.get('form-reset-complete').handlers.submit({preventDefault(){}});assert.equal(h.calls.length,2);assert.equal(h.calls[1].body.new_password,'😀'.repeat(100));
});

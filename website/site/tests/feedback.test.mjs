import test from 'node:test';import assert from 'node:assert/strict';import vm from 'node:vm';import {readFileSync} from 'node:fs';import {randomUUID} from 'node:crypto';
test('Public feedback retries preserve key and draft but a changed body gets a new key',async()=>{
 const nodes=new Map(['feedback-form','fb-submit','fb-notice','fb-email','fb-subject','fb-body'].map(id=>[id,{value:'',disabled:false,textContent:'',handlers:{},addEventListener(k,fn){this.handlers[k]=fn},setAttribute(){},removeAttribute(){},reportValidity:()=>true,focus(){}}]));
 const calls=[];let attempts=0;
 const doc={documentElement:{dataset:{}},readyState:'complete',querySelector:()=>null,querySelectorAll:()=>[],getElementById:id=>nodes.get(id)};
 const context={document:doc,window:{matchMedia:()=>({matches:false,addEventListener(){}}),addEventListener(){},setTimeout:()=>1,clearTimeout(){},setInterval(){},requestAnimationFrame:fn=>fn()},localStorage:{getItem:()=>null},crypto:{randomUUID},AbortController,URL,console,fetch:async(path,options)=>{calls.push(options);attempts++;return{ok:false,status:503,headers:{get:()=>null},json:async()=>({})}}};
 vm.runInNewContext(readFileSync(new URL('../assets/site.js',import.meta.url),'utf8'),context);
 nodes.get('fb-body').value='这是需要保留的反馈内容';const submit=()=>nodes.get('feedback-form').handlers.submit({preventDefault(){}});const settle=async()=>{for(let i=0;i<50;i++)await Promise.resolve()};
 submit();await settle();submit();await settle();assert.equal(calls[0].headers['Idempotency-Key'],calls[1].headers['Idempotency-Key']);assert.equal(nodes.get('fb-body').value,'这是需要保留的反馈内容');
 nodes.get('fb-body').value='修改内容后应该使用不同的请求标识';submit();await settle();assert.notEqual(calls[1].headers['Idempotency-Key'],calls[2].headers['Idempotency-Key']);
});

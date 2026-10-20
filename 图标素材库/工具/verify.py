#!/usr/bin/env python3
"""Verify source, render, exports, shared native state, routes, archives and browser regressions."""
from pathlib import Path
from xml.etree import ElementTree as ET
from PIL import Image
import argparse, hashlib, json, os, re, shutil, subprocess, tempfile
from catalog import ICONS
from river_glyph import rect_closed, rect_open
from build import SIZES, VARIANTS, asset, png_path
from runtime import node,node_env
ROOT=Path(__file__).resolve().parents[1]
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,default=ROOT/'预览/验收证据');ap.add_argument('--project-root',type=Path,default=ROOT.parent);args=ap.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True);checks=[]
    def check(name,condition,detail=''):
        checks.append({'name':name,'pass':bool(condition),'detail':detail});print(('PASS ' if condition else 'FAIL ')+name+(' '+str(detail) if detail else ''),flush=True)
    manifest=json.loads((ROOT/'共享语义/manifest.json').read_text());ids=[g.id for g in ICONS]
    check('one shared family and 80 unique semantics',len(ids)==len(set(ids))==80 and manifest['rendering']=='original' and manifest['platforms']==['macOS','iOS'])
    bad=[]
    for state in VARIANTS:
        for gid in ids:
            p=ROOT/'SVG'/state/f'{gid}.svg'
            try:
                s=p.read_text();r=ET.fromstring(s)
                if r.get('viewBox')!='0 0 24 24' or 'NaN' in s or '<script' in s:bad.append(str(p))
            except Exception as e:bad.append(str(e))
    check('320 standalone SVGs parse',len(list((ROOT/'SVG').rglob('*.svg')))==320 and not bad,bad[:3])
    bad=[]
    for state in VARIANTS:
        for size in SIZES:
            for gid in ids:
                p=png_path(state,size,gid)
                try:
                    im=Image.open(p)
                    if im.size!=(size,size) or not im.convert('RGBA').getchannel('A').getbbox():bad.append(str(p))
                except Exception as e:bad.append(str(e))
    check('all PNG sizes and nonempty alpha',not bad,f'{len(VARIANTS)*len(SIZES)*80} PNG; '+str(bad[:3]))
    r=subprocess.run([node(),str(ROOT/'工具/verify_raster.cjs'),str(out/'raster-parity.json')],capture_output=True,text=True,env=node_env());check('320 SVGs rerender pixel-identically to PNG exports',r.returncode==0,r.stdout.strip())
    # Actual container path endpoints: round caps must leave a visible physical opening.
    gaps=[]
    for g in ICONS:
        if not g.water:continue
        d=g.parts[0].d;start=re.match(r'M([\d.]+) ([\d.]+)',d);end=re.search(r'L([\d.]+) ([\d.]+)$',d)
        gaps.append((g.id,abs(float(start[1])-float(end[1]))-1.95))
    check('all ten water mouths remain open after selected stroke',len(gaps)==10 and all(gap>=1.8 for _,gap in gaps),gaps)
    cat=ROOT/'原生资源包/RiverGlyph.xcassets';bad=[]
    for g in ICONS:
        for selected in (False,True):
            folder=cat/(asset(g.id,selected)+'.imageset');data=json.loads((folder/'Contents.json').read_text());entries=data['images']
            if len(entries)!=6 or data['properties']['template-rendering-intent']!='original':bad.append(str(folder))
            keys=[]
            for e in entries:
                dark=bool(e.get('appearances'));scale=int(e['scale'][0]);keys.append((dark,scale));state=('selected-dark' if dark else 'selected') if selected else ('dark' if dark else 'light')
                if (folder/e['filename']).read_bytes()!=png_path(state,32*scale,g.id).read_bytes():bad.append(str(folder/e['filename']))
            if len(set(keys))!=6:bad.append('duplicate appearance '+str(folder))
    check('160 shared imagesets include exact normal/selected and dark artwork',len(list(cat.glob('*.imageset')))==160 and not bad,bad[:3])
    unchanged=[]
    for g in ICONS:
        for normal,selected in [('light','selected'),('dark','selected-dark')]:
            a=Image.open(png_path(normal,64,g.id)).convert('RGBA').getchannel('A');b=Image.open(png_path(selected,64,g.id)).convert('RGBA').getchannel('A')
            # Filled-dot-only icons can convey selection through color and the parent state.
            if a.tobytes()==b.tobytes() and any(not part.fill for part in g.parts):unchanged.append((g.id,normal))
    check('selected geometry changes survive native resource packaging',not unchanged,unchanged)
    routes=json.loads((ROOT/'共享语义/routes.json').read_text());ios=(args.project_root/'ios/RiverDiary/RiverDiary/Views/IOSExperience.swift').read_text();mac=(args.project_root/'macos/RiverDiaryMac/Sources/RiverDiaryMac/Views/RiverShell.swift').read_text()
    def cases(text,enum):
        body=text.split('enum '+enum,1)[1].split('\n}',1)[0];return re.findall(r'^    case (\w+)\s*$',body,re.M)
    check('iOS route coverage matches actual five tabs',set(cases(ios,'RiverAppTab'))=={x['route'] for x in routes['iosPrimary']} and routes['iosPrimary'][0]['icon']=='today')
    check('macOS routes are complete and unambiguous',set(cases(mac,'RiverDestination'))==set(routes['macDestinations']) and routes['macDestinations']['timeline']=='footprints' and all(x in routes['macDestinations'] for x in routes['macPrimary']))
    appcat=ROOT/'原生资源包/RiverAppIcons-iOS.xcassets/AppIcon.appiconset';app=json.loads((appcat/'Contents.json').read_text())
    check('iOS app catalog includes a dedicated dark appearance',len(app['images'])==2 and any(e.get('appearances')==[{'appearance':'luminosity','value':'dark'}] and (appcat/e['filename']).exists() for e in app['images']))
    check('iOS app images are opaque 1024px',all(Image.open(appcat/e['filename']).size==(1024,1024) and Image.open(appcat/e['filename']).convert('RGBA').getchannel('A').getextrema()==(255,255) for e in app['images']))
    bad=[]
    for z in sorted((ROOT/'原生资源包').glob('*.zip')):
        with __import__('zipfile').ZipFile(z) as archive:
            if archive.testzip():bad.append(z.name+' CRC')
            for name in archive.namelist():
                if z.name.endswith('SVG.zip'):p=ROOT/name
                elif name.startswith('AppIcons/'):p=ROOT/'应用图标'/name.removeprefix('AppIcons/')
                elif name=='routes.json':p=ROOT/'共享语义/routes.json'
                else:p=ROOT/'原生资源包'/name
                if not p.exists() or p.read_bytes()!=archive.read(name):bad.append(z.name+':'+name)
    check('all four archives match current files byte-for-byte',len(list((ROOT/'原生资源包').glob('*.zip')))==4 and not bad,bad[:3])
    # Probe the reported clean-rebuild failure without deleting any delivery artifact.
    with tempfile.TemporaryDirectory(prefix='river-glyph-rebuild-') as tmp:
        clone=Path(tmp)/'icons';shutil.copytree(ROOT,clone,ignore=shutil.ignore_patterns('预览','__pycache__'))
        for z in (clone/'原生资源包').glob('*.zip'):z.unlink()
        r=subprocess.run([shutil.which('python3'),'工具/build.py','package'],cwd=clone,capture_output=True,text=True,env=node_env());(out/'package-rebuild.log').write_text(r.stdout+r.stderr)
        check('clean package rebuild regenerates four archives including SVG',r.returncode==0 and len(list((clone/'原生资源包').glob('*.zip')))==4)
    env=dict(os.environ);dev=Path.home()/'Downloads/Xcode-beta.app/Contents/Developer'
    if 'DEVELOPER_DIR' not in env and dev.exists():env['DEVELOPER_DIR']=str(dev)
    env.pop('SDKROOT',None)
    for platform,sdk,target in [('macOS','macosx','arm64-apple-macos14.0'),('iOS','iphonesimulator','arm64-apple-ios17.0-simulator')]:
        r=subprocess.run(['xcrun','--sdk',sdk,'swiftc','-typecheck','-target',target,'-module-cache-path',str(out/'swift-cache'),str(ROOT/'原生资源包/RiverGlyph.swift')],capture_output=True,text=True,env=env);(out/f'swift-{platform}.log').write_text(r.stdout+r.stderr);check(platform+' shared Swift typecheck',r.returncode==0,r.stderr[-200:])
        dest=out/('actool-'+platform);dest.mkdir(exist_ok=True);appcatalog=ROOT/f'原生资源包/RiverAppIcons-{platform}.xcassets'
        cmd=['xcrun','actool',str(cat),str(appcatalog),'--compile',str(dest),'--platform','macosx' if platform=='macOS' else 'iphoneos','--minimum-deployment-target','14.0' if platform=='macOS' else '17.0','--app-icon','AppIcon','--output-partial-info-plist',str(dest/'partial.plist')]
        if platform=='iOS':cmd+=['--target-device','iphone','--target-device','ipad']
        r=subprocess.run(cmd,capture_output=True,text=True,env=env);(out/f'actool-{platform}.log').write_text(r.stdout+r.stderr);check(platform+' catalog and AppIcon compile',r.returncode==0,r.stderr[-200:])
    (out/'geometry-fixtures.json').write_text(json.dumps({'closed':rect_closed(4,4,16,16,4)}))
    r=subprocess.run([node(),str(ROOT/'工具/verify_ui.cjs'),str(out)],capture_output=True,text=True,env=node_env());(out/'browser.log').write_text(r.stdout+r.stderr);check('browser geometry, states, namespaces and responsive regressions',r.returncode==0,r.stdout[-1000:] if r.returncode else '')
    (out/'result.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2))
    lines=['# River Glyph v2 · 验收记录','','统一图标家族，双端共用。日期：2026-10-19。','',f'结论：{sum(c["pass"] for c in checks)}/{len(checks)} 通过。','', '| 结果 | 检查 |','|---|---|']+[f'| {"通过" if c["pass"] else "失败"} | {c["name"]} |' for c in checks]+['','图录为设计场景，不是现有 App 截图。未自动替换 App 绑定；App 真机、VoiceOver 和点击区域需在接入后验证。']
    (ROOT/'预览/验收.md').write_text('\n'.join(lines)+'\n');return 0 if all(c['pass'] for c in checks) else 1
if __name__=='__main__':raise SystemExit(main())

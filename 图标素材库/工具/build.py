#!/usr/bin/env python3
"""Build one River Glyph family for both native platforms. No app files are changed."""
from pathlib import Path
import argparse, hashlib, json, shutil, subprocess, tempfile, zipfile
from catalog import ICONS
from river_glyph import PALETTES, WEIGHTS, render_svg
from build_app_icon import write_app_icons, write_macos_icns
from runtime import node, node_env
ROOT=Path(__file__).resolve().parents[1]
VARIANTS=('light','dark','selected','selected-dark')
# All required 16/18/20/24/28/32pt @1x/2x/3x. Native catalog uses 32pt.
SIZES=tuple(sorted({pt*scale for pt in (16,18,20,24,28,32) for scale in (1,2,3)}))
def dump(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def asset(gid,selected=False): return 'RiverGlyph'+''.join(p.capitalize() for p in gid.split('-'))+('Selected' if selected else '')
def swift_case(gid):
    first,*rest=gid.split('-');return first+''.join(x.capitalize() for x in rest)
def png_path(state,size,gid):return ROOT/'PNG'/state/f'{size}px'/f'{gid}.png'
def jobs():
    return [{'source':str(ROOT/'SVG'/state/f'{g.id}.svg'),'dest':str(png_path(state,size,g.id)),'size':size} for state in VARIANTS for g in ICONS for size in SIZES]
def build_svg():
    for state in VARIANTS:
        for g in ICONS:
            p=ROOT/'SVG'/state/f'{g.id}.svg';p.parent.mkdir(parents=True,exist_ok=True);p.write_text(render_svg(g,state)+'\n')
    categories=list(dict.fromkeys(g.category for g in ICONS))
    dump(ROOT/'共享语义/manifest.json',{'system':'River Glyph','version':'2.0.0','family':'河流 · Waterline','count':len(ICONS),'status':'shared assets ready; app binding pending','platforms':['macOS','iOS'],'rendering':'original','states':list(VARIANTS),'grid':{'viewBox':24,'stroke':WEIGHTS,'selectedStrokeIncrease':0.2,'mouthCenterlineGap':3.8,'waterRise':0.8},'pngPixels':SIZES,'catalogPointSize':32,'palettes':PALETTES,'categories':categories,'icons':[{'id':g.id,'label':g.label,'category':g.category,'water':bool(g.water),'asset':asset(g.id),'selectedAsset':asset(g.id,True),'svg':{s:f'SVG/{s}/{g.id}.svg' for s in VARIANTS}} for g in ICONS]})
    dump(ROOT/'共享语义/routes.json',{
        'iosPrimary':[{'route':r,'label':l,'icon':i} for r,l,i in [('timeline','今天','today'),('footprints','足迹','footprints'),('confirmations','待确认','confirmations'),('river','River','river'),('me','我的','profile')]],
        'macDestinations':{'today':'today','timeline':'footprints','confirmations':'confirmations','dailyReview':'review','habitReview':'habit','health':'health','footprints':'location','workLearn':'chapter','memory':'memory','ask':'river','progress':'progress','database':'database','sources':'source'},
        'macPrimary':['today','timeline','memory','ask','dailyReview'],
        'rule':'One route-to-icon map per platform. Primary order references that map; route names are taken from app enums.'})
    write_app_icons(ROOT)
    write_swift()
    print(f'SVG_READY {len(ICONS)*len(VARIANTS)}; one family, both platforms')
def render_png():
    tasks=jobs()
    for j in tasks:Path(j['dest']).parent.mkdir(parents=True,exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w',suffix='.json') as f:
        json.dump(tasks,f);f.flush();subprocess.run([node(),str(ROOT/'工具/render_png.cjs'),f.name],env=node_env(),check=True)
def content(folder,images,properties=None):
    data={'images':images,'info':{'author':'xcode','version':1}}
    if properties:data['properties']=properties
    dump(folder/'Contents.json',data)
def archive(dest,roots):
    with zipfile.ZipFile(dest,'w',zipfile.ZIP_DEFLATED) as z:
        for source,prefix in roots:
            paths=sorted(source.rglob('*')) if source.is_dir() else [source]
            for p in paths:
                if p.is_file() and p.name!='.DS_Store':z.write(p,str(Path(prefix)/p.relative_to(source)) if source.is_dir() else prefix)
def package():
    native=ROOT/'原生资源包';native.mkdir(exist_ok=True)
    cat=native/'RiverGlyph.xcassets'
    if cat.exists():shutil.rmtree(cat)
    dump(cat/'Contents.json',{'info':{'author':'xcode','version':1}})
    for g in ICONS:
        for selected in (False,True):
            folder=cat/(asset(g.id,selected)+'.imageset');folder.mkdir()
            images=[]
            for dark in (False,True):
                state=('selected-dark' if dark else 'selected') if selected else ('dark' if dark else 'light')
                for scale in (1,2,3):
                    fn=f'{g.id}{"-dark" if dark else ""}@{scale}x.png';shutil.copy2(png_path(state,32*scale,g.id),folder/fn)
                    e={'idiom':'universal','filename':fn,'scale':f'{scale}x'}
                    if dark:e['appearances']=[{'appearance':'luminosity','value':'dark'}]
                    images.append(e)
            content(folder,images,{'template-rendering-intent':'original'})
    write_macos_icns(ROOT)
    for platform in ('iOS','macOS'):
        catalog=native/f'RiverAppIcons-{platform}.xcassets'
        if catalog.exists():shutil.rmtree(catalog)
        dump(catalog/'Contents.json',{'info':{'author':'xcode','version':1}})
        folder=catalog/'AppIcon.appiconset';folder.mkdir()
        images=[]
        if platform=='iOS':
            for dark in (False,True):
                fn='AppIcon-dark.png' if dark else 'AppIcon.png';shutil.copy2(ROOT/'应用图标'/('ios-dark-1024.png' if dark else 'ios-1024.png'),folder/fn)
                e={'filename':fn,'idiom':'universal','platform':'ios','size':'1024x1024'}
                if dark:e['appearances']=[{'appearance':'luminosity','value':'dark'}]
                images.append(e)
        else:
            for size in (16,32,128,256,512):
                for scale in (1,2):
                    fn=f'icon_{size}x{size}{"@2x" if scale==2 else ""}.png';shutil.copy2(ROOT/'应用图标/RiverGlyph.iconset'/fn,folder/fn)
                    images.append({'filename':fn,'idiom':'mac','size':f'{size}x{size}','scale':f'{scale}x'})
        content(folder,images)
    common=[(cat,cat.name),(native/'RiverGlyph.swift','RiverGlyph.swift'),(native/'README.md','README.md'),(ROOT/'共享语义/routes.json','routes.json')]
    archive(native/'RiverGlyph-双端共享.zip',common)
    for platform in ('iOS','macOS'):
        catalog=native/f'RiverAppIcons-{platform}.xcassets'
        archive(native/f'RiverGlyph-{platform}-原生资源.zip',common+[(catalog,catalog.name),(ROOT/'应用图标','AppIcons')])
    archive(native/'RiverGlyph-SVG.zip',[(ROOT/'SVG','SVG'),(ROOT/'共享语义','共享语义'),(ROOT/'设计语言.md','设计语言.md'),(ROOT/'README.md','README.md')])
    dump(native/'checksums.json',{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(native.glob('*.zip'))})
    print('PACKAGED shared + iOS + macOS + SVG')
def write_swift():
    cases='\n'.join(f'    case {swift_case(g.id)} = "{g.id}"' for g in ICONS)
    source='''// Generated from 工具/catalog.py. Both targets import the same catalog and source.
import SwiftUI
public enum RiverGlyphName: String, CaseIterable, Identifiable {
CASES
    public var id: String { rawValue }
    public var assetName: String { "RiverGlyph" + rawValue.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() }
}
public struct RiverGlyphView: View {
    public enum State { case normal, selected }
    public let name: RiverGlyphName
    public var state: State
    public var size: CGFloat
    public init(_ name: RiverGlyphName, state: State = .normal, size: CGFloat = 20) {
        self.name = name; self.state = state; self.size = size
    }
    public var body: some View {
        Image(name.assetName + (state == .selected ? "Selected" : ""))
            .resizable().renderingMode(.original).interpolation(.high)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
'''.replace('CASES',cases)
    p=ROOT/'原生资源包/RiverGlyph.swift';p.parent.mkdir(exist_ok=True);p.write_text(source)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('stage',choices=('svg','png','package','all'),default='all',nargs='?');args=parser.parse_args()
    for stage,fn in [('svg',build_svg),('png',render_png),('package',package)]:
        if args.stage in (stage,'all'):fn()

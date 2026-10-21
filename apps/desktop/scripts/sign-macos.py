#!/usr/bin/env python3
"""Sign the new desktop bundle. Credentials come only from the invoking environment."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[3]
MACHO={b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xfe\xed\xfa\xce',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'}
def run(*args,**kwargs):return subprocess.run(args,check=True,**kwargs)
def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def notarize(path,receipt_path):
    args=['xcrun','notarytool','submit',str(path),'--wait','--timeout','10m','--output-format','json']
    profile=os.environ.get('NERO_NOTARY_PROFILE')
    if profile:args+=['--keychain-profile',profile]
    else:args+=['--key',os.environ['NERO_NOTARY_KEY_PATH'],'--key-id',os.environ['NERO_NOTARY_KEY_ID'],'--issuer',os.environ['NERO_NOTARY_ISSUER_ID']]
    print('Submitting '+path.name+' for notarization...',flush=True)
    result=json.loads(subprocess.check_output(args,text=True))
    receipt_path.write_text(json.dumps(result,indent=2)+'\n')
    if result.get('status')!='Accepted':raise SystemExit('Notarization not accepted. Preserve the upload and inspect its log.')
    return result
def tree(path):
    result={}
    for file in sorted(path.rglob('*')):
        name=str(file.relative_to(path))
        if file.is_symlink():result[name]={'link':os.readlink(file)}
        elif file.is_file():result[name]={'bytes':file.stat().st_size,'sha256':digest(file)}
    return result
def verify_dmg(path,app,require_ticket):
    run('hdiutil','verify',str(path))
    attached=plistlib.loads(subprocess.check_output(['hdiutil','attach','-readonly','-nobrowse','-noautoopen','-plist',str(path)]))
    devices=[entity['dev-entry'] for entity in attached['system-entities'] if 'dev-entry' in entity]
    try:
        mounted=[entity for entity in attached['system-entities'] if 'mount-point' in entity]
        if len(mounted)!=1:raise SystemExit('Expected one mounted disk image volume')
        volume=Path(mounted[0]['mount-point'])
        if not (volume/'Applications').is_symlink() or os.readlink(volume/'Applications')!='/Applications':raise SystemExit('Applications link missing or invalid')
        packaged=volume/'Nero.app'
        run('codesign','--verify','--deep','--strict',str(packaged))
        if require_ticket:run('xcrun','stapler','validate',str(packaged))
        if tree(app)!=tree(packaged):raise SystemExit('Packaged app differs from the signed source bundle')
        return {'readonly_mount_verified':True,'applications_link':'/Applications','embedded_app_matches_source':True}
    finally:
        if devices:run('hdiutil','detach',devices[0])
p=argparse.ArgumentParser();p.add_argument('--app',required=True,type=Path);p.add_argument('--output',required=True,type=Path);p.add_argument('--notarize',action='store_true');p.add_argument('--dmg-output',type=Path);p.add_argument('--dmg-builder',default='dmgbuild');p.add_argument('--dmg-only',action='store_true');a=p.parse_args()
app=a.app.resolve();output=a.output.resolve()
if app.suffix!='.app' or not (app/'Contents/Info.plist').is_file():raise SystemExit('A built .app is required')
if output.suffix!='.zip' or output.exists()!=a.dmg_only:raise SystemExit('Use a new ZIP output, or an existing verified ZIP with --dmg-only')
dmg=a.dmg_output.resolve() if a.dmg_output else None
if a.dmg_only and not dmg:raise SystemExit('--dmg-only requires --dmg-output')
if dmg and (dmg.suffix!='.dmg' or dmg.exists()):raise SystemExit('A new .dmg output path is required')
builder=shutil.which(a.dmg_builder) if dmg else None
if dmg and not builder:raise SystemExit('Install the dmgbuild build tool or pass --dmg-builder')
identity=os.environ['NERO_SIGN_IDENTITY']
identities=subprocess.check_output(['security','find-identity','-v','-p','codesigning'],text=True)
if not any(identity in line and 'Developer ID Application:' in line for line in identities.splitlines()):raise SystemExit('Valid Developer ID Application identity required')
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
if info.get('CFBundleName')!='Nero':raise SystemExit('Expected the new Nero bundle, not a legacy app')
build_info=json.loads((app/'Contents/Resources/build-info.json').read_text())
if build_info['sourceDirty']:raise SystemExit('Distribution requires a clean source commit')
packaging_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
if not a.dmg_only and build_info['sourceCommit']!=packaging_commit:raise SystemExit('Built source commit differs from HEAD')
if subprocess.check_output(['git','status','--porcelain','--untracked-files=normal'],cwd=ROOT,text=True).strip():raise SystemExit('Source changed after the release build')
if (build_info['version'],build_info['build'],build_info['bundleIdentifier'])!=(info['CFBundleShortVersionString'],info['CFBundleVersion'],info['CFBundleIdentifier']):raise SystemExit('Bundle and release metadata differ')
files=[p for p in (app/'Contents').rglob('*') if p.is_file()]
if any(p.suffix.lower() in {'.gguf','.safetensors','.p8','.p12','.wav','.m4a','.mp3'} for p in files):raise SystemExit('Private/model/credential artifact found in bundle')
if a.dmg_only:
    receipt=json.loads(Path(str(output)+'.receipt.json').read_text())
    expected=(build_info['sourceCommit'],info['CFBundleShortVersionString'],info['CFBundleVersion'],info['CFBundleIdentifier'])
    actual=(receipt.get('source_commit'),receipt.get('version'),receipt.get('build'),receipt.get('bundle_id'))
    if actual!=expected or not receipt.get('signed') or digest(output)!=receipt.get('zip_sha256'):raise SystemExit('Existing ZIP does not match its release receipt')
    if a.notarize and not receipt.get('notarized'):raise SystemExit('An already-notarized app ZIP is required')
    run('codesign','--verify','--deep','--strict',str(app))
    if a.notarize:run('xcrun','stapler','validate',str(app))
    with tempfile.TemporaryDirectory(dir=app.parent) as temporary:
        run('ditto','-x','-k',str(output),temporary)
        if tree(app)!=tree(Path(temporary)/app.name):raise SystemExit('App differs from the preserved ZIP')
else:
    for file in files:
        with file.open('rb') as f:magic=f.read(4)
        if magic in MACHO:
            run('codesign','--force','--options','runtime','--timestamp','--sign',identity,str(file))
    for bundle in sorted((p for p in (app/'Contents').rglob('*.bundle') if p.is_dir()),key=lambda p:len(p.parts),reverse=True):
        run('codesign','--force','--options','runtime','--timestamp','--sign',identity,str(bundle))
    run('codesign','--force','--options','runtime','--timestamp','--sign',identity,'--entitlements',str(ROOT/'apps/desktop/src-tauri/Nero.entitlements'),str(app))
    run('codesign','--verify','--deep','--strict',str(app))
    output.parent.mkdir(parents=True,exist_ok=True)
    upload=output.with_suffix('.notary-upload.zip')
    if upload.exists():raise SystemExit('Notary upload path exists; preserve or move it first')
    run('ditto','-c','-k','--keepParent',str(app),str(upload))
    receipt={'bundle_id':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'source_commit':build_info['sourceCommit'],'source_tree':build_info['sourceTree'],'source_dirty':False,'architecture':subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS'/info['CFBundleExecutable'])],text=True).strip(),'signed':True,'notarized':False}
    if a.notarize:
        receipt['notary']=notarize(upload,Path(str(output)+'.notarization.json'))
        run('xcrun','stapler','staple',str(app));run('xcrun','stapler','validate',str(app));run('spctl','--assess','--type','execute','--verbose=2',str(app));receipt['notarized']=True
    run('ditto','-c','-k','--keepParent',str(app),str(output))
    receipt.update(zip_bytes=output.stat().st_size,zip_sha256=digest(output))
    Path(str(output)+'.receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('Created:',output,flush=True)
if dmg:
    dmg.parent.mkdir(parents=True,exist_ok=True)
    run(builder,'-s',str(ROOT/'apps/desktop/scripts/dmg-settings.py'),'-Dapp='+str(app),'Nero',str(dmg))
    run('codesign','--force','--timestamp','--sign',identity,'--identifier',info['CFBundleIdentifier']+'.diskimage',str(dmg))
    run('codesign','--verify','--strict',str(dmg))
    dmg_receipt={key:value for key,value in receipt.items() if key not in {'notary','zip_bytes','zip_sha256'}}
    dmg_receipt['notarized']=False
    dmg_receipt['packaging_commit']=packaging_commit
    verify_dmg(dmg,app,a.notarize)
    if a.notarize:
        dmg_receipt['notary']=notarize(dmg,Path(str(dmg)+'.notarization.json'))
        run('xcrun','stapler','staple',str(dmg));run('xcrun','stapler','validate',str(dmg))
        run('spctl','--assess','--type','open','--context','context:primary-signature','--verbose=2',str(dmg))
        dmg_receipt['notarized']=True
    dmg_receipt['verification']=verify_dmg(dmg,app,a.notarize)
    dmg_receipt.update(dmg_bytes=dmg.stat().st_size,dmg_sha256=digest(dmg),app_notary=receipt.get('notary'))
    Path(str(dmg)+'.receipt.json').write_text(json.dumps(dmg_receipt,indent=2)+'\n')
    print('Created:',dmg,flush=True)

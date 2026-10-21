#!/usr/bin/env python3
"""Build-time only: pin, verify and bundle native llama.cpp. Never fetch model weights."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT=Path(__file__).resolve().parents[2]
SPEC=json.loads(Path(__file__).with_name('runtime.json').read_text())

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for data in iter(lambda:f.read(1024*1024),b''):h.update(data)
    return h.hexdigest()

def windows_crt(explicit):
    if explicit is not None: roots=[explicit]
    elif os.environ.get('VCToolsRedistDir'): roots=[Path(os.environ['VCToolsRedistDir'])]
    elif os.name=='nt':
        locator=Path(os.environ.get('ProgramFiles(x86)','C:/Program Files (x86)'))/'Microsoft Visual Studio/Installer/vswhere.exe'
        installation=subprocess.check_output([str(locator),'-latest','-products','*','-property','installationPath'],text=True).strip()
        roots=sorted((Path(installation)/'VC/Redist/MSVC').glob('*'),reverse=True)
    else: raise ValueError('Windows packaging requires --msvc-redist from a licensed Windows build toolchain')
    required={'msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll'}
    for root in roots:
        candidates=[root]+list(root.glob('x64/Microsoft.VC*.CRT'))
        for folder in candidates:
            files={p.name.lower():p for p in folder.glob('*.dll')}
            if required<=files.keys():return files
    raise ValueError('App-local Microsoft C++ runtime DLLs are missing; do not ship this bundle')

def prepare(target, cache, output, redist=None):
    crt=windows_crt(redist) if target.startswith('windows') else {}
    cache.mkdir(parents=True,exist_ok=True)
    if output.exists():
        raise SystemExit('Destination exists; use a new destination. Existing workers are never replaced.')
    output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='summary-',dir=output.parent) as temporary:
        stage=Path(temporary)/'summary';stage.mkdir()
        for item in SPEC['assets'][target]:
            archive=cache/item['name']
            if not archive.is_file() or archive.stat().st_size!=item['bytes'] or sha(archive)!=item['sha256']:
                partial=cache/(item['name']+'.part')
                request=urllib.request.Request(f"https://github.com/{SPEC['repository']}/releases/download/{SPEC['version']}/{item['name']}",headers={'User-Agent':'Nero-build'})
                with urllib.request.urlopen(request,timeout=60) as r,partial.open('wb') as f:
                    total=0
                    while data:=r.read(1024*1024):
                        total+=len(data)
                        if total>item['bytes']:raise ValueError('Runtime archive exceeded pinned size')
                        f.write(data)
                if partial.stat().st_size!=item['bytes'] or sha(partial)!=item['sha256']:raise ValueError('Runtime archive checksum mismatch')
                partial.replace(archive)
            destination=stage/item['backend'];destination.mkdir()
            # Flatten only runtime files, rejecting duplicate names and archive links.
            def write(name,data):
                base=Path(name).name
                wanted=base in ('llama-server','llama-server.exe') or base.endswith(('.dylib','.dll','.metallib','.metal')) or base.upper().startswith(('LICENSE','COPYING'))
                if not wanted:return
                path=destination/base
                if path.exists():raise ValueError('Duplicate runtime file: '+base)
                with path.open('xb') as f:shutil.copyfileobj(data,f)
                if base=='llama-server':path.chmod(0o755)
            if archive.suffix=='.zip':
                with zipfile.ZipFile(archive) as z:
                    for info in z.infolist():
                        if info.is_dir():continue
                        if (info.external_attr>>16)&0o170000==0o120000:raise ValueError('Linked archive entry')
                        with z.open(info) as f:write(info.filename,f)
            else:
                with tarfile.open(archive) as t:
                    for info in t:
                        # Official macOS tar contains dylib aliases: preserve their bytes under each alias.
                        if info.isfile() or info.issym() or info.islnk():
                            f=t.extractfile(info)
                            if f is not None:
                                with f:write(info.name,f)
            for name,source in crt.items():
                shutil.copyfile(source,destination/name)
            binary=destination/('llama-server.exe' if target.startswith('windows') else 'llama-server')
            if not binary.is_file():raise ValueError('Missing llama-server')
        license_url=f"https://raw.githubusercontent.com/{SPEC['repository']}/{SPEC['commit']}/LICENSE"
        with urllib.request.urlopen(license_url,timeout=30) as r:(stage/'LICENSE-llama.cpp.txt').write_bytes(r.read(65536))
        receipt={'target':target,'runtime':SPEC,'source_archive_hashes_verified':True,'file_hash_scope':'before Developer ID code signing','files':[{'path':str(p.relative_to(stage)),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(stage.rglob('*')) if p.is_file()]}
        (stage/'runtime.json').write_text(json.dumps(receipt,indent=2)+'\n')
        os.rename(stage,output)
    print('Prepared native summary runtime:',target)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--target',required=True,choices=SPEC['assets']);p.add_argument('--msvc-redist',type=Path);p.add_argument('--cache',type=Path,default=ROOT/'.work/summary-runtime-downloads');p.add_argument('--output',type=Path,default=ROOT/'apps/desktop/.generated/native/summary');a=p.parse_args();prepare(a.target,a.cache,a.output,a.msvc_redist)

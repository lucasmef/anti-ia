#!/usr/bin/env python3
"""Run the app's scanner, then apply a recorded move plan without overwriting files."""
import argparse
import concurrent.futures
import ctypes
import json
import os
from pathlib import Path
import stat
import subprocess
import time
from collections import Counter

def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')

def fingerprint(path):
    s = path.lstat()
    if not stat.S_ISREG(s.st_mode):
        raise ValueError('Not a regular file: '+str(path))
    return dict(device=s.st_dev, inode=s.st_ino, size=s.st_size, mtime_ns=s.st_mtime_ns)

def walk(root):
    files, skipped = [], []
    for parent, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d != 'alerta de ia' and not d.startswith('relatorio-ia-') and not Path(parent,d).is_symlink())
        for name in sorted(names):
            p = Path(parent,name)
            if name == '.DS_Store' or p.is_symlink():
                skipped.append(str(p.relative_to(root))); continue
            files.append({'path': str(p.relative_to(root)), 'snapshot': fingerprint(p)})
    return files, skipped

def analyze(app, root, entries):
    paths = [str(root/e['path']) for e in entries]
    try:
        output = subprocess.run([str(app),'--scan',*paths], capture_output=True, timeout=60, check=True)
        reports = json.loads(output.stdout)
        if len(reports) != len(entries): raise ValueError('Wrong report count')
        results = []
        for entry, report in zip(entries,reports):
            if report['file'] != Path(entry['path']).name: raise ValueError('Wrong filename returned')
            result = dict(entry, report=report)
            if fingerprint(root/entry['path']) != entry['snapshot']:
                result['report']['status'] = 'inconclusive'
                result['report']['warnings'].append('Arquivo alterado durante a leitura; não será movido.')
            results.append(result)
        return results
    except Exception as error:
        if len(entries)>1:
            # Isolate any corrupt file or native decoder failure.
            return [result for entry in entries for result in analyze(app,root,[entry])]
        return [dict(entries[0], report={'status':'inconclusive','evidence':[], 'warnings':['Falha do processo de leitura: '+str(error)[:500]]})]

def scan(root, run, app):
    run.mkdir(parents=True, exist_ok=False)
    started = time.time()
    entries, skipped = walk(root)
    write_json(run/'inventory.json', {'root':str(root),'entries':entries,'skipped':skipped,'app':str(app)})
    counts, warnings, by_extension = Counter(), Counter(), {}
    plan, done = [], 0
    batches = [entries[i:i+32] for i in range(0,len(entries),32)]
    with (run/'results.jsonl').open('w') as output, concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(analyze,app,root,batch) for batch in batches]
        for future in concurrent.futures.as_completed(futures):
            for result in future.result():
                output.write(json.dumps(result,ensure_ascii=False)+'\n')
                report = result['report']; status = report['status']; counts[status]+=1
                suffix = Path(result['path']).suffix.lower()
                by_extension.setdefault(suffix,Counter())[status]+=1
                warnings.update(report.get('warnings',[]))
                if status == 'ai_declared' and any(e['kind']=='ai_source' for e in report.get('evidence',[])):
                    plan.append(result)
                done += 1
            output.flush()
            if done%512 < 32 or done == len(entries):
                print(json.dumps({'done':done,'total':len(entries),'counts':counts,'seconds':round(time.time()-started,1)}),flush=True)
    plan.sort(key=lambda item:item['path'])
    write_json(run/'move-plan.json', {'root':str(root),'destination':'alerta de ia','entries':plan})
    summary = {'root':str(root),'scanned':done,'skipped':skipped,'counts':counts,'by_extension':by_extension,'warnings':warnings,'selected':len(plan),'selected_bytes':sum(e['snapshot']['size'] for e in plan),'seconds':round(time.time()-started,1)}
    write_json(run/'summary.json',summary)
    print(json.dumps(summary,ensure_ascii=False),flush=True)

def safe_child(root, relative):
    rel = Path(relative)
    if rel.is_absolute() or '..' in rel.parts or not rel.parts:
        raise ValueError('Unsafe relative path')
    child = root/rel
    for parent in [child,*child.parents]:
        if parent == root: break
        if parent.is_symlink(): raise ValueError('Symlink in path: '+str(parent))
    return child

def move(root, run):
    plan = json.loads((run/'move-plan.json').read_text())
    if plan['root'] != str(root) or plan['destination'] != 'alerta de ia': raise ValueError('Unexpected root or destination')
    destination = safe_child(root,'alerta de ia')
    entries = plan['entries']
    # Check every planned move before mutating anything.
    for entry in entries:
        if entry['report']['status'] != 'ai_declared' or not any(e['kind']=='ai_source' for e in entry['report']['evidence']):
            raise ValueError('Move plan contains a file without explicit AI evidence')
        src = safe_child(root,entry['path']); dst = safe_child(destination,entry['path'])
        if dst.exists(): raise FileExistsError(str(dst))
        if fingerprint(src) != entry['snapshot']: raise ValueError('Source changed: '+str(src))
    libc = ctypes.CDLL(None,use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];rename.restype=ctypes.c_int
    destination.mkdir(exist_ok=True)
    moved = 0
    with (run/'moves.jsonl').open('a') as journal:
        for entry in entries:
            src = safe_child(root,entry['path']); dst = safe_child(destination,entry['path'])
            dst.parent.mkdir(parents=True,exist_ok=True)
            if fingerprint(src) != entry['snapshot']: raise ValueError('Source changed before move: '+str(src))
            intent = {'source':str(src),'destination':str(dst),'snapshot':entry['snapshot'],'state':'prepared'}
            journal.write(json.dumps(intent,ensure_ascii=False)+'\n');journal.flush();os.fsync(journal.fileno())
            # RENAME_EXCL is atomic on macOS and fails if destination exists.
            if rename(os.fsencode(src),os.fsencode(dst),4):
                raise OSError(ctypes.get_errno(),os.strerror(ctypes.get_errno()),str(src))
            if src.exists() or fingerprint(dst) != entry['snapshot']: raise ValueError('Post-move verification failed')
            intent['state']='moved';journal.write(json.dumps(intent,ensure_ascii=False)+'\n');journal.flush()
            moved+=1
            if moved%500 == 0: print(json.dumps({'moved':moved,'total':len(entries)}),flush=True)
        os.fsync(journal.fileno())
    for entry in entries:
        if safe_child(root,entry['path']).exists() or fingerprint(safe_child(destination,entry['path'])) != entry['snapshot']:
            raise ValueError('Final verification failed: '+entry['path'])
    write_json(run/'move-summary.json',{'moved':moved,'destination':str(destination),'verified':True})
    print(json.dumps({'moved':moved,'destination':str(destination),'verified':True}),flush=True)

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('mode',choices=['scan','move']);parser.add_argument('root',type=Path);parser.add_argument('run',type=Path)
    parser.add_argument('--app',type=Path,default=Path(__file__).parent/'Sinal IA.app/Contents/MacOS/SinalIA')
    args=parser.parse_args()
    root=args.root.resolve();run=args.run.resolve()
    if args.mode=='scan': scan(root,run,args.app.resolve())
    else: move(root,run)

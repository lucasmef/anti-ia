#!/usr/bin/env python3
"""Lossless, staged cleanup for the PNG/JPEG files selected by Sinal IA.

Prepare and inspect ALL outputs before commit. Commit swaps files atomically,
keeps originals in staging until every replacement passes verification, then
deletes those originals only with an explicit --delete-originals argument.
"""
import argparse
import concurrent.futures
import ctypes
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import time
import xml.etree.ElementTree as ET
import zlib

import batch_scan

LIB = ctypes.CDLL(None, use_errno=True)
LIB.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
LIB.listxattr.restype = ctypes.c_ssize_t
LIB.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
LIB.getxattr.restype = ctypes.c_ssize_t
LIB.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
LIB.setxattr.restype = ctypes.c_int
LIB.copyfile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
LIB.copyfile.restype = ctypes.c_int
LIB.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
LIB.renamex_np.restype = ctypes.c_int
LIB.getattrlist.argtypes = [ctypes.c_char_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_ulong]
LIB.getattrlist.restype = ctypes.c_int
LIB.setattrlist.argtypes = [ctypes.c_char_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_ulong]
LIB.setattrlist.restype = ctypes.c_int
IGNORED_XATTRS = {'com.apple.decmpfs'}  # filesystem compression, not user metadata
TAG = 'com.apple.metadata:_kMDItemUserTags'
XMP_PREFIX = b'http://ns.adobe.com/xap/1.0/\0'
IPTC = 'http://iptc.org/std/Iptc4xmpExt/2008-02-29/'
AI_TYPES = {'trainedAlgorithmicMedia', 'compositeWithTrainedAlgorithmicMedia', 'compositeSynthetic'}
C2PA_UUID = bytes.fromhex('6332706100110010800000aa00389b71')

def check(result):
    if result < 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    return result

def digest(data):
    return hashlib.sha256(data).hexdigest()

def file_hash(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        while True:
            part=f.read(4*1024*1024)
            if not part:break
            h.update(part)
    return h.hexdigest()

def xattrs(path):
    raw=os.fsencode(path)
    size=check(LIB.listxattr(raw,None,0,0)); buf=ctypes.create_string_buffer(size)
    n=check(LIB.listxattr(raw,buf,size,0))
    result={}
    for name in buf.raw[:n].rstrip(b'\0').split(b'\0') if n else []:
        if name.decode() in IGNORED_XATTRS:continue
        count=check(LIB.getxattr(raw,name,None,0,0,0))
        if count > 32*1024*1024:raise ValueError('Unexpectedly large extended attribute')
        value=ctypes.create_string_buffer(count)
        length=check(LIB.getxattr(raw,name,value,count,0,0))
        result[name.decode()]=value.raw[:length]
    return result

def metadata(path):
    s=path.stat()
    return {'xattrs':{k:digest(v) for k,v in xattrs(path).items()},
            'mode':stat.S_IMODE(s.st_mode),'uid':s.st_uid,'gid':s.st_gid,
            'mtime_ns':s.st_mtime_ns,'birthtime_ns':birthtime(path),
            'flags':s.st_flags & ~0x20}

def birthtime(path, value=None):
    attributes=ctypes.create_string_buffer(struct.pack('<HHIIIII',5,0,0x200,0,0,0,0))
    if value is None:
        output=ctypes.create_string_buffer(32)
        check(LIB.getattrlist(os.fsencode(path),attributes,output,32,1))
        seconds,nanos=struct.unpack_from('<qq',output.raw,4)
        return seconds*1_000_000_000+nanos
    data=ctypes.create_string_buffer(struct.pack('<qq',value//1_000_000_000,value%1_000_000_000))
    check(LIB.setattrlist(os.fsencode(path),attributes,data,16,1))

def preserve_metadata(source,destination):
    expected=xattrs(source)
    check(LIB.copyfile(os.fsencode(source),os.fsencode(destination),None,7)) # ACL, STAT, XATTR
    current=xattrs(destination)
    for name,value in expected.items():
        if current.get(name)!=value:
            buf=ctypes.create_string_buffer(value)
            check(LIB.setxattr(os.fsencode(destination),name.encode(),buf,len(value),0,0))
    birthtime(destination,birthtime(source))
    if metadata(source)!=metadata(destination):
        raise ValueError('macOS metadata mismatch: '+str(source))

def is_ai(value):
    return any(value == base+term for base in ['http://cv.iptc.org/newscodes/digitalsourcetype/','https://cv.iptc.org/newscodes/digitalsourcetype/'] for term in AI_TYPES)

def clean_xmp(packet):
    for prefix,uri in [('x','adobe:ns:meta/'),('rdf','http://www.w3.org/1999/02/22-rdf-syntax-ns#'),('Iptc4xmpExt',IPTC)]:
        ET.register_namespace(prefix,uri)
    root=ET.fromstring(packet.rstrip(b'\0'))
    keys={f'{{{IPTC}}}DigitalSourceType',f'{{{IPTC}}}DigitalSourcefileType'}
    removed=0
    for element in root.iter():
        for key,value in list(element.attrib.items()):
            if key in keys and is_ai(value.strip()):del element.attrib[key];removed+=1
        for child in list(element):
            value=(child.text or child.attrib.get('{http://www.w3.org/1999/02/22-rdf-syntax-ns#}resource','')).strip()
            if child.tag in keys and is_ai(value):element.remove(child);removed+=1
    return (ET.tostring(root,encoding='utf-8') if removed else packet),removed

def clean_png(data):
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):raise ValueError('Invalid PNG signature')
    pos=8;parts=[data[:8]];removed=0;saw_end=False
    while pos<len(data):
        if len(data)-pos<12:raise ValueError('Truncated PNG')
        length=struct.unpack_from('>I',data,pos)[0];end=pos+12+length
        if end>len(data):raise ValueError('Truncated PNG chunk')
        kind=data[pos+4:pos+8];body=data[pos+8:end-4]
        if zlib.crc32(data[pos+4:end-4]) != struct.unpack_from('>I',data,end-4)[0]:raise ValueError('PNG CRC mismatch')
        if kind==b'caBX':
            if len(body)<33 or body[4:8]!=b'jumb' or body[12:16]!=b'jumd' or body[16:32]!=C2PA_UUID:
                raise ValueError('Unknown caBX payload; original preserved')
            removed+=1
        else:parts.append(data[pos:end])
        pos=end
        if kind==b'IEND':saw_end=True;break
    if not saw_end or pos!=len(data):raise ValueError('PNG trailing data or missing IEND')
    # Every byte outside the C2PA chunks is retained, including ICC, EXIF,
    # dimensions, alpha, all compressed pixel data and animation chunks.
    output=b''.join(parts)
    return output,{'c2pa_chunks_removed':removed,'image_and_other_metadata_sha256':digest(output)}

def clean_jpeg(data):
    if not data.startswith(b'\xff\xd8'):raise ValueError('Invalid JPEG signature')
    pos=2;parts=[data[:2]];render=[data[:2]];removed=0;saw_scan=False
    while pos<len(data):
        start=pos
        if data[pos]!=255:raise ValueError('Invalid JPEG marker')
        while pos<len(data) and data[pos]==255:pos+=1
        if pos>=len(data):raise ValueError('Truncated JPEG marker')
        marker=data[pos];pos+=1
        if marker==0xda:
            parts.append(data[start:]);render.append(data[start:]);saw_scan=True;break
        if marker in [0x01,*range(0xd0,0xd8)]:
            parts.append(data[start:pos]);render.append(data[start:pos]);continue
        if pos+2>len(data):raise ValueError('Truncated JPEG segment')
        length=int.from_bytes(data[pos:pos+2],'big');end=pos+length
        if length<2 or end>len(data):raise ValueError('Truncated JPEG segment')
        body=data[pos+2:end];segment=data[start:end]
        if marker==0xe1 and body.startswith(XMP_PREFIX):
            edited,count=clean_xmp(body[len(XMP_PREFIX):]);removed+=count
            if count:
                replacement=XMP_PREFIX+edited
                if len(replacement)+2>65535:raise ValueError('Edited XMP exceeds JPEG segment size')
                segment=data[start:pos]+struct.pack('>H',len(replacement)+2)+replacement
        else:render.append(segment)
        parts.append(segment);pos=end
    if not saw_scan:raise ValueError('Missing JPEG image data')
    return b''.join(parts),{'xmp_ai_fields_removed':removed,'image_and_other_metadata_sha256':digest(b''.join(render))}

def clean(data,suffix):
    if suffix.lower()=='.png':return clean_png(data)
    if suffix.lower() in ['.jpg','.jpeg']:return clean_jpeg(data)
    raise ValueError('Unsupported cleanup format: '+suffix)

def prepare_one(root,stage,entry):
    source=batch_scan.safe_child(root,entry['path']);target=batch_scan.safe_child(stage,entry['path'])
    before=batch_scan.fingerprint(source);before_meta=metadata(source)
    if before!=entry['snapshot']:raise ValueError('Source changed before preparation')
    if before['size']>256*1024*1024:raise ValueError('File exceeds cleanup memory limit')
    original=source.read_bytes();output,details=clean(original,source.suffix)
    if not sum(details.get(k,0) for k in ['c2pa_chunks_removed','xmp_ai_fields_removed']):raise ValueError('No removable marker found')
    if source.suffix.lower()=='.png':
        again,check_details=clean_png(output)
    else:again,check_details=clean_jpeg(output)
    if again!=output or check_details['image_and_other_metadata_sha256']!=details['image_and_other_metadata_sha256']:
        raise ValueError('Image data verification failed')
    target.parent.mkdir(parents=True,exist_ok=True)
    with target.open('xb') as f:f.write(output);f.flush();os.fsync(f.fileno())
    preserve_metadata(source,target)
    if file_hash(target)!=digest(output):raise ValueError('Output changed during metadata copy')
    if metadata(source)!=before_meta or batch_scan.fingerprint(source)!=before:raise ValueError('Source changed during preparation')
    return {'path':entry['path'],'original_snapshot':before,'original_sha256':digest(original),
            'new_sha256':digest(output),'new_snapshot':batch_scan.fingerprint(target),
            'metadata':before_meta,'details':details}

def prepare(root,stage,run,app):
    if stage.exists() or run.exists():raise FileExistsError('Use a new staging/report directory')
    run.mkdir(parents=True);stage.mkdir(parents=True)
    entries,skipped=batch_scan.walk(root)
    if not entries:raise ValueError('No files to clean')
    write=lambda name,value:batch_scan.write_json(run/name,value)
    write('inventory.json',{'root':str(root),'stage':str(stage),'entries':entries,'skipped':skipped})
    rows=[];errors=[]
    with (run/'prepared.jsonl').open('w') as log,concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures={pool.submit(prepare_one,root,stage,e):e for e in entries}
        for future in concurrent.futures.as_completed(futures):
            entry=futures[future]
            try:
                row=future.result();rows.append(row);log.write(json.dumps(row,ensure_ascii=False)+'\n');log.flush()
            except Exception as error:errors.append({'path':entry['path'],'error':str(error)})
            if (len(rows)+len(errors))%250==0:print(json.dumps({'prepared':len(rows),'errors':len(errors),'total':len(entries)}),flush=True)
    write('preparation-errors.json',errors)
    if errors:raise ValueError('Preparation incomplete; no originals replaced. See preparation-errors.json')
    batch_scan.scan(stage,run/'scanner-verification',app)
    summary=json.loads((run/'scanner-verification/summary.json').read_text())
    if summary['scanned']!=len(rows) or summary['counts']!={'no_signals':len(rows)}:
        raise ValueError('Not every cleaned file passed scanner verification. Originals unchanged.')
    rows.sort(key=lambda row:row['path'])
    write('commit-plan.json',{'root':str(root),'stage':str(stage),'entries':rows})
    write('prepare-summary.json',{'prepared':len(rows),'tagged':sum(TAG in row['metadata']['xattrs'] for row in rows),'finder_info':sum('com.apple.FinderInfo' in row['metadata']['xattrs'] for row in rows),'all_outputs_no_signals':True,'metadata_verified':True})
    print((run/'prepare-summary.json').read_text(),flush=True)

def verify(path,row,new):
    expected=row['new_sha256'] if new else row['original_sha256']
    if file_hash(path)!=expected or metadata(path)!=row['metadata']:raise ValueError('Verification failed: '+str(path))

def commit(root,stage,run,delete_originals):
    if not delete_originals:raise ValueError('Explicit --delete-originals is required')
    plan=json.loads((run/'commit-plan.json').read_text())
    if plan['root']!=str(root) or plan['stage']!=str(stage):raise ValueError('Plan paths mismatch')
    if (run/'commit.jsonl').exists():raise ValueError('Commit already started; inspect its journal before resuming')
    for row in plan['entries']:
        old=batch_scan.safe_child(root,row['path']);new=batch_scan.safe_child(stage,row['path'])
        if batch_scan.fingerprint(old)!=row['original_snapshot'] or batch_scan.fingerprint(new)!=row['new_snapshot']:
            raise ValueError('File identity changed since preparation')
        verify(old,row,False);verify(new,row,True)
    swapped=[]
    with (run/'commit.jsonl').open('x') as journal:
        for row in plan['entries']:
            old=batch_scan.safe_child(root,row['path']);new=batch_scan.safe_child(stage,row['path'])
            verify(old,row,False);verify(new,row,True)
            record={'path':row['path'],'state':'swap_prepared'}
            journal.write(json.dumps(record,ensure_ascii=False)+'\n');journal.flush();os.fsync(journal.fileno())
            check(LIB.renamex_np(os.fsencode(old),os.fsencode(new),2)) # RENAME_SWAP
            try:verify(old,row,True);verify(new,row,False)
            except Exception:
                check(LIB.renamex_np(os.fsencode(old),os.fsencode(new),2));raise
            record['state']='swapped_and_verified';journal.write(json.dumps(record,ensure_ascii=False)+'\n');journal.flush()
            swapped.append(row)
            if len(swapped)%500==0:print(json.dumps({'replaced':len(swapped),'total':len(plan['entries'])}),flush=True)
        # Originals still exist in staging until every replacement passes.
        for row in swapped:
            verify(batch_scan.safe_child(root,row['path']),row,True)
            verify(batch_scan.safe_child(stage,row['path']),row,False)
        for row in swapped:
            old=batch_scan.safe_child(stage,row['path']);old.unlink()
            journal.write(json.dumps({'path':row['path'],'state':'original_deleted'},ensure_ascii=False)+'\n');journal.flush()
        os.fsync(journal.fileno())
    for parent,dirs,files in os.walk(stage,topdown=False):
        if files:raise ValueError('Unexpected files remain in staging')
        Path(parent).rmdir()
    result={'replaced':len(swapped),'originals_deleted':len(swapped),'names_preserved':True,'image_data_preserved':True,'mac_metadata_preserved':True,'stage_removed':True}
    batch_scan.write_json(run/'completion.json',result)
    print(json.dumps(result),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('mode',choices=['prepare','commit']);p.add_argument('root',type=Path);p.add_argument('stage',type=Path);p.add_argument('run',type=Path);p.add_argument('--delete-originals',action='store_true');p.add_argument('--app',type=Path,default=Path(__file__).parent/'Sinal IA.app/Contents/MacOS/SinalIA');a=p.parse_args()
    root,stage,run=a.root.resolve(),a.stage.resolve(),a.run.resolve()
    if root==stage or root in stage.parents or stage in root.parents:raise ValueError('Staging must be outside the source directory')
    if a.mode=='prepare':prepare(root,stage,run,a.app.resolve())
    else:commit(root,stage,run,a.delete_originals)

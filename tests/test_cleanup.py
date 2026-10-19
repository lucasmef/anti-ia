import contextlib
import ctypes
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import tempfile
import unittest

from test_images import FIXTURES, chunk, store, XMP

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('clean_metadata',ROOT/'clean_metadata.py')
cleaner=importlib.util.module_from_spec(spec);spec.loader.exec_module(cleaner)

class CleanupTests(unittest.TestCase):
    def png(self):
        raw=(FIXTURES/'plain.png').read_bytes()
        return raw[:-12]+chunk('caBX',store())+raw[-12:]
    def attr(self,path,name,value):
        data=ctypes.create_string_buffer(value)
        cleaner.check(cleaner.LIB.setxattr(os.fsencode(path),name.encode(),data,len(value),0,0))
    def test_png_preserves_every_non_c2pa_byte(self):
        new,details=cleaner.clean_png(self.png())
        self.assertEqual(new,(FIXTURES/'plain.png').read_bytes())
        self.assertEqual(details['c2pa_chunks_removed'],1)
    def test_jpeg_preserves_all_image_and_other_metadata(self):
        raw=(FIXTURES/'ai.jpg').read_bytes()
        new,before=cleaner.clean_jpeg(raw)
        again,after=cleaner.clean_jpeg(new)
        self.assertEqual(before['image_and_other_metadata_sha256'],after['image_and_other_metadata_sha256'])
        self.assertEqual(new,again)
        self.assertEqual(before['xmp_ai_fields_removed'],1)
    def test_xmp_preserves_other_fields(self):
        packet=XMP.replace(b'<rdf:Description ',b'<rdf:Description keep="copyright" ')
        output,count=cleaner.clean_xmp(packet)
        self.assertEqual(count,1);self.assertIn(b'copyright',output)
    def test_invalid_png_keeps_source_untouched(self):
        bad=bytearray(self.png());bad[-1]^=1
        with self.assertRaises(ValueError):cleaner.clean_png(bytes(bad))
    def test_staged_replace_preserves_tags_dates_and_finder_colors(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);root=base/'source';root.mkdir();stage=base/'stage';run=base/'report'
            p=root/'labeled.png';p.write_bytes(self.png())
            self.attr(p,'com.apple.metadata:_kMDItemUserTags',plistlib.dumps(['Vermelho\n6'],fmt=plistlib.FMT_BINARY))
            info=bytearray(32);info[9]=12
            self.attr(p,'com.apple.FinderInfo',bytes(info))
            os.utime(p,ns=(1700000000000000000,1700000000000000000))
            before=cleaner.metadata(p)
            with contextlib.redirect_stdout(io.StringIO()):
                cleaner.prepare(root,stage,run,ROOT/'Sinal IA.app/Contents/MacOS/SinalIA')
                self.assertEqual(p.read_bytes(),self.png())
                with self.assertRaises(ValueError):cleaner.commit(root,stage,run,False)
                cleaner.commit(root,stage,run,True)
            self.assertEqual(cleaner.metadata(p),before)
            self.assertEqual(p.read_bytes(),(FIXTURES/'plain.png').read_bytes())
            self.assertFalse(stage.exists())
    def test_modified_original_aborts_before_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);root=base/'source';root.mkdir();stage=base/'stage';run=base/'report'
            p=root/'image.png';p.write_bytes(self.png())
            with contextlib.redirect_stdout(io.StringIO()):cleaner.prepare(root,stage,run,ROOT/'Sinal IA.app/Contents/MacOS/SinalIA')
            p.write_bytes(b'user edit')
            with self.assertRaises(ValueError):cleaner.commit(root,stage,run,True)
            self.assertEqual(p.read_bytes(),b'user edit')

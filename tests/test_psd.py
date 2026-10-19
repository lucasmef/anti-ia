import struct
import unittest
import test_scanner
from test_images import XMP

def psd(xmp=b'', version=1, name=b''):
    header = b'8BPS'+struct.pack('>H',version)+bytes(6)+struct.pack('>HIIHH',3,1,1,8,3)
    named = bytes([len(name)])+name
    named += bytes(len(named)%2)
    resources = b'8BIM'+struct.pack('>H',1060)+named+struct.pack('>I',len(xmp))+xmp+bytes(len(xmp)%2) if xmp else b''
    return header+bytes(4)+struct.pack('>I',len(resources))+resources+bytes(4 if version == 1 else 8)+bytes(5)

class PSDTests(unittest.TestCase):
    scan = test_scanner.ScannerTests.scan
    def test_psd_and_psb_xmp(self):
        for version in [1,2]:
            for name in [b'',b'a',b'ab']:
                report = self.scan(psd(XMP,version,name),'.psd' if version == 1 else '.psb')
                self.assertEqual(report['status'],'ai_declared',report)
                self.assertTrue(report['warnings'])
    def test_plain_psd_is_inconclusive(self):
        self.assertEqual(self.scan(psd(),'.psd')['status'],'inconclusive')
    def test_description_does_not_trigger(self):
        self.assertEqual(self.scan(psd(b'<description>ChatGPT trainedAlgorithmicMedia</description>'),'.psd')['status'],'inconclusive')
    def test_truncated_psd(self):
        for data in [b'8BPS',psd(XMP)[:-12]]:
            self.assertEqual(self.scan(data,'.psd')['status'],'inconclusive')

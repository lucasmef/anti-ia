import pathlib
import struct
import unittest
import zlib
import test_scanner
from test_scanner import box, cbor, credentials, URI

FIXTURES = pathlib.Path(__file__).parent / 'fixtures'
XMP = f'<x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:i="http://iptc.org/std/Iptc4xmpExt/2008-02-29/"><rdf:RDF><rdf:Description i:DigitalSourceType="{URI}trainedAlgorithmicMedia"/></rdf:RDF></x:xmpmeta>'.encode()

def store(term='trainedAlgorithmicMedia'):
    desc = box('jumd', bytes.fromhex('6332706100110010800000aa00389b71') + b'\x03c2pa\0')
    return box('jumb', desc + box('jumb', box('cbor', cbor({'actions': [{'digitalSourceType': URI+term}]}))))

def chunk(kind, data):
    raw = kind.encode() + data
    return struct.pack('>I',len(data)) + raw + struct.pack('>I',zlib.crc32(raw))

def jpeg_segment(marker, data):
    return bytes([255,marker]) + struct.pack('>H',len(data)+2) + data

class ImageTests(unittest.TestCase):
    scan = test_scanner.ScannerTests.scan

    def test_native_images_with_and_without_ai(self):
        for suffix in ['png','jpg','tiff','heic']:
            for name, expected in [('plain','no_signals'),('ai','ai_declared')]:
                with self.subTest(suffix=suffix,name=name):
                    r = self.scan((FIXTURES/f'{name}.{suffix}').read_bytes(), '.'+suffix)
                    self.assertEqual(r['status'], expected, r['warnings'])

    def test_png_c2pa_and_camera_credentials(self):
        png = (FIXTURES/'plain.png').read_bytes()
        for term, expected in [('trainedAlgorithmicMedia','ai_declared'),('digitalCapture','credentials_present')]:
            r = self.scan(png[:-12]+chunk('caBX',store(term))+png[-12:], '.png')
            self.assertEqual(r['status'],expected,r['warnings'])

    def test_png_xmp_compression(self):
        png = (FIXTURES/'plain.png').read_bytes()
        for type, payload in [('iTXt',b'XML:com.adobe.xmp\0\x01\0\0\0'+zlib.compress(XMP)), ('zTXt',b'XML:com.adobe.xmp\0\0'+zlib.compress(XMP))]:
            r = self.scan(png[:-12]+chunk(type,payload)+png[-12:],'.png')
            self.assertEqual(r['status'],'ai_declared',r['warnings'])

    def test_png_bad_crc_and_empty_compression(self):
        png = (FIXTURES/'plain.png').read_bytes()
        bad = bytearray(chunk('caBX',store()));bad[-1] ^= 1
        for block in [bad,chunk('iTXt',b'XML:com.adobe.xmp\0\x01\0\0\0')]:
            r = self.scan(png[:-12]+block+png[-12:],'.png')
            self.assertEqual(r['status'],'inconclusive')

    def test_jpeg_fragmented_manifest(self):
        jpg = (FIXTURES/'plain.jpg').read_bytes(); manifest = store()
        segments = b''
        for i, data in enumerate([manifest[:65],manifest[65:110],manifest[110:]]):
            segments += jpeg_segment(0xeb,b'JP\0\x01'+struct.pack('>I',i+1)+(manifest[:8] if i else b'')+data)
        r = self.scan(jpg[:2]+segments+jpg[2:],'.jpg')
        self.assertEqual(r['status'],'ai_declared',r['warnings'])
        missing = jpeg_segment(0xeb,b'JP\0\x01'+struct.pack('>I',1)+manifest[:65])
        self.assertEqual(self.scan(jpg[:2]+missing+jpg[2:],'.jpg')['status'],'inconclusive')

    def test_jpeg_extended_xmp(self):
        jpg = (FIXTURES/'plain.jpg').read_bytes(); segments = b''
        for start,end in [(100,len(XMP)),(0,100)]:
            payload = b'http://ns.adobe.com/xmp/extension/\0'+b'A'*32+struct.pack('>II',len(XMP),start)+XMP[start:end]
            segments += jpeg_segment(0xe1,payload)
        r = self.scan(jpg[:2]+segments+jpg[2:],'.jpg')
        self.assertEqual(r['status'],'ai_declared',r['warnings'])

    def test_webp_c2pa_xmp_and_plain(self):
        def riff_chunk(kind,data): return kind.encode()+struct.pack('<I',len(data))+data+bytes(len(data)%2)
        for extra,expected in [(b'','no_signals'),(riff_chunk('C2PA',store()),'ai_declared'),(riff_chunk('XMP ',XMP),'ai_declared')]:
            body = b'WEBP'+riff_chunk('VP8L',b'\x2f\0\0\0\0')+extra
            r = self.scan(b'RIFF'+struct.pack('<I',len(body))+body,'.webp')
            self.assertEqual(r['status'],expected,r['warnings'])

    def test_tiff_c2pa_both_byte_orders(self):
        for byteorder,signature in [('<',b'II'),('>',b'MM')]:
            data = store()
            raw = signature+struct.pack(byteorder+'HIH',42,8,1)+struct.pack(byteorder+'HHII',52545,7,len(data),26)+struct.pack(byteorder+'I',0)+data
            r = self.scan(raw,'.tiff')
            self.assertEqual(r['status'],'ai_declared',r['warnings'])

    def test_heic_manifest(self):
        raw = (FIXTURES/'plain.heic').read_bytes() + credentials({'digitalSourceType':URI+'trainedAlgorithmicMedia'})
        self.assertEqual(self.scan(raw,'.heic')['status'],'ai_declared')

    def test_wrong_extensions_and_truncated_images(self):
        for suffix in ['png','jpg','webp','heic','tiff','avif']:
            for raw in [b'not an image',(FIXTURES/'plain.png').read_bytes()[:15]]:
                self.assertEqual(self.scan(raw,'.'+suffix)['status'],'inconclusive')

    def test_metadata_words_are_not_ai(self):
        png = (FIXTURES/'plain.png').read_bytes()
        text = chunk('tEXt',b'Comment\0ChatGPT '+URI.encode()+b'trainedAlgorithmicMedia')
        self.assertEqual(self.scan(png[:-12]+text+png[-12:],'.png')['status'],'no_signals')

if __name__ == '__main__':
    unittest.main()

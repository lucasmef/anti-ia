"""Behavior tests against the compiled app; synthetic metadata only."""
import json
import pathlib
import struct
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / 'Sinal IA.app/Contents/MacOS/SinalIA'
UUID = bytes.fromhex('d8fec3d61b0e483c92975828877ec481')
URI = 'http://cv.iptc.org/newscodes/digitalsourcetype/'

def box(kind, body=b''):
    return struct.pack('>I4s', len(body) + 8, kind.encode()) + body

def cbor(value):
    def header(major, n):
        if n < 24:
            return bytes([(major << 5) + n])
        if n < 256:
            return bytes([(major << 5) + 24, n])
        return bytes([(major << 5) + 25]) + struct.pack('>H', n)
    if isinstance(value, str):
        b = value.encode()
        return header(3, len(b)) + b
    if isinstance(value, list):
        return header(4, len(value)) + b''.join(map(cbor, value))
    return header(5, len(value)) + b''.join(cbor(k)+cbor(v) for k,v in value.items())

def credentials(value):
    return box('uuid', UUID + b'\0\0\0\0manifest\0' + bytes(8) + box('jumb', box('jumb', box('cbor', cbor(value)))) + bytes(17))

def movie(metadata=b''):
    return box('ftyp', b'qt  \0\0\0\0qt  ') + box('moov') + metadata + box('mdat', b'fake sample bytes')

class ScannerTests(unittest.TestCase):
    def scan(self, content, suffix='.mov'):
        with tempfile.NamedTemporaryFile(suffix=suffix) as f:
            f.write(content); f.flush()
            return json.loads(subprocess.check_output([str(APP), '--scan', f.name]))[0]

    def test_plain_movie(self):
        self.assertEqual(self.scan(movie())['status'], 'no_signals')

    def test_explicit_ai(self):
        for term in ['trainedAlgorithmicMedia', 'compositeWithTrainedAlgorithmicMedia', 'compositeSynthetic']:
            with self.subTest(term=term):
                r = self.scan(movie(credentials({'actions': [{'digitalSourceType': URI + term, 'softwareAgent': {'name': 'ChatGPT'}}]})))
                self.assertEqual(r['status'], 'ai_declared')
                self.assertTrue(r['hasC2PA'])
                self.assertIn('ChatGPT', [e['value'] for e in r['evidence']])

    def test_camera_credentials_are_not_ai(self):
        r = self.scan(movie(credentials({'digitalSourceType': URI + 'digitalCapture'})))
        self.assertEqual(r['status'], 'credentials_present')

    def test_filename_or_description_does_not_trigger(self):
        r = self.scan(movie(credentials({'dc:title': 'ChatGPT.png', 'description': URI + 'trainedAlgorithmicMedia'})))
        self.assertEqual(r['status'], 'credentials_present')

    def test_sample_data_is_not_metadata(self):
        r = self.scan(box('moov') + box('mdat', credentials({'digitalSourceType': URI + 'trainedAlgorithmicMedia'})))
        self.assertEqual(r['status'], 'no_signals')

    def test_xmp_attribute_and_element(self):
        for inner in [f'<rdf:Description i:DigitalSourceType="{URI}trainedAlgorithmicMedia"/>', f'<rdf:Description><i:DigitalSourceType>{URI}trainedAlgorithmicMedia</i:DigitalSourceType></rdf:Description>']:
            xmp = f'<x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:i="http://iptc.org/std/Iptc4xmpExt/2008-02-29/"><rdf:RDF>{inner}</rdf:RDF></x:xmpmeta>'
            r = self.scan(movie(box('udta', box('XMP_', xmp.encode()))))
            self.assertEqual(r['status'], 'ai_declared')

    def test_wrong_namespace_does_not_trigger(self):
        xmp = f'<r xmlns:i="https://example.com"><i:DigitalSourceType>{URI}trainedAlgorithmicMedia</i:DigitalSourceType></r>'
        self.assertEqual(self.scan(movie(box('XMP_', xmp.encode())))['status'], 'no_signals')

    def test_unknown_uuid_is_inconclusive(self):
        self.assertEqual(self.scan(movie(box('uuid', bytes(16))))['status'], 'inconclusive')

    def test_invalid_and_truncated(self):
        for data in [b'', b'123', struct.pack('>I4s', 1000, b'moov'), movie()+b'bad']:
            with self.subTest(data=data[:20]):
                self.assertEqual(self.scan(data)['status'], 'inconclusive')

    def test_malformed_credentials(self):
        self.assertEqual(self.scan(movie(box('uuid', UUID + b'bad')))['status'], 'inconclusive')

    def test_metadata_after_media_and_extended_size(self):
        data = box('moov') + struct.pack('>I4sQ', 1, b'mdat', 20) + b'abcd' + credentials({'digitalSourceType': URI + 'trainedAlgorithmicMedia'})
        self.assertEqual(self.scan(data)['status'], 'ai_declared')

    def test_unsupported_extension(self):
        self.assertEqual(self.scan(movie(), '.avi')['status'], 'inconclusive')

    def test_large_sparse_video_skips_payload(self):
        with tempfile.NamedTemporaryFile(suffix='.mov') as f:
            f.write(box('moov'))
            size = 5 * 1024**3
            f.write(struct.pack('>I4sQ', 1, b'mdat', size))
            f.seek(size + 8)
            f.write(credentials({'digitalSourceType': URI + 'trainedAlgorithmicMedia'})); f.flush()
            r = json.loads(subprocess.check_output([str(APP), '--scan', f.name]))[0]
            self.assertEqual(r['status'], 'ai_declared')
            self.assertLess(r['bytesRead'], 4096)

if __name__ == '__main__':
    unittest.main()

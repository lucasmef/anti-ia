import unittest
import test_scanner
from test_scanner import box, cbor, movie, UUID, URI
from test_images import FIXTURES

class CompatibilityTests(unittest.TestCase):
    scan = test_scanner.ScannerTests.scan
    def wrapped(self,payload):
        return movie(box('uuid',UUID+bytes(4)+b'manifest\0'+bytes(8)+box('jumb',box('cbor',payload))))
    def test_indefinite_cbor_maps_arrays_and_strings(self):
        for value in [cbor(URI+'trainedAlgorithmicMedia'),b'\x7f'+cbor(URI)+cbor('trainedAlgorithmicMedia')+b'\xff']:
            payload=b'\xbf'+cbor('actions')+b'\x9f\xbf'+cbor('digitalSourceType')+value+b'\xff\xff\xff'
            self.assertEqual(self.scan(self.wrapped(payload))['status'],'ai_declared')
    def test_indefinite_cbor_binary(self):
        payload=b'\xbf'+cbor('signature')+b'\x5f\x42ab\x41c\xff\xff'
        self.assertEqual(self.scan(self.wrapped(payload))['status'],'credentials_present')
    def test_invalid_indefinite_cbor(self):
        for payload in [b'\xbf'+cbor('digitalSourceType')+b'\xff',b'\x7f\x5f\xff\xff',b'\x9f']:
            self.assertEqual(self.scan(self.wrapped(payload))['status'],'inconclusive')
    def test_jpeg_named_png(self):
        for name,status in [('plain.jpg','no_signals'),('ai.jpg','ai_declared')]:
            report=self.scan((FIXTURES/name).read_bytes(),'.png')
            self.assertEqual(report['status'],status)
            self.assertEqual(report['detectedFormat'],'jpg')

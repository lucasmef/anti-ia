import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE=Path(__file__).resolve().parents[1]/'batch_scan.py'
spec=importlib.util.spec_from_file_location('batch_scan',MODULE)
batch=importlib.util.module_from_spec(spec);spec.loader.exec_module(batch)
FIXTURES=Path(__file__).parent/'fixtures'
APP=MODULE.parent/'Sinal IA.app/Contents/MacOS/SinalIA'

class BatchTests(unittest.TestCase):
    def test_moves_only_explicit_ai_and_preserves_tree(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/'assets';root.mkdir();(root/'nested').mkdir()
            (root/'ai.png').write_bytes((FIXTURES/'ai.png').read_bytes())
            (root/'nested'/'ai.png').write_bytes((FIXTURES/'ai.png').read_bytes())
            (root/'plain.png').write_bytes((FIXTURES/'plain.png').read_bytes())
            (root/'broken.png').write_bytes(b'broken')
            (root/'link.png').symlink_to(root/'ai.png')
            run=Path(temp)/'report'
            batch.scan(root,run,APP)
            batch.move(root,run)
            self.assertFalse((root/'ai.png').exists())
            self.assertTrue((root/'alerta de ia/nested/ai.png').exists())
            self.assertTrue((root/'plain.png').exists())
            self.assertTrue((root/'broken.png').exists())
            self.assertEqual(json.loads((run/'move-summary.json').read_text())['moved'],2)

    def test_existing_destination_stops_before_any_move(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/'assets';root.mkdir()
            (root/'ai.png').write_bytes((FIXTURES/'ai.png').read_bytes())
            run=Path(temp)/'report';batch.scan(root,run,APP)
            (root/'alerta de ia').mkdir();(root/'alerta de ia/ai.png').write_bytes(b'keep')
            with self.assertRaises(FileExistsError):batch.move(root,run)
            self.assertTrue((root/'ai.png').exists())
            self.assertEqual((root/'alerta de ia/ai.png').read_bytes(),b'keep')

    def test_changed_source_is_not_moved(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/'assets';root.mkdir()
            (root/'ai.png').write_bytes((FIXTURES/'ai.png').read_bytes())
            run=Path(temp)/'report';batch.scan(root,run,APP)
            (root/'ai.png').write_bytes(b'changed')
            with self.assertRaises(ValueError):batch.move(root,run)
            self.assertTrue((root/'ai.png').exists())

    def test_path_traversal_rejected(self):
        with self.assertRaises(ValueError):batch.safe_child(Path('/tmp'), '../elsewhere')

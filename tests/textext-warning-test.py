"""Verify the targeted warning filter and safe repeat installation."""
from pathlib import Path
import runpy
import sys
import tempfile
import types
import unittest
from unittest.mock import patch as mock_patch
import warnings

PATCH = runpy.run_path(str(Path(__file__).resolve().parents[1] /
                          "inkscape/patch-textext-warning.py"))["patch"]
SOURCE = "try:\n    import gi\nexcept ImportError:\n    pass\n"
MESSAGE = "GLib.unix_signal_add_full is deprecated; use GLibUnix.signal_add_full instead"


class WarningPatchTests(unittest.TestCase):
    def test_warning_scope_and_repeat_run(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "asktext.py"
            path.write_text(SOURCE)
            PATCH(path)
            patched = path.read_text()
            PATCH(path)
            self.assertEqual(path.read_text(), patched)
            gi = types.ModuleType("gi")
            gi.PyGIDeprecationWarning = type("PyGIDeprecationWarning", (DeprecationWarning,), {})
            with mock_patch.dict(sys.modules, {"gi": gi}), warnings.catch_warnings(record=True) as seen:
                warnings.simplefilter("always")
                exec(compile(patched, str(path), "exec"), {})
                warnings.warn(MESSAGE, gi.PyGIDeprecationWarning)
                warnings.warn("Unrelated GTK warning", gi.PyGIDeprecationWarning)
                warnings.warn(MESSAGE, UserWarning)
                self.assertEqual(len(seen), 2)
                self.assertEqual(str(seen[0].message), "Unrelated GTK warning")
                self.assertIs(seen[1].category, UserWarning)

    def test_unknown_source_is_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "asktext.py"
            path.write_text("# unexpected upstream layout\n")
            with self.assertRaises(RuntimeError):
                PATCH(path)
            self.assertEqual(path.read_text(), "# unexpected upstream layout\n")


if __name__ == "__main__":
    unittest.main()

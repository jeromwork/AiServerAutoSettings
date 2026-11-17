"""Architecture guards for Windows-only ownership paths; no network mutation."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class Lifecycle(unittest.TestCase):
    def test_job_handle_and_inheritance_lifetime(self):
        native = (ROOT/'app/launcher/NativeJob.cs').read_text()
        self.assertIn('readonly SafeFileHandle handle', native)
        self.assertIn('handle.DangerousAddRef(ref pinned)', native)
        self.assertIn('handle.DangerousRelease()', native)
        self.assertIn('TerminateJobObject(handle, 1)', native)
        self.assertIn('new IntPtr(0x00020002)', native)  # inherited stdio whitelist only
        self.assertIn('new IntPtr(3 * IntPtr.Size)', native)
        self.assertIn('ref StartupInfoEx startup', native)
        self.assertIn('startup.cb = Marshal.SizeOf(typeof(StartupInfoEx))', native)

    def test_bounded_probe_cannot_be_direct_success(self):
        probe = (ROOT/'app/launcher/VpnProbe.cs').read_text()
        self.assertIn('GetBestInterface(', probe)
        self.assertIn('index != tunIndex', probe)
        self.assertIn('client.ConnectAsync(address, url.Port)', probe)
        self.assertIn('AuthenticateAsClientAsync(url.DnsSafeHost)', probe)
        self.assertIn('client.Close()', probe)
        self.assertNotIn('GetHostAddresses', probe)
        self.assertNotIn('HttpWebRequest', probe)
        self.assertNotIn('ServerCertificateValidationCallback', probe)

if __name__ == '__main__':
    unittest.main()

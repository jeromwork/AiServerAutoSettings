"""Resource gate for opt-in heavy checks on a shared 8 GiB server."""
import subprocess
import time


def wait_for_memory(attempts=20):
    for attempt in range(attempts + 1):
        output = subprocess.check_output(['free', '-m'], text=True)
        available = int(next(line for line in output.splitlines() if line.startswith('Mem:')).split()[-1])
        print('Resource guard: available=%s MiB (need 2000)' % available, flush=True)
        if available >= 2000:
            return True
        if attempt < attempts:
            time.sleep(60)
    print('SKIP heavy check: available memory stayed below 2000 MiB for 20 waits', flush=True)
    return False


if __name__ == '__main__':
    raise SystemExit(0 if wait_for_memory() else 77)

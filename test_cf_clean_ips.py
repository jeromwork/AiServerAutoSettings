import socket
import time

ips = [
    "188.114.96.1", "188.114.96.2", "188.114.96.3",
    "188.114.97.1", "188.114.97.2", "188.114.97.3",
    "162.159.192.1", "162.159.193.1",
    "104.16.132.229", "104.16.133.229",
    "104.17.150.100", "172.64.150.10"
]

results = []
for ip in ips:
    t0 = time.time()
    try:
        s = socket.create_connection((ip, 443), timeout=1.5)
        dt = (time.time() - t0) * 1000
        s.close()
        results.append((ip, round(dt, 1)))
    except Exception as e:
        results.append((ip, None))

results.sort(key=lambda x: x[1] if x[1] is not None else 9999)
for ip, ping in results:
    print(f"{ip:16}: {ping} ms")

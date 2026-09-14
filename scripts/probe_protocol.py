"""Credential-free protocol probe. Performs DH handshake + documented-in-binary ping.

Only public handshake parameters and synthetic ping results are printed. No login,
password, account session, packet capture, or game-memory access is performed.
"""
import secrets
import socket
import struct
import argparse


def exact(s, n):
    out = bytearray()
    while len(out) < n:
        part = s.recv(n - len(out))
        if not part:
            raise EOFError('connection closed')
        out.extend(part)
    return bytes(out)


def blob(s, maximum):
    n, = struct.unpack('>I', exact(s, 4))
    if not 0 < n <= maximum:
        raise ValueError('invalid handshake field length')
    return exact(s, n)


def crypt(data, key, decrypt=False):
    from Crypto.Cipher import Blowfish
    swap = lambda d: b''.join(d[i:i+4][::-1] for i in range(0, len(d), 4))
    source = swap(data)
    cipher = Blowfish.new(key, Blowfish.MODE_ECB)
    return swap(cipher.decrypt(source) if decrypt else cipher.encrypt(source))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='221.122.119.158', choices=['221.122.119.158', '221.122.108.12'])
    ap.add_argument('--timeout', type=float, default=8)
    args = ap.parse_args()
    with socket.create_connection((args.host, 9030), timeout=args.timeout) as s:
        s.settimeout(args.timeout)
        s.sendall(struct.pack('>II', 1, 8))
        status, = struct.unpack('>I', exact(s, 4))
        if status != 0:
            raise ValueError(f'handshake rejected {status}')
        g, p, server_public = [int(blob(s, bound), 16) for bound in [62, 1022, 1022]]
        print('SERVER_HANDSHAKE_OK', 'modulus_bits', p.bit_length(), 'generator', g)
        private = secrets.randbits(160) | 1
        public = format(pow(g, private, p), 'X')
        if len(public) % 2: public = '0' + public
        shared = format(pow(server_public, private, p), 'X')
        if len(shared) % 2: shared = '0' + shared
        key = bytes.fromhex(shared)[:8]
        s.sendall(struct.pack('>I', len(public)) + public.encode('ascii'))
        body = b'\x01' + struct.pack('>II', 0, 123456)
        plain = struct.pack('>H', len(body)) + body
        padded = plain + bytes((len(plain) // 8 + 1) * 8 - len(plain))
        s.sendall(struct.pack('>II', len(padded), len(plain)) + crypt(padded, key))
        encrypted_len, plain_len = struct.unpack('>II', exact(s, 8))
        if encrypted_len > 32768 or encrypted_len % 8 or plain_len > encrypted_len:
            raise ValueError('invalid response record')
        response = crypt(exact(s, encrypted_len), key, True)[:plain_len]
        print('PING_RESPONSE', response.hex())
        assert len(response) == 11 and response[:7] == struct.pack('>HBI', 9, 2, 0)
        print('NATIVE_PROTOCOL_PING_OK')


if __name__ == '__main__':
    main()

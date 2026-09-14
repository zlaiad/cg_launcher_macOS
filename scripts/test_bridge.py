"""Tests Wine stdin transport with synthetic data, without touching CGSharedMem."""
from pathlib import Path
import os
import struct
import subprocess
import shutil

root = Path(__file__).resolve().parent.parent
helper = root / 'work/cg_bridge.exe'
subprocess.run(['i686-w64-mingw32-gcc', '-O2', '-Wall', '-Wextra', '-static', str(root / 'bridge/cg_bridge.c'), '-o', str(helper)], check=True)
wine = '/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine'
command = [wine, '--bottle', 'CrossGate', 'Z:' + str(helper).replace('/', '\\')]
env = dict(os.environ, WINEDEBUG='-all', LANG='zh_CN.UTF-8', LC_ALL='zh_CN.UTF-8')
result = subprocess.run(command + ['--locale-check'], capture_output=True, timeout=20, env=env)
assert result.returncode == 0 and b'acp=936' in result.stdout
result = subprocess.run(command + ['--self-test'], capture_output=True, timeout=20, env=env)
assert result.returncode == 0 and b'BRIDGE_SELF_TEST_OK' in result.stdout

# The child must reopen its own image using GetModuleFileNameA/GetFileAttributesA
# when its original installation path contains Chinese, using the game's ACP 936.
unicode_helper = root / 'work/路径验证/cg_bridge.exe'
unicode_helper.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(helper, unicode_helper)
unicode_command = [wine, '--bottle', 'CrossGate', 'Z:' + str(unicode_helper).replace('/', '\\')]
result = subprocess.run(unicode_command + ['--self-test'], capture_output=True, timeout=20, env=env)
assert result.returncode == 0 and b'BRIDGE_SELF_TEST_OK' in result.stdout

packet = bytearray(b'CGM1')
def field(s):
    b = s.encode('utf-8'); packet.extend(struct.pack('<I', len(b))); packet.extend(b)
field('gid:synthetic glt:synthetic:1 ')
field('C:\\Program Files (x86)\\PlayOnline\\魔力宝贝\\cg_se_3000.exe')
field('C:\\Program Files (x86)\\PlayOnline\\魔力宝贝')
args = ['updated', 'IP:0:127.0.0.1:9013', 'animebin:3']
packet.extend(struct.pack('<I', len(args)))
for arg in args: field(arg)
result = subprocess.run(command + ['--validate-input'], input=packet, capture_output=True, timeout=20, env=env)
assert result.returncode == 0 and b'BRIDGE_STDIN_VALIDATED' in result.stdout
print('BRIDGE_CHECKS_OK shared_memory child_process unicode_paths legacy_ansi_image_path stdin_transport')

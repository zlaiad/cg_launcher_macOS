"""Local static PE inspection. Does not read live process memory or credentials."""
import argparse
import re
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32
from capstone.x86 import X86_OP_IMM, X86_OP_MEM


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('binary', type=Path)
    ap.add_argument('--disasm', type=Path)
    ap.add_argument('--match', default=r'CGSharedMem|gid:|glt:|login|password|connect|send|recv|billing|认证|密码|帐号|计费')
    args = ap.parse_args()
    pe = pefile.PE(str(args.binary))
    image_base = pe.OPTIONAL_HEADER.ImageBase
    print(f'Image base: {image_base:#x}, entry: {image_base + pe.OPTIONAL_HEADER.AddressOfEntryPoint:#x}')
    imports = {}
    for library in getattr(pe, 'DIRECTORY_ENTRY_IMPORT', []):
        for imp in library.imports:
            imports[imp.address] = library.dll.decode() + '!' + (imp.name.decode() if imp.name else f'ordinal_{imp.ordinal}')
    for address, name in imports.items():
        if re.search(r'socket|send|recv|connect|crypt|mapview|mapping|createprocess|openprocess|readprocess', name, re.I):
            print(f'IMPORT {address:#x}: {name}')
    strings = {}
    for section in pe.sections:
        for match in re.finditer(rb'[\x20-\x7e\x80-\xff]{4,}\x00', section.get_data()):
            raw = match.group()[:-1]
            if len(raw) > 1200:
                continue
            text = raw.decode('gb18030', errors='replace')
            addr = image_base + section.VirtualAddress + match.start()
            strings[addr] = text
            if re.search(args.match, text, re.I):
                print(f'STRING {addr:#x}: {text}')
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = True
    md.skipdata = True
    lines = []
    for section in pe.sections:
        if not section.Characteristics & 0x20000000:
            continue
        for ins in md.disasm(section.get_data(), image_base + section.VirtualAddress):
            notes = []
            if ins.id:
                for operand in ins.operands:
                    address = operand.imm if operand.type == X86_OP_IMM else operand.mem.disp if operand.type == X86_OP_MEM else None
                    if address in imports:
                        notes.append(imports[address])
                    if address in strings:
                        notes.append(repr(strings[address]))
            line = f'{ins.address:08x}  {ins.mnemonic:8} {ins.op_str}'
            if notes:
                line += ' ; ' + ' | '.join(notes)
                if any(re.search(args.match, x, re.I) for x in notes):
                    print('XREF', line)
            lines.append(line)
    if args.disasm:
        args.disasm.write_text('\n'.join(lines))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Print "0x<crc> <symbol>" for every symbol a relocatable kernel module (.ko) exports.

Used by build-drivers.sh: with CONFIG_MODVERSIONS, a module only loads if the CRCs it was built
against match the running kernel's. The stock WSL modules carry the real CRCs in their __kcrctab
sections; the matching symbol names come from the relocations of their __ksymtab sections (each
12-byte ksymtab entry points at a "__kstrtab_<name>" string, and entry i's CRC is the i-th u32 of
the corresponding __kcrctab section).

Usage: kcrc.py <module.ko>
"""
import re
import struct
import subprocess
import sys


def readelf(*args):
    return subprocess.run(["readelf", *args], capture_output=True, text=True).stdout.splitlines()


def main(ko):
    data = open(ko, "rb").read()
    offsets = {}                                       # section name -> file offset
    for line in readelf("-S", "-W", ko):
        m = re.match(r"\s*\[\s*(\d+)\]\s+(\S+)\s+\S+\s+[0-9a-f]+\s+([0-9a-f]+)\s+([0-9a-f]+)", line)
        if m:
            offsets[m.group(2)] = int(m.group(3), 16)

    section = None                                     # "__ksymtab" or "__ksymtab_gpl"
    for line in readelf("-r", "-W", ko):
        m = re.match(r"Relocation section '\.rela(__ksymtab(?:_gpl)?)'", line)
        if m:
            section = m.group(1)
            continue
        if line.startswith("Relocation section"):
            section = None
            continue
        if not section:
            continue
        p = line.split()
        if len(p) >= 5 and p[4].startswith("__kstrtab_") and not p[4].startswith("__kstrtabns_"):
            entry = int(p[0], 16) // 12
            crctab = offsets.get(section.replace("__ksymtab", "__kcrctab"))
            if crctab is None:
                continue
            crc = struct.unpack_from("<I", data, crctab + entry * 4)[0]
            print(f"0x{crc:08x} {p[4][len('__kstrtab_'):]}")


if __name__ == "__main__":
    main(sys.argv[1])

#!/usr/bin/env python3
"""맥 앱의 자체 서명(ad-hoc)을 Apple 도구 없이 검증한다.

macOS가 앱을 실행할 때 확인하는 것과 같은 항목을 실제 파일로 다시 계산해 서명 기록과 대조한다.
  1) 모든 Mach-O 실행 파일: 코드 페이지별 SHA-256이 CodeDirectory에 기록된 값과 같은지
  2) 번들(.app/.framework)의 주 실행 파일: Info.plist, CodeResources 지문(특수 슬롯)이 맞는지
  3) CodeResources(_CodeSignature): 기록된 리소스 파일 지문이 맞고, 기록에서 빠진 파일이 없는지

사용: python3 mac/verify-signature.py "release/mac-arm64/MD Studio.app"
"""
import hashlib
import os
import plistlib
import re
import struct
import sys

LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
HASHERS = {1: hashlib.sha1, 2: hashlib.sha256}


def code_directories(data):
    """Mach-O(단일 또는 universal)에서 (슬라이스 시작, CodeDirectory 정보) 목록을 돌려준다."""
    magic_be = struct.unpack_from('>I', data, 0)[0]
    slices = []
    if magic_be == FAT_MAGIC:
        n = struct.unpack_from('>I', data, 4)[0]
        for i in range(n):
            _cpu, _sub, off, size, _align = struct.unpack_from('>5I', data, 8 + i * 20)
            slices.append((off, size))
    else:
        slices.append((0, len(data)))
    out = []
    for off, size in slices:
        if struct.unpack_from('<I', data, off)[0] != MH_MAGIC_64:
            raise ValueError('64비트 Mach-O가 아님')
        ncmds = struct.unpack_from('<I', data, off + 16)[0]
        p = off + 32
        sig = None
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from('<II', data, p)
            if cmd == LC_CODE_SIGNATURE:
                sig = struct.unpack_from('<II', data, p + 8)
            p += cmdsize
        if not sig:
            raise ValueError('서명 없음')
        sb = off + sig[0]
        magic, _length, count = struct.unpack_from('>III', data, sb)
        if magic != CSMAGIC_EMBEDDED_SIGNATURE:
            raise ValueError('서명 블록 형식 오류')
        best = None
        for i in range(count):
            typ, boff = struct.unpack_from('>II', data, sb + 12 + i * 8)
            if typ == 0 or 0x1000 <= typ < 0x1005:  # 기본 CodeDirectory 또는 대체 CodeDirectory
                cd = sb + boff
                if struct.unpack_from('>I', data, cd)[0] != CSMAGIC_CODEDIRECTORY:
                    continue
                (_m, _l, version, flags, hash_off, ident_off, n_special, n_code, code_limit,
                 hash_size, hash_type, _platform, page_log2) = struct.unpack_from('>7I2I4B', data, cd)
                info = dict(cd=cd, flags=flags, hash_off=hash_off, n_special=n_special, n_code=n_code,
                            code_limit=code_limit, hash_size=hash_size, hash_type=hash_type, page=1 << page_log2,
                            ident=data[cd + ident_off:data.index(b'\0', cd + ident_off)].decode())
                if best is None or hash_type > best['hash_type']:
                    best = info  # SHA-256이 있으면 그것으로 검증
        if not best:
            raise ValueError('CodeDirectory 없음')
        out.append((off, best))
    return out


def slot_hash(data, cd, slot):
    start = cd['cd'] + cd['hash_off'] + slot * cd['hash_size']
    return data[start:start + cd['hash_size']]


def verify_macho(path, bundle_root=None):
    data = open(path, 'rb').read()
    errors = []
    for off, cd in code_directories(data):
        h = HASHERS[cd['hash_type']]
        for i in range(cd['n_code']):
            a = off + i * cd['page']
            b = off + min((i + 1) * cd['page'], cd['code_limit'])
            if h(data[a:b]).digest() != slot_hash(data, cd, i):
                errors.append(f'코드 페이지 {i} 지문 불일치')
                break
        if bundle_root:
            contents = os.path.join(bundle_root, 'Contents') if os.path.isdir(os.path.join(bundle_root, 'Contents')) else os.path.join(bundle_root, 'Resources')
            info_plist = os.path.join(bundle_root, 'Contents', 'Info.plist') if bundle_root.endswith('.app') else os.path.join(bundle_root, 'Resources', 'Info.plist')
            res = os.path.join(bundle_root, 'Contents', '_CodeSignature', 'CodeResources') if bundle_root.endswith('.app') else os.path.join(bundle_root, '_CodeSignature', 'CodeResources')
            if cd['n_special'] >= 1 and os.path.exists(info_plist):
                if h(open(info_plist, 'rb').read()).digest() != slot_hash(data, cd, -1):
                    errors.append('Info.plist 지문 불일치')
            if cd['n_special'] >= 3:
                if not os.path.exists(res):
                    errors.append('CodeResources 없음')
                elif h(open(res, 'rb').read()).digest() != slot_hash(data, cd, -3):
                    errors.append('CodeResources 지문 불일치')
    return errors, cd


def verify_resources(bundle, main_executables=frozenset()):
    """CodeResources의 files2 기록과 실제 파일을 대조한다."""
    if bundle.endswith('.app'):
        base, res = os.path.join(bundle, 'Contents'), os.path.join(bundle, 'Contents', '_CodeSignature', 'CodeResources')
    else:
        base, res = bundle, os.path.join(bundle, '_CodeSignature', 'CodeResources')
    if not os.path.exists(res):
        return ['CodeResources 없음']
    doc = plistlib.load(open(res, 'rb'))
    seal = doc.get('files2', {})
    # 서명에 기록된 Apple 규칙 중 '제외(omit)' 규칙: Info.plist(특수 슬롯으로 보호), PkgInfo 등
    omit = [re.compile(k) for k, v in doc.get('rules2', {}).items() if isinstance(v, dict) and v.get('omit')]
    errors = []
    for rel, entry in seal.items():
        p = os.path.join(base, rel)
        if 'symlink' in entry:
            if not os.path.islink(p) or os.readlink(p) != entry['symlink']:
                errors.append(f'링크 불일치: {rel}')
        elif 'hash2' in entry:
            if not os.path.isfile(p):
                errors.append(f'파일 없음: {rel}')
            elif hashlib.sha256(open(p, 'rb').read()).digest() != entry['hash2']:
                errors.append(f'지문 불일치: {rel}')
        elif 'cdhash' in entry and not os.path.exists(p):
            errors.append(f'중첩 코드 없음: {rel}')
    # 기록에 없는 파일이 추가되지 않았는지 (중첩 번들과 서명 폴더 제외)
    nested = [os.path.join(base, k) for k, v in seal.items() if 'cdhash' in v or 'requirement' in v]
    for root, dirs, files in os.walk(base):
        if any(root == n or root.startswith(n + os.sep) for n in nested):
            dirs[:] = []
            continue
        for name in files:
            p = os.path.join(root, name)
            rel = os.path.relpath(p, base)
            if rel.startswith('_CodeSignature') or rel.startswith('MacOS' + os.sep) or '/_CodeSignature/' in '/' + rel:
                continue
            if any(r.search(rel) for r in omit):
                continue
            if p in main_executables:
                continue  # 번들 주 실행 파일은 자기 서명(코드 페이지 지문)으로 보호됨
            if rel not in seal and not os.path.islink(p):
                errors.append(f'기록에 없는 파일: {rel}')
    return errors


def main(app):
    app = os.path.abspath(app)
    total = failed = 0
    bundles = [app]
    for root, dirs, _ in os.walk(app):
        for d in dirs:
            if d.endswith('.app') or d.endswith('.framework'):
                bundles.append(os.path.join(root, d))
    # 번들별 주 실행 파일 위치
    mains = {}
    for b in bundles:
        if b.endswith('.app'):
            info = plistlib.load(open(os.path.join(b, 'Contents', 'Info.plist'), 'rb'))
            mains[os.path.realpath(os.path.join(b, 'Contents', 'MacOS', info['CFBundleExecutable']))] = b
        else:
            name = os.path.basename(b)[:-len('.framework')]
            cur = os.path.realpath(os.path.join(b, 'Versions', 'Current'))
            mains[os.path.realpath(os.path.join(cur, name))] = cur
    seen = set()
    for root, _, files in os.walk(app):
        for name in files:
            p = os.path.join(root, name)
            rp = os.path.realpath(p)
            if os.path.islink(p) or rp in seen:
                continue
            with open(p, 'rb') as f:
                head = f.read(4)
            if head not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
                continue
            seen.add(rp)
            total += 1
            try:
                errs, cd = verify_macho(p, mains.get(rp))
            except Exception as e:  # noqa: BLE001
                errs, cd = [str(e)], None
            rel = os.path.relpath(p, app)
            if errs:
                failed += 1
                print(f'  실패 {rel}: {", ".join(errs)}')
            else:
                kind = '번들 주 실행 파일' if rp in mains else '라이브러리/도구'
                print(f'  통과 {rel} [{kind}, {"ad-hoc" if cd["flags"] & 0x2 else "서명"}, {cd["ident"]}]')
    res_fail = 0
    for b in bundles:
        target = b if b.endswith('.app') else os.path.realpath(os.path.join(b, 'Versions', 'Current'))
        errs = verify_resources(target, set(mains))
        if errs:
            res_fail += 1
            print(f'  리소스 실패 {os.path.relpath(b, app)}: {errs[:5]}')
    print(f'\n실행 파일 {total}개 중 {total - failed}개 통과, 번들 {len(bundles)}개 중 리소스 기록 {len(bundles) - res_fail}개 통과')
    return 0 if failed == 0 and res_fail == 0 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))

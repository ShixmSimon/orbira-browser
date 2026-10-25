#!/usr/bin/env python3
"""Build the pinned, vendored Rust DSO. Cargo never accesses the network."""
import argparse, hashlib, os, pathlib, shutil, subprocess, tarfile
p=argparse.ArgumentParser()
p.add_argument('--out',required=True)
p.add_argument('--sdk',required=True)
p.add_argument('--cpu',default='arm64')
a=p.parse_args()
root=pathlib.Path(__file__).resolve().parent
import json
manifest=json.loads((root/'resources/SOURCES.json').read_text())
for name,digest in manifest['files'].items():
    if hashlib.sha256((root/'resources'/name).read_bytes()).hexdigest()!=digest:
        raise SystemExit('Adblock resource integrity mismatch: '+name)
out=pathlib.Path(a.out).resolve()
out.parent.mkdir(parents=True,exist_ok=True)
work=out.parent/'adblock-rust-build'
work.mkdir(exist_ok=True)
archive=root/'vendor.tar.gz'
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
stamp=work/'vendor.sha256'
if not stamp.exists() or stamp.read_text()!=digest:
    shutil.rmtree(work/'vendor',ignore_errors=True)
    with tarfile.open(archive) as tar: tar.extractall(work,filter='data')
    stamp.write_text(digest)
# Separate source/config tree so Chromium's parent .cargo settings cannot alter this crate.
for name in ['Cargo.toml','Cargo.lock','src','lists','resources']:
    source=root/name
    if source.is_dir(): shutil.copytree(source,work/name,dirs_exist_ok=True)
    else: shutil.copy2(source,work/name)
(work/'.cargo').mkdir(exist_ok=True)
(work/'.cargo/config.toml').write_text('[source.crates-io]\nreplace-with="vendored-sources"\n[source.vendored-sources]\ndirectory="'+str(work/'vendor')+'"\n')
triples={'arm64':('aarch64-unknown-linux-ohos','aarch64-linux-ohos'),
         'arm':('armv7-unknown-linux-ohos','arm-linux-ohos'),
         'x64':('x86_64-unknown-linux-ohos','x86_64-linux-ohos')}
rust_target,clang_target=triples[a.cpu]
sdk=pathlib.Path(a.sdk).resolve()
env=os.environ.copy()
# cargo + OHOS 目标 std：优先 rustup（其 1.96.1 工具链含 aarch64-unknown-linux-ohos 目标 std，本 build.py 原设计）。
# Chromium 自带 rust-toolchain 仅含 host(x86_64-unknown-linux-gnu) std、无 OHOS 目标，故仅当它确有该目标 std 才启用。
# root = src/third_party/adblock_rust，root.parent = src/third_party。
rustup=shutil.which('cargo') or (str(pathlib.Path.home()/'.cargo/bin/cargo') if (pathlib.Path.home()/'.cargo/bin/cargo').exists() else None)
bundled_bin=root.parent/'rust-toolchain'/'bin'
bundled_has_ohos=(bundled_bin/'cargo').exists() and (root.parent/'rust-toolchain'/'lib'/'rustlib'/rust_target).exists()
if rustup:
    cargo, targs = rustup, ['+1.96.1']
elif bundled_has_ohos:
    cargo, targs = str(bundled_bin/'cargo'), []
    env['RUSTC']=str(bundled_bin/'rustc')
    env['PATH']=str(bundled_bin)+os.pathsep+env.get('PATH',os.environ.get('PATH',''))
else:
    raise SystemExit(
        'adblock 需要 rustup：未找到 cargo，且 Chromium 自带 rust-toolchain 无 '+rust_target+' 目标 std（仅 host）。\n'
        '请在 WSL 依次执行：\n'
        '  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y\n'
        '  ~/.cargo/bin/rustup toolchain install 1.96.1\n'
        '  ~/.cargo/bin/rustup target add '+rust_target)
env['CARGO_TARGET_DIR']=str(work/'target')
# 链接器：① SDK 自带 Linux clang（上游 canonical）。本机不可用——DevEco NDK 只装了 Windows clang.exe
# （无 extensionless clang，其 wrapper aarch64-unknown-linux-ohos-clang 也 exec 同目录 clang）、WSL 未挂 /mnt/d。
# ② 回退 Chromium 自带 clang：本树全部 C++ 编译/.so 链接均由它驱动（110MB 真二进制，LLVM24）。
#    但其自身资源目录无 ohos builtins（lib/clang/24/lib 无 ohos triple），必须按
#    build/config/ohos/BUILD.gn(170/211/218) 同款补 -resource-dir 与 -L——builtins/crt/libc++ 都在 SDK llvm/lib 下。
src_root=root.parent.parent
extra=[]
linker=sdk/'native/llvm/bin/clang'
if not linker.exists():
    fb=src_root/'third_party/llvm-build/Release+Asserts/bin/clang'
    rdir=sdk/'native/llvm/lib/clang/current'
    if not fb.exists():
        raise SystemExit('找不到链接器：试过 '+str(linker)+' 与 '+str(fb))
    if not rdir.exists():
        raise SystemExit('找不到 clang 资源目录（ohos builtins 所在）：'+str(rdir))
    linker=fb
    extra.append('-resource-dir='+str(rdir))
    if rust_target.startswith('aarch64'):
        extra.append('-L'+str(sdk/'native/llvm/lib/aarch64-linux-ohos'))
        extra.append('-L'+str(rdir/'lib/aarch64-unknown-linux-ohos'))
    print('note: SDK clang 缺失，回退 Chromium clang（附 '+','.join(extra)+'）')
env['CARGO_TARGET_'+rust_target.upper().replace('-','_')+'_LINKER']=str(linker)
# Encoded flags preserve SDK paths containing spaces. No LTO bitcode leaves the DSO.
flags=['-C','relocation-model=pic','-C','link-arg=--target='+clang_target,
    '-C','link-arg=--sysroot='+str(sdk/'native/sysroot'),'-C','link-arg=-Wl,-soname,liblumie_adblock.so']
for f in extra:
    flags+=['-C','link-arg='+f]
env['CARGO_ENCODED_RUSTFLAGS']='\x1f'.join(flags)
subprocess.run([cargo]+targs+['build','--manifest-path',str(work/'Cargo.toml'),'--target',rust_target,
                '--release','--frozen','--offline'],cwd=work,env=env,check=True)
shutil.copy2(work/'target'/rust_target/'release/liblumie_adblock.so',out)

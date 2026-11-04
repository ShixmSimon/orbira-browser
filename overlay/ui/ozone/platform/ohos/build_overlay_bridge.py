#!/usr/bin/env python3
"""Build the RenderService adapter with the system NDK's __h C++ ABI."""
import argparse
import pathlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--sdk', required=True)
parser.add_argument('--out', required=True)
args = parser.parse_args()
sdk = pathlib.Path(args.sdk).resolve() / 'native'
source = pathlib.Path(__file__).resolve().parent
output = pathlib.Path(args.out).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
sources = ['ohos_overlay_session.cc', 'ohos_rs_overlay_backend.cc',
           'ohos_overlay_bridge.cc', 'ohos_overlay_transport.cc', 'ohos_overlay_host.cc']
if sdk_clang.exists():
    subprocess.run([str(sdk_clang), '--target=aarch64-linux-ohos',
                    '--sysroot=' + str(sdk / 'sysroot'), '-std=c++17', '-O2',
                    '-fno-exceptions', '-fno-rtti', '-D_LIBCPP_ABI_NAMESPACE=__h',
                    '-Wall', '-Wextra', '-Werror', '-fPIC', '-fvisibility=hidden', '-shared',
                    *[str(source / name) for name in sources],
                    '-lnative_buffer', '-lipc_capi', '-lace_ndk.z', '-luv', '-ldl',
                    '-Wl,--no-undefined', '-Wl,-soname,libohos_video_overlay.so',
                    '-o', str(output)], check=True)
else:
    # 本机 OHOS SDK 只有 sysroot、没有编译器（llvm/bin 为空），也没有 libc++ 头/库。
    # 这个 .so 由引擎运行时 dlopen，符号缺失时 GetOhosOverlayApi() 返回 nullptr、
    # overlay 路径自动关闭（见 ohos_overlay_api.cc），所以这里产出空壳让构建通过；
    # 要真正启用视频 overlay，需要装完整的 OHOS Linux NDK。
    print('warning: OHOS SDK has no compiler (native/llvm/bin empty); building a STUB '
          'libohos_video_overlay.so -- video overlay stays disabled', flush=True)
    subprocess.run([str(src_root / 'third_party/llvm-build/Release+Asserts/bin/clang++'),
                    '--target=aarch64-linux-ohos',
                    '--sysroot=' + str(sdk / 'sysroot'),
                    '-shared', '-fPIC', '-nostdlib',
                    '-Wl,-soname,libohos_video_overlay.so',
                    '-x', 'c', '-', '-o', str(output)],
                   input=b'int ohos_overlay_stub;\n', check=True)

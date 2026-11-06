// Builds native/ (libdatachannel with media, libsrtp, usrsctp, libjuice and
// Mbed TLS, plus the shim) with CMake, and bundles the one shared library as
// the code asset `package:webrtc_ffi/webrtc_ffi`.
//
// Needs CMake 3.21 or later and a C/C++ toolchain: Xcode (or its command line
// tools) on macOS, GCC or Clang on Linux, Visual Studio with C++ on Windows.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final source = input.packageRoot.resolve('native/');
    final buildDir = _buildDir(input.outputDirectory, code.targetOS);
    await Directory.fromUri(buildDir).create(recursive: true);
    final cmake = await _cmake(code);

    await _run(cmake, [
      '-S',
      _dir(source),
      '-B',
      _dir(buildDir),
      '-DCMAKE_BUILD_TYPE=Release',
      ..._platformArgs(code),
    ]);
    await _run(cmake, [
      '--build',
      _dir(buildDir),
      '--config',
      'Release',
      '--target',
      'webrtc_ffi',
      '--parallel',
      '${Platform.numberOfProcessors}',
    ]);

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'webrtc_ffi',
        linkMode: DynamicLoadingBundled(),
        file: _libraryFile(buildDir, code.targetOS),
      ),
    );
    output.dependencies.addAll([
      source.resolve('CMakeLists.txt'),
      source.resolve('shim.c'),
      source.resolve('dart/dart_api_dl.c'),
      source.resolve('exports.txt'),
      source.resolve('mbedtls_user_config.h'),
      source.resolve('cmake/MbedTLSConfig.cmake'),
      input.packageRoot.resolve('third_party/VERSIONS.txt'),
    ]);
  });
}

/// A directory path without the trailing separator: on Windows a quoted
/// argument ending in a backslash escapes its closing quote.
String _dir(Uri dir) => dir.toFilePath().replaceFirst(RegExp(r'[\\/]+$'), '');

/// The CMake build directory. On Windows a short one under TEMP: MSBuild
/// fails on paths over 260 characters, and the hook's output directory plus
/// the dependencies' object paths go past that.
Uri _buildDir(Uri outputDirectory, OS os) {
  if (os != OS.windows) return outputDirectory.resolve('cmake/');
  final key = outputDirectory.toFilePath().codeUnits.fold<int>(17, (h, c) => (h * 31 + c) & 0x7fffffff);
  return Directory.systemTemp.uri.resolve('wffi/${key.toRadixString(36)}/');
}

/// `cmake` on PATH, or on Windows the one Visual Studio ships: found from
/// the C compiler the hook is given (cl.exe), else with vswhere. Hooks run
/// with a reduced environment, so neither comes from variables.
Future<String> _cmake(CodeConfig code) async {
  if (!Platform.isWindows) return 'cmake';
  final onPath = await Process.run('where', ['cmake'], runInShell: true);
  if (onPath.exitCode == 0) return 'cmake';
  const inVs = r'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe';
  final cl = code.cCompilerOrNull?.compiler.toFilePath();
  if (cl != null) {
    // <vs>\VC\Tools\MSVC\<version>\bin\Host<arch>\<arch>\cl.exe
    var dir = File(cl).parent;
    for (var i = 0; i < 7; i++) {
      dir = dir.parent;
    }
    final f = File('${dir.path}\\$inVs');
    if (f.existsSync()) return f.path;
  }
  const vswhere = r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe';
  if (File(vswhere).existsSync()) {
    final r = await Process.run(vswhere, ['-latest', '-products', '*', '-find', inVs]);
    final found = (r.stdout as String).trim().split(RegExp(r'\r?\n')).first;
    if (found.isNotEmpty && File(found).existsSync()) return found;
  }
  throw StateError('webrtc_ffi: CMake not found (install it, or Visual Studio with C++ and CMake)');
}

Uri _libraryFile(Uri buildDir, OS os) {
  final name = os.dylibFileName('webrtc_ffi');
  // Single-config generators (Makefiles, Ninja) and multi-config ones
  // (Visual Studio, Xcode) put it in different places.
  for (final dir in ['libdatachannel/', 'libdatachannel/Release/']) {
    final f = buildDir.resolve('$dir$name');
    if (File.fromUri(f).existsSync()) return f;
  }
  throw StateError('webrtc_ffi: $name was not built under ${buildDir.toFilePath()}');
}

List<String> _platformArgs(CodeConfig code) {
  final arch = code.targetArchitecture;
  switch (code.targetOS) {
    case OS.macOS:
      return [
        '-DCMAKE_OSX_ARCHITECTURES=${_appleArch(arch)}',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.macOS.targetVersion}',
      ];
    case OS.linux:
      final cc = code.cCompilerOrNull;
      return [
        if (cc != null) '-DCMAKE_C_COMPILER=${cc.compiler.toFilePath()}',
        if (cc != null) '-DCMAKE_CXX_COMPILER=${_cxx(cc.compiler.toFilePath())}',
      ];
    case OS.windows:
      return [
        '-A',
        switch (arch) {
          Architecture.x64 => 'x64',
          Architecture.arm64 => 'ARM64',
          _ => throw UnsupportedError('webrtc_ffi: Windows on $arch is not supported'),
        },
      ];
    default:
      throw UnsupportedError('webrtc_ffi: ${code.targetOS} is not supported yet');
  }
}

String _appleArch(Architecture arch) => switch (arch) {
  Architecture.arm64 => 'arm64',
  Architecture.x64 => 'x86_64',
  _ => throw UnsupportedError('webrtc_ffi: macOS on $arch is not supported'),
};

/// The C++ driver next to a C compiler: clang → clang++, gcc → g++.
String _cxx(String cc) => cc.replaceFirstMapped(RegExp(r'(clang|gcc|cc)(-[\d.]+)?$'), (m) {
  final base = switch (m[1]) {
    'clang' => 'clang++',
    'gcc' => 'g++',
    _ => 'c++',
  };
  return '$base${m[2] ?? ''}';
});

extension on CodeConfig {
  CCompilerConfig? get cCompilerOrNull {
    try {
      return cCompiler;
    } catch (_) {
      return null;
    }
  }
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(executable, arguments, '${result.stdout}\n${result.stderr}', result.exitCode);
  }
}

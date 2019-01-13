// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:build_modules/build_modules.dart';
import 'package:meta/meta.dart';

import '../artifacts.dart';
import '../base/process_manager.dart';
import '../compile.dart';
import '../globals.dart';


const vmKernelModuleExtension = '.vm.dill';
const vmKernelEntrypointExtension = '.vm.app.dill';

/// A builder which creates a kernel file for a flutter app from dart
/// modules and an entrypoint.
///
/// Unlike the package:build kernel builders, this creates a single kernel from
/// dart source using the frontend server binary. Incremental kernel is not
/// necessarily beneficial to a hot reload based workflow.
///
// TODO(jonahwilliams): figure out what dep file is used for.
class FlutterKernelBuilder implements Builder {
  const FlutterKernelBuilder({
    @required this.target,
    @required this.aot,
    @required this.trackWidgetCreation,
    @required this.targetProductVm,
    @required this.linkPlatformKernelIn,
    @required this.extraFrontEndOptions,
    @required this.sdkRoot,
    @required this.packagesPath,
    this.incrementalCompilerByteStorePath,
    this.fileSystemRoots,
  });

  final String target;
  final String packagesPath;
  final String sdkRoot;
  final String incrementalCompilerByteStorePath;
  final bool aot;
  final bool trackWidgetCreation;
  final bool targetProductVm;
  final bool linkPlatformKernelIn;
  final List<String> extraFrontEndOptions;
  final List<String> fileSystemRoots;

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '.dart': <String>['.app.dill'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (!buildStep.inputId.path.contains('main.dart')) {
      return;
    }
    final AssetId moduleId = buildStep.inputId.changeExtension('.vm.module');
    final Module module = Module.fromJson(json.decode(await buildStep.readAsString(moduleId)));
    final AssetId outputId = module.primarySource.changeExtension('.app.dill');
    final File outputFile = scratchSpace.fileFor(outputId);
    //// QUESTIONABLE
    var transitiveDeps = await module.computeTransitiveDependencies(buildStep);
    var transitiveKernelDeps = <AssetId>[];
    var transitiveSourceDeps = <AssetId>[];

    await Future.wait(transitiveDeps.map((dep) => _addModuleDeps(
        dep,
        module,
        transitiveKernelDeps,
        transitiveSourceDeps,
        buildStep,
        vmKernelModuleExtension)));

    var allAssetIds = Set<AssetId>()
      ..addAll(module.sources)
      ..addAll(transitiveKernelDeps)
      ..addAll(transitiveSourceDeps);
    await scratchSpace.ensureAssets(allAssetIds, buildStep);

    /////
    final String frontendServer = artifacts.getArtifactPath(
      Artifact.frontendServerSnapshotForEngineDartSdk
    );
    final String engineDartPath = artifacts.getArtifactPath(Artifact.engineDartBinary);
    final List<String> command = <String>[
      engineDartPath,
      frontendServer,
      '--sdk-root',
      sdkRoot,
      '--strong',
      '--target=flutter',
    ];
    if (trackWidgetCreation) {
      command.add('--track-widget-creation');
    }
    if (!linkPlatformKernelIn) {
      command.add('--no-link-platform');
    }
    if (aot) {
      command.add('--aot');
      command.add('--tfa');
    }
    if (targetProductVm) {
      command.add('-Ddart.vm.product=true');
    }
    if (incrementalCompilerByteStorePath != null) {
      command.add('--incremental');
    }
    command.addAll(<String>['--packages', packagesPath]);
    final Uri mainUri = PackageUriMapper.findUri(target, packagesPath);
    command.addAll(<String>['--output-dill', outputFile.path]);
    // if (depFilePath != null && (fileSystemRoots == null || fileSystemRoots.isEmpty)) {
    //   command.addAll(<String>['--depfile', depFilePath]);
    // }
    if (fileSystemRoots != null) {
      for (String root in fileSystemRoots) {
        command.addAll(<String>['--filesystem-root', root]);
      }
    }
    command.addAll(<String>['--filesystem-scheme', multiRootScheme]);
    if (extraFrontEndOptions != null) {
      command.addAll(extraFrontEndOptions);
    }
    command.add(mainUri?.toString() ?? target);

    printTrace(command.join(' '));
    final Process server = await processManager
        .start(command)
        .catchError((dynamic error, StackTrace stack) {
      printError('Failed to start frontend server $error, $stack');
    });

    final StdoutHandler _stdoutHandler = StdoutHandler();

    server.stderr
      .transform<String>(utf8.decoder)
      .listen(printError);
    server.stdout
      .transform<String>(utf8.decoder)
      .transform<String>(const LineSplitter())
      .listen(_stdoutHandler.handler);
    final int exitCode = await server.exitCode;
    printTrace('exitCode: $exitCode');
    final CompilerOutput output = await _stdoutHandler.compilerOutput.future;
    printTrace(output.outputFilename);
    await scratchSpace.copyOutput(outputId, buildStep);
    //await scratchSpace.copyOutput(outputKernelDepId, buildStep);
  }

  Future<void> _addModuleDeps(
    Module dependency,
    Module root,
    List<AssetId> transitiveKernelDeps,
    List<AssetId> transitiveSourceDeps,
    BuildStep buildStep,
    String outputExtension) async {
  var kernelId = dependency.primarySource.changeExtension(outputExtension);
  if (await buildStep.canRead(kernelId)) {
    // If we can read the kernel file, but it depends on any module in this
    // package, then we need to only provide sources for that file since its
    // dependencies in this package will only be providing sources as well.
    if ((await dependency.computeTransitiveDependencies(buildStep))
        .any((m) => m.primarySource.package == root.primarySource.package)) {
      transitiveSourceDeps.addAll(dependency.sources);
    } else {
      transitiveKernelDeps.add(kernelId);
    }
  } else {
    transitiveSourceDeps.addAll(dependency.sources);
  }
}
}

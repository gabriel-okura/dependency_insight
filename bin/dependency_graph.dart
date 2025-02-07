import "dart:io";

import "package:analyzer/dart/analysis/analysis_context.dart";
import "package:analyzer/dart/analysis/analysis_context_collection.dart";
import "package:analyzer/dart/analysis/results.dart";
import "package:analyzer/dart/element/element2.dart";
import "package:analyzer/file_system/physical_file_system.dart";

import 'package:graphs/graphs.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw "Needs 1 argument.";
  }
  List<String> paths = [];
  File f = new File(arguments.single);
  if (f.existsSync()) {
    if (f.path.endsWith(".dart")) {
      paths.add(f.path);
    }
  } else {
    Directory d = new Directory(arguments.single);
    if (d.existsSync()) {
      for (FileSystemEntity entity in d.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith(".dart")) {
          paths.add(entity.path);
        }
      }
    }
  }
  if (paths.isEmpty) {
    throw "No paths found.";
  }
  print("Given ${paths.length} dart file(s) as input.");
  print("");

  await doStuff(paths);
}

Future<void> doStuff(List<String> paths) async {
  AnalysisContextCollection collection = AnalysisContextCollection(
    includedPaths: paths,
    resourceProvider: PhysicalResourceProvider.INSTANCE,
  );

  List<LibraryElement2> queue = [];
  for (String path in paths) {
    AnalysisContext context = collection.contextFor(path);
    SomeResolvedLibraryResult resolvedLibraryResult = await context
        .currentSession
        .getResolvedLibrary(path);
    if (resolvedLibraryResult is ResolvedLibraryResult) {
      queue.add(resolvedLibraryResult.element2);
    }
  }

  Map<Uri, Set<Uri>> importExportGraph = {};
  Map<Uri, Set<Uri>> dependencyGraph = {};
  while (queue.isNotEmpty) {
    LibraryElement2 element = queue.removeLast();
    if (importExportGraph.containsKey(element.uri)) continue;
    Set<Uri> edges = importExportGraph[element.uri] = {};
    for (LibraryFragment fragment in element.fragments) {
      for (LibraryElement2 import in fragment.importedLibraries2) {
        if (import.uri.isScheme("dart")) continue;
        edges.add(import.uri);
        queue.add(import);
        (dependencyGraph[import.uri] ??= {}).add(element.uri);
      }
      for (LibraryExport export in fragment.libraryExports2) {
        LibraryElement2? exportedLibrary = export.exportedLibrary2;
        if (exportedLibrary != null) {
          if (exportedLibrary.uri.isScheme("dart")) continue;
          edges.add(exportedLibrary.uri);
          queue.add(exportedLibrary);
          (dependencyGraph[exportedLibrary.uri] ??= {}).add(element.uri);
        } else {
          print("WARNING: Export in ${element.uri} was null: $export");
        }
      }
    }
  }

  Set<Uri> invalidate(Uri library) {
    Set<Uri> result = {};
    List<Uri> queue = [];
    queue.add(library);
    while (queue.isNotEmpty) {
      Uri library = queue.removeLast();
      if (!result.add(library)) continue;
      for (Uri dependency in dependencyGraph[library] ?? const <Uri>[]) {
        queue.add(dependency);
      }
    }
    return result;
  }

  print("Found ${importExportGraph.length} libraries");
  print("");

  print("Strongly connected components:");
  final List<List<Uri>> components = stronglyConnectedComponents<Uri>(
    importExportGraph.keys,
    (Uri node) {
      return importExportGraph[node] ?? (throw "Nothing found for $node");
    },
  );
  components.sort((a, b) => a.length.compareTo(b.length));
  for (List<Uri> component in components) {
    print("Component with ${component.length} libraries:");
    Set<Uri> ifInvalidate = invalidate(component.first);
    for (Uri uri in component) {
      print(" => $uri");
      assert(() {
        Set<Uri> ifInvalidate2 = invalidate(uri);
        if (ifInvalidate2.length != ifInvalidate.length) {
          assert(
            false,
            "Invalidating ${component.first} and $uri produces a different "
            "number of libraries, but shouldn't because they're in the same "
            "strongly connected component.",
          );
        }
        ifInvalidate2.removeAll(ifInvalidate);
        if (ifInvalidate2.isNotEmpty) {
          assert(
            false,
            "Invalidating ${component.first} and $uri produces a different "
            "set of libraries, but shouldn't because they're in the same "
            "strongly connected component.",
          );
        }
        return true;
      }());
    }

    print(
      "Invalidating any will invalidate "
      "${ifInvalidate.length} libraries.",
    );
    print("");
  }
}


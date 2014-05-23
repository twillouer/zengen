// Copyright (c) 2014, Alexandre Ardhuin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

library zengen.transformer;

import 'dart:async';

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/element.dart';
import 'package:barback/barback.dart';
import 'package:code_transformers/resolver.dart';
import 'package:path/path.dart' as p;

import 'package:zengen/zengen.dart';

final MODIFIERS = <ContentModifier>[//
  new ToStringAppender(), //
  new EqualsAndHashCodeAppender(),//
];

abstract class ContentModifier {
  List<Transformation> accept(LibraryElement lib);
}

class ZengenTransformer extends TransformerGroup {
  ZengenTransformer.asPlugin() : this._(new ModifierTransformer());
  ZengenTransformer._(ModifierTransformer mt) : super([//
        [new PartsMergeTransformer()], //
      ]..addAll(new Iterable.generate(3, (_) => [mt])));
}

class PartsMergeTransformer extends Transformer {
  PartsMergeTransformer();

  String get allowedExtensions => ".dart";

  Future apply(Transform transform) {
    return transform.primaryInput.readAsString().then((content) {
      final id = transform.primaryInput.id;
      final cu = parseCompilationUnit(content);

      // parts will be merged into the library. So we skip it.
      if (cu.directives.any((e) => e is PartOfDirective)) {
        transform.logger.info("part $id will be merged", asset: id);
        transform.consumePrimary();
        return null;
      }

      // merge parts if any
      final transformations = cu.directives.where((e) => e is PartDirective
          ).map((PartDirective part) {
        final partId = new AssetId(id.package, p.joinAll([]
            ..addAll(p.split(id.path)..removeLast())
            ..addAll(p.split(part.uri.stringValue))));
        return transform.readInputAsString(partId).then((source) =>
            new Transformation(part.offset, part.end, removePartOf(source)));
      });
      return Future.wait(transformations).then((List<Transformation>
          transformations) {
        if (transformations.isEmpty) return;
        content = applyTransformations(content, transformations);
        transform.addOutput(new Asset.fromString(id, content));
      });
    });
  }

  String removePartOf(String content) => applyTransformations(content,
      parseCompilationUnit(content).directives.where((e) => e is PartOfDirective).map(
      (d) => new Transformation.deletation(d.offset, d.end)));
}


class ModifierTransformer extends Transformer {
  Resolvers resolvers = new Resolvers(dartSdkDirectory);
  List<AssetId> unmodified = [];

  ModifierTransformer();

  String get allowedExtensions => ".dart";

  Future apply(Transform transform) {
    final id = transform.primaryInput.id;
    if (unmodified.contains(id)) return null;
    return resolvers.get(transform).then((resolver) {
      return new Future(() => applyResolver(transform, resolver)).whenComplete(
          () => resolver.release());
    });
  }

  applyResolver(Transform transform, Resolver resolver) {
    final id = transform.primaryInput.id;
    final lib = resolver.getLibrary(id);

    final transaction = resolver.createTextEditTransaction(lib);
    traverseModifiers(lib, (List<Transformation> transformations) {
      for (final t in transformations) {
        transaction.edit(t.begin, t.end, t.content);
      }
    });
    if (transaction.hasEdits) {
      final np = transaction.commit();
      np.build('');
      final newContent = np.text;
      transform.logger.fine("new content for $id : \n$newContent", asset: id);
      transform.addOutput(new Asset.fromString(id, newContent));
    } else {
      unmodified.add(id);
    }
  }
}


void traverseModifiers(LibraryElement
    lib, onTransformations(List<Transformation> transformations)) {
  bool modifications = true;
  while (modifications) {
    modifications = false;
    for (final modifier in MODIFIERS) {
      final transformations = modifier.accept(lib);
      if (transformations.isNotEmpty) {
        onTransformations(transformations);
        modifications = true;
        return;
      }
    }
  }
}

String applyTransformations(String content, List<Transformation>
    transformations) {
  int padding = 0;
  for (final t in transformations) {
    content = content.substring(0, t.begin + padding) + t.content +
        content.substring(t.end + padding);
    padding += t.content.length - (t.end - t.begin);
  }
  return content;
}

class Transformation {
  final int begin, end;
  final String content;
  Transformation(this.begin, this.end, this.content);
  Transformation.insertion(int index, this.content)
      : begin = index,
        end = index;
  Transformation.deletation(this.begin, this.end) : content = '';
}

class ToStringAppender implements ContentModifier {
  @override
  List<Transformation> accept(LibraryElement lib) {
    final transformations = [];
    lib.unit.declarations.where((d) => d is ClassDeclaration).where(
        (ClassDeclaration c) => getAnnotations(c, 'ToString').isNotEmpty).forEach(
        (ClassDeclaration clazz) {
      final annotation = getToString(clazz);
      final callSuper = annotation.callSuper == true;
      final exclude = annotation.exclude == null ? [] : annotation.exclude;
      final fieldNames = getFieldNames(clazz).where((f) => !exclude.contains(f)
          );

      final toString = '@generated @override String toString() => '
          '"${clazz.name.name}(' + //
      (callSuper ? 'super=\${super.toString()}' : '') + //
      (callSuper && fieldNames.isNotEmpty ? ', ' : '') + //
      fieldNames.map((f) => '$f=\$$f').join(', ') + ')";';

      final index = clazz.end - 1;
      if (!isMethodDefined(clazz, 'toString')) {
        transformations.add(new Transformation.insertion(index, '  $toString\n')
            );
      }
    });
    return transformations;
  }

  ToString getToString(ClassDeclaration clazz) {
    final Annotation annotation = getAnnotations(clazz, 'ToString').first;

    if (annotation == null) return null;

    bool callSuper = null;
    List<String> exclude = null;

    final NamedExpression callSuperPart =
        annotation.arguments.arguments.firstWhere((e) => e is NamedExpression &&
        e.name.label.name == 'callSuper', orElse: () => null);
    if (callSuperPart != null) {
      callSuper = (callSuperPart.expression as BooleanLiteral).value;
    }

    final NamedExpression excludePart =
        annotation.arguments.arguments.firstWhere((e) => e is NamedExpression &&
        e.name.label.name == 'exclude', orElse: () => null);
    if (excludePart != null) {
      exclude = (excludePart.expression as ListLiteral).elements.map(
          (StringLiteral sl) => sl.stringValue).toList();
    }

    return new ToString(callSuper: callSuper, exclude: exclude);
  }
}

class EqualsAndHashCodeAppender implements ContentModifier {
  @override
  List<Transformation> accept(LibraryElement lib) {
    final transformations = [];
    lib.unit.declarations.where((d) => d is ClassDeclaration).where(
        (ClassDeclaration c) => getAnnotations(c, 'EqualsAndHashCode').isNotEmpty
        ).forEach((ClassDeclaration clazz) {
      final annotation = getEqualsAndHashCode(clazz);
      final callSuper = annotation.callSuper == true;
      final exclude = annotation.exclude == null ? [] : annotation.exclude;
      final fieldNames = getFieldNames(clazz).where((f) => !exclude.contains(f)
          );

      final hashCodeValues = fieldNames.toList();
      if (callSuper) hashCodeValues.insert(0, 'super.hashCode');
      final hashCode = '@generated @override int get hashCode => '
          'hashObjects([' + hashCodeValues.join(', ') + ']);';

      final equals = '@generated @override bool operator==(o) => '
          'o is ${clazz.name.name}' + (callSuper ? ' && super == o' : '') +
          fieldNames.map((f) => ' && o.$f == $f').join() + ';';

      final index = clazz.end - 1;
      if (!isMethodDefined(clazz, 'hashCode')) {
        transformations.add(new Transformation.insertion(index, '  $hashCode\n')
            );
      }
      if (!isMethodDefined(clazz, '==')) {
        transformations.add(new Transformation.insertion(index, '  $equals\n'));
      }
    });
    return transformations;
  }

  EqualsAndHashCode getEqualsAndHashCode(ClassDeclaration clazz) {
    final Annotation annotation = getAnnotations(clazz, 'EqualsAndHashCode'
        ).first;

    if (annotation == null) return null;

    bool callSuper = null;
    List<String> exclude = null;

    final NamedExpression callSuperPart =
        annotation.arguments.arguments.firstWhere((e) => e is NamedExpression &&
        e.name.label.name == 'callSuper', orElse: () => null);
    if (callSuperPart != null) {
      callSuper = (callSuperPart.expression as BooleanLiteral).value;
    }

    final NamedExpression excludePart =
        annotation.arguments.arguments.firstWhere((e) => e is NamedExpression &&
        e.name.label.name == 'exclude', orElse: () => null);
    if (excludePart != null) {
      exclude = (excludePart.expression as ListLiteral).elements.map(
          (StringLiteral sl) => sl.stringValue).toList();
    }

    return new EqualsAndHashCode(callSuper: callSuper, exclude: exclude);
  }
}

Iterable<String> getFieldNames(ClassDeclaration clazz) => clazz.members.where(
    (m) => m is FieldDeclaration && !m.isStatic).expand((FieldDeclaration f) =>
    f.fields.variables.map((v) => v.name.name));

const _LIBRARY_NAME = 'zengen';

Iterable<Annotation> getAnnotations(Declaration declaration, String name) =>
    declaration.metadata.where((m) => m.element.library.name == _LIBRARY_NAME &&
    m.element is ConstructorElement && m.element.enclosingElement.name == name);

bool isMethodDefined(ClassDeclaration clazz, String methodName) =>
    clazz.members.any((m) => m is MethodDeclaration && m.name.name == methodName);

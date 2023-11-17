import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:butterfly_api/butterfly_text.dart' as text;
import 'package:xml/xml.dart';

List<PathPoint> toPoints(List<double> data) {
  final points = <PathPoint>[];
  final iterator = data.iterator;
  while (iterator.moveNext()) {
    final x = iterator.current;
    if (iterator.moveNext()) {
      final y = iterator.current;
      points.add(PathPoint(x, y));
    }
  }
  return points;
}

int _importColor(String value) {
  final number = int.parse(value.substring(1), radix: 16);
  return (number >> 8 | number << 24);
}

String _exportColor(int value) {
  final number = (value >> 8 | value << 24);
  return '#${number.toRadixString(16)}';
}

(NoteData, PadElement?) getElement(
    NoteData data, XmlElement element, String layerName) {
  PadElement? get() {
    switch (element.qualifiedName) {
      case 'stroke':
        return PenElement(
          property: PenProperty(
            color: _importColor(element.getAttribute('color')!),
            strokeWidth: double.parse(element.getAttribute('width')!),
          ),
          points: toPoints(element.innerText
              .split(' ')
              .map((e) => double.parse(e))
              .toList()),
          layer: layerName,
        );
      case 'text':
        return TextElement(
          area: text.TextArea(
              paragraph: text.TextParagraph.text(
            textSpans: [
              text.TextSpan.text(
                text: element.innerText,
                property: text.SpanProperty.defined(
                  color: _importColor(element.getAttribute('color')!),
                  size: double.parse(element.getAttribute('size')!),
                ),
              ),
            ],
          )),
          position: Point(double.parse(element.getAttribute('x')!),
              double.parse(element.getAttribute('y')!)),
          layer: layerName,
        );
      case 'image':
        final imageData = UriData.parse(element.innerText);
        String path;
        (data, path) = data.addImage(imageData.contentAsBytes(), 'png');
        final left = double.parse(element.getAttribute('x')!);
        final top = double.parse(element.getAttribute('y')!);
        final right = double.parse(element.getAttribute('right')!);
        final bottom = double.parse(element.getAttribute('bottom')!);
        return ImageElement(
          source: Uri.file(path, windows: false).toString(),
          position: Point(left, top),
          layer: layerName,
          height: bottom - top,
          width: right - left,
        );
      default:
        return null;
    }
  }

  return (data, get());
}

NoteData xoppMigrator(Uint8List data) {
  final doc = XmlDocument.parse(utf8.decode(GZipDecoder().decodeBytes(data)));
  final xournal = doc.getElement('xournal')!;
  var note = NoteData(Archive());
  note = note.setMetadata(FileMetadata(
    type: NoteFileType.document,
    name: xournal.getElement('title')!.innerText,
  ));
  for (final entry in xournal.findElements('page').toList().asMap().entries) {
    final elements = <PadElement>[];
    final page = entry.value;
    final layerName = 'Layer ${entry.key}';
    for (final layer in page.findElements('layer')) {
      for (final element in layer.childElements) {
        PadElement? current;
        (note, current) = getElement(note, element, layerName);
        if (current != null) {
          elements.add(current);
        }
      }
    }
    final backgroundXml = page.getElement('background')!;
    final backgroundStyle = backgroundXml.getAttribute('style');
    final backgroundColor =
        _importColor(backgroundXml.getAttribute('color')!.substring(1));
    final background = switch (backgroundXml.getAttribute('type')) {
      'solid' => Background.texture(
            texture: SurfaceTexture.pattern(
          boxXColor: backgroundColor,
          boxYColor: backgroundColor,
          boxYSpace:
              backgroundStyle == 'ruled' || backgroundStyle == 'lined' ? 20 : 0,
          boxXSpace: backgroundStyle == 'ruled' ? 20 : 0,
        )),
      _ => null,
    };
    (note, _) = note.addPage(DocumentPage(
      content: elements,
      backgrounds: [
        if (background != null) background,
      ],
    ));
  }
  return note;
}

Uint8List xoppExporter(NoteData document) {
  final builder = XmlBuilder();
  builder.processing('xml', 'version="1.0" encoding="UTF-8"');
  builder.element('xournal',
      attributes: {'creator': 'Butterfly', 'fileversion': '4'}, nest: () {
    final metadata = document.getMetadata();
    builder.element('title', nest: metadata?.name);
    for (final pageName in document.getPages()) {
      final page = document.getPage(pageName);
      if (page == null) continue;
      builder.element('page', nest: () {
        builder.element('background', attributes: {
          'type': 'solid',
          'color':
              _exportColor(page.backgrounds.firstOrNull?.defaultColor ?? 0),
          'style': 'plain',
        });
        for (final element in page.content) {
          switch (element) {
            case PenElement e:
              builder.element('stroke', attributes: {
                'color': _exportColor(e.property.color),
                'width': e.property.strokeWidth.toString(),
              }, nest: () {
                builder.text(e.points.map((e) => '${e.x} ${e.y}').join(' '));
              });
              break;
            case LabelElement e:
              final styleSheet = e.styleSheet.resolveStyle(document);
              final style = e is TextElement
                  ? styleSheet
                      ?.resolveParagraphProperty(e.area.paragraph.property)
                      ?.span
                  : styleSheet?.getParagraphProperty('p')?.span;
              builder.element('text', attributes: {
                'color': _exportColor(style?.color ?? 0),
                'size': (style?.size ?? 12).toString(),
                'x': e.position.x.toString(),
                'y': e.position.y.toString(),
              }, nest: () {
                builder.text(e.text);
              });
            case ImageElement e:
              final imageData = document.getAsset(Uri.parse(e.source).path);
              builder.element('image', attributes: {
                'left': e.position.x.toString(),
                'top': e.position.y.toString(),
                'right': (e.position.x + e.width).toString(),
                'bottom': (e.position.y + e.height).toString(),
              }, nest: () {
                builder.text(
                    UriData.fromBytes(imageData ?? [], mimeType: 'image/png')
                        .toString());
              });
            default:
              break;
          }
        }
      });
    }
  });
  return Uint8List.fromList(
      GZipEncoder().encode(builder.buildDocument().toXmlString(pretty: true))!);
}

import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

/// Spritesheet metadata in the shape the FastPix images service returns.
///
/// Tiles are laid out [columns] per row, sized [tile], and start every [step]
/// seconds unless [starts] gives explicit start times. [interval] is included
/// only when set, as for an advanced spritesheet.
String spritesheetJson({
  required int count,
  int columns = 5,
  ({int width, int height}) tile = (width: 256, height: 160),
  double? step,
  double? duration,
  int? interval,
  List<double>? starts,
}) {
  final gap = step ?? (interval?.toDouble() ?? 10);
  final tileWidth = tile.width;
  final tileHeight = tile.height;
  return jsonEncode(<String, Object?>{
    'url': 'https://images.fastpix.com//ignored/Spritesheet.jpg',
    'tile_width': tileWidth,
    'tile_height': tileHeight,
    'duration': duration ?? count * gap,
    if (interval != null) 'interval': interval,
    'tiles': <Map<String, num>>[
      for (var i = 0; i < count; i++)
        <String, num>{
          'start': starts?[i] ?? i * gap,
          'x': (i % columns) * tileWidth,
          'y': (i ~/ columns) * tileHeight,
        },
    ],
  });
}

/// A PNG of [width] x [height] solid pixels, for decode tests.
///
/// Encoded in Dart rather than rendered with `Picture.toImage`, which needs the
/// GPU and stalls under the test binding.
Future<Uint8List> pngBytes(int width, int height) async {
  final raw = BytesBuilder();
  final row = Uint8List(1 + width * 3); // filter byte 0, then RGB
  for (var x = 0; x < width; x++) {
    row[1 + x * 3] = 0x33;
    row[2 + x * 3] = 0x66;
    row[3 + x * 3] = 0xCC;
  }
  for (var y = 0; y < height; y++) {
    raw.add(row);
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2) // colour type: RGB
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);

  final png = BytesBuilder()
    ..add(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  _chunk(png, 'IHDR', header.buffer.asUint8List());
  _chunk(png, 'IDAT', Uint8List.fromList(zlib.encode(raw.takeBytes())));
  _chunk(png, 'IEND', Uint8List(0));
  return png.takeBytes();
}

void _chunk(BytesBuilder out, String type, Uint8List data) {
  final typeBytes = ascii.encode(type);
  out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
  out.add(typeBytes);
  out.add(data);
  final crc = _crc32(<int>[...typeBytes, ...data]);
  out.add((ByteData(4)..setUint32(0, crc)).buffer.asUint8List());
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

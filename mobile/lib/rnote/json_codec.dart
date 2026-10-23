import 'dart:convert';

/// JSON helpers that keep unsigned 64 bit integers (e.g. the `seed` of rough
/// and textured styles) intact.
///
/// Dart's `jsonDecode` turns integers that do not fit into a signed 64 bit
/// integer into doubles, which would corrupt them when the document is saved
/// again (Rnote's serde expects an `u64`). Such literals are replaced with a
/// marked string before decoding and written back verbatim when encoding.
const String _u64Marker = '\u0000u64:';

/// A big unsigned integer kept as its decimal representation.
class U64 {
  final String digits;
  const U64(this.digits);

  factory U64.fromInt(int v) => U64(v.toUnsigned(64).toString());

  BigInt get value => BigInt.parse(digits);

  @override
  String toString() => digits;
}

Object? decodeJsonPreservingU64(String text) {
  final protected = _protectLargeIntegers(text);
  final decoded = jsonDecode(protected);
  return identical(protected, text) ? decoded : _restoreMarkers(decoded);
}

String _protectLargeIntegers(String text) {
  StringBuffer? out;
  var last = 0;
  var inString = false;
  final len = text.length;
  var i = 0;
  while (i < len) {
    final c = text.codeUnitAt(i);
    if (inString) {
      if (c == 0x5C) {
        i += 2;
        continue;
      }
      if (c == 0x22) inString = false;
      i++;
      continue;
    }
    if (c == 0x22) {
      inString = true;
      i++;
      continue;
    }
    if (c >= 0x30 && c <= 0x39) {
      final start = i;
      while (i < len) {
        final d = text.codeUnitAt(i);
        if (d < 0x30 || d > 0x39) break;
        i++;
      }
      final isInteger = i >= len ||
          (text.codeUnitAt(i) != 0x2E &&
              text.codeUnitAt(i) != 0x65 &&
              text.codeUnitAt(i) != 0x45);
      final negative = start > 0 && text.codeUnitAt(start - 1) == 0x2D;
      // 9223372036854775807 has 19 digits, everything from there on may overflow.
      if (isInteger && !negative && i - start >= 19) {
        final digits = text.substring(start, i);
        if (BigInt.parse(digits) > BigInt.from(9223372036854775807)) {
          out ??= StringBuffer();
          out.write(text.substring(last, start));
          out.write('"\\u0000u64:$digits"');
          last = i;
        }
      }
      continue;
    }
    i++;
  }
  if (out == null) return text;
  out.write(text.substring(last));
  return out.toString();
}

Object? _restoreMarkers(Object? v) {
  if (v is String && v.startsWith(_u64Marker)) {
    return U64(v.substring(_u64Marker.length));
  }
  if (v is Map<String, dynamic>) {
    for (final key in v.keys.toList()) {
      v[key] = _restoreMarkers(v[key]);
    }
    return v;
  }
  if (v is List) {
    for (var i = 0; i < v.length; i++) {
      v[i] = _restoreMarkers(v[i]);
    }
    return v;
  }
  return v;
}

/// Encodes JSON, writing [U64] values as plain integer literals and
/// sanitizing non-finite doubles which are not representable in JSON.
String encodeJsonPreservingU64(Object? value) {
  final sb = StringBuffer();
  _write(sb, value);
  return sb.toString();
}

void _write(StringBuffer sb, Object? v) {
  if (v == null) {
    sb.write('null');
  } else if (v is bool) {
    sb.write(v ? 'true' : 'false');
  } else if (v is int) {
    sb.write(v);
  } else if (v is double) {
    if (!v.isFinite) {
      sb.write('0.0');
    } else {
      sb.write(v.toString());
    }
  } else if (v is U64) {
    sb.write(v.digits);
  } else if (v is BigInt) {
    sb.write(v.toString());
  } else if (v is String) {
    sb.write(jsonEncode(v));
  } else if (v is Map) {
    sb.write('{');
    var first = true;
    v.forEach((key, value) {
      if (!first) sb.write(',');
      first = false;
      sb.write(jsonEncode(key.toString()));
      sb.write(':');
      _write(sb, value);
    });
    sb.write('}');
  } else if (v is Iterable) {
    sb.write('[');
    var first = true;
    for (final e in v) {
      if (!first) sb.write(',');
      first = false;
      _write(sb, e);
    }
    sb.write(']');
  } else {
    throw ArgumentError('Value of type ${v.runtimeType} is not JSON encodable');
  }
}

/// Deep copies a decoded JSON tree.
dynamic deepCopyJson(dynamic v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) e.key as String: deepCopyJson(e.value),
    };
  }
  if (v is List) return [for (final e in v) deepCopyJson(e)];
  return v;
}

/// Merges [update] into a deep copy of [base], keeping fields of [base] that
/// are unknown to this app (e.g. written by a newer Rnote version).
///
/// Externally tagged enums (maps with a single key) whose variant changed are
/// replaced instead of merged.
dynamic mergeJson(dynamic base, dynamic update) {
  if (base is Map && update is Map) {
    if (base.length == 1 &&
        update.length == 1 &&
        base.keys.first != update.keys.first) {
      return deepCopyJson(update);
    }
    final result = deepCopyJson(base) as Map<String, dynamic>;
    update.forEach((key, value) {
      result[key as String] = result.containsKey(key)
          ? mergeJson(result[key], value)
          : deepCopyJson(value);
    });
    return result;
  }
  return deepCopyJson(update);
}

double toDouble(dynamic v, [double fallback = 0.0]) {
  if (v is num) return v.toDouble();
  return fallback;
}

int toInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return fallback;
}

/// Rounds to 3 decimal places, like Rnote's serializer does.
double dp3(double v) => (v * 1000).roundToDouble() / 1000;

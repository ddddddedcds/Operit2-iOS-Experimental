// ignore_for_file: file_names

/// Removes orphaned UTF-16 surrogate code units so the text is safe to hand to
/// [TextSpan], which throws `Invalid argument(s): string is not well-formed
/// UTF-16` on invalid input. Terminal/tool output may carry raw bytes that
/// decode into lone surrogates (e.g. a truncated multi-byte sequence), which
/// would otherwise crash markdown/code-block rendering.
///
/// Shared so every text path that feeds [TextSpan] can sanitize in one place
/// instead of re-implementing the filter.
String sanitizeUtf16(String text) {
  if (text.isEmpty) {
    return text;
  }
  final length = text.length;
  var hasSurrogate = false;
  for (var i = 0; i < length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDFFF) {
      hasSurrogate = true;
      break;
    }
  }
  if (!hasSurrogate) {
    return text;
  }

  final buffer = StringBuffer();
  for (var i = 0; i < length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      // High surrogate: keep it only with a following low surrogate.
      if (i + 1 < length) {
        final next = text.codeUnitAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          buffer.writeCharCode(unit);
          buffer.writeCharCode(next);
          i++; // low surrogate consumed
          continue;
        }
      }
      continue; // lone high surrogate -> drop
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      continue; // low surrogate without preceding high -> drop
    }
    buffer.writeCharCode(unit);
  }
  return buffer.toString();
}

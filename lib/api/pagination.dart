/// Opaque cursor token from a paginated 2A-RD endpoint.
///
/// The server-side cursor is base64-encoded JSON containing a DDB
/// `LastEvaluatedKey`; the client treats it as a black box. Round-trip
/// via the `?cursor=` query param until the server returns `nextCursor:
/// null`.
///
/// Per phase-2a-read.md L6.
class CursorPage<T> {
  final List<T> items;
  final String? nextCursor;

  const CursorPage({required this.items, this.nextCursor});

  bool get hasMore => nextCursor != null;
}

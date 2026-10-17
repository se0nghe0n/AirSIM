export class RequestBodyError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export async function readBoundedJSON(request, maximumBytes) {
  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > maximumBytes) {
    throw new RequestBodyError(413, "request body too large");
  }
  const reader = request.body?.getReader();
  if (!reader) throw new RequestBodyError(400, "invalid JSON");
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maximumBytes) {
        try { await reader.cancel(); } catch {}
        throw new RequestBodyError(413, "request body too large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let parsed;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new RequestBodyError(400, "invalid JSON");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new RequestBodyError(400, "invalid JSON");
  }
  return parsed;
}

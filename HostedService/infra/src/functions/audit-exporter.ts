import {
  createAuditExporterRoot,
  lazyRoot,
  unavailableSqsResponse,
} from "./slice4-runtime-roots.js";

const exporter = lazyRoot(async () => createAuditExporterRoot());

export async function handler(event: Parameters<typeof exporter>[0]) {
  try {
    return await exporter(event);
  } catch {
    return unavailableSqsResponse(event);
  }
}

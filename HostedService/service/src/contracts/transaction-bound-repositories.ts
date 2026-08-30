/**
 * Opaque server-only repository bundle. Slice 5 adds its project-sync
 * capability as a separately branded extension in persistence; handlers still
 * receive neither a raw SQL executor nor a provider client.
 */
export interface TransactionBoundRepositoryBundle {
  readonly contract: "roomscan-transaction-repositories-v1";
  readonly transactionMarker: symbol;
}

/**
 * Opaque server-only repository bundle. Concrete repository methods are added
 * by the composition root once the corresponding migrations are frozen.
 * Handlers receive this bundle, never a raw SQL executor or provider client.
 */
export interface TransactionBoundRepositoryBundle {
  readonly contract: "roomscan-transaction-repositories-v1";
  readonly transactionMarker: symbol;
}

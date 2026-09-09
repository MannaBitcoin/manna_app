enum SubSwapStatus {
  /// Initial state of the swap; optionally the initial state can also be `invoice.set` in case
  /// the invoice was already specified in the request that created the swap.
  created('swap.created'),

  /// Indicates the lockup failed, which is usually because the user sent too little.
  transactionLockupFailed('transaction.lockupFailed'),

  /// The lockup transaction was found in the mempool, meaning the user sent funds to the
  /// lockup address.
  transactionMempool('transaction.mempool'),

  /// The lockup transaction was included in a block.
  transactionConfirmed('transaction.confirmed'),

  /// The swap has an invoice that should be paid.
  /// Can be the initial state when the invoice was specified in the request that created the swap
  invoiceSet('invoice.set'),

  /// Boltz started paying the invoice.
  invoicePending('invoice.pending'),

  /// Boltz failed to pay the invoice. In this case the user needs to broadcast a refund
  /// transaction to reclaim the locked up onchain coins.
  invoiceFailedToPay('invoice.failedToPay'),

  /// Boltz successfully paid the invoice.
  invoicePaid('invoice.paid'),

  /// Indicates that Boltz is ready for the creation of a cooperative signature for a key path
  /// spend. Taproot Swaps are not claimed immediately by Boltz after the invoice has been paid,
  /// but instead Boltz waits for the API client to post a signature for a key path spend. If the
  /// API client does not cooperate in a key path spend, Boltz will eventually claim via the script path.
  transactionClaimPending('transaction.claim.pending'),

  /// Indicates that after the invoice was successfully paid, the onchain were successfully
  /// claimed by Boltz. This is the final status of a successful Normal Submarine Swap.
  transactionClaimed('transaction.claimed'),

  /// Indicates the user didn't send onchain (lockup) and the swap expired (approximately 24h).
  /// This means that it was cancelled and chain L-BTC shouldn't be sent anymore.
  swapExpired('swap.expired'),

  /// This state is not from boltz and used by app to determine if the lockup funds has refunded.
  swapRefunded('swap.refunded');

  final String jsonName;

  const SubSwapStatus(this.jsonName);

  static Map<SubSwapStatus, String> dataValues() => Map.fromEntries(values.map((e) => MapEntry(e, e.jsonName)));
}

enum RevSwapStatus {
  /// Initial state of a newly created Reverse Submarine Swap.
  created('swap.created'),

  /// Optional and currently not enabled on Boltz. If Boltz requires prepaying miner fees via a
  /// separate Lightning invoice, this state is set when the miner fee invoice was successfully paid.
  minerFeePaid('minerfee.paid'),

  /// Boltz's lockup transaction is found in the mempool which will only happen after the user
  /// paid the Lightning hold invoice.
  transactionMempool('transaction.mempool'),

  /// The lockup transaction was included in a block. This state is skipped, if the client
  /// optionally accepts the transaction without confirmation. Boltz broadcasts chain transactions
  /// non-RBF only.
  transactionConfirmed('transaction.confirmed'),

  /// The transaction claiming onchain was broadcast by the user's client and Boltz used the
  /// preimage of this transaction to settle the Lightning invoice. This is the final status of a
  /// successful Reverse Submarine Swap.
  invoiceSettled('invoice.settled'),

  /// Set when the invoice of Boltz expired and pending HTLCs are cancelled. Boltz invoices
  /// currently expire after 50% of the swap timeout window.
  invoiceExpired('invoice.expired'),

  /// This is the final status of a swap, if the swap expires without the lightning invoice being paid.
  swapExpired('swap.expired'),

  /// Set in the unlikely event that Boltz is unable to send the agreed amount of onchain coins
  /// after the user set up the payment to the provided Lightning invoice. If this happens, the
  /// pending Lightning HTLC will also be cancelled. The Lightning bitcoin automatically bounce
  /// back to the user, no further action or refund is required and the user didn't pay any fees.
  transactionFailed('transaction.failed'),

  /// This is the final status of a swap, if the user successfully set up the Lightning payment
  /// and Boltz successfully locked up coins onchain, but the Boltz API Client did not claim
  /// the locked oncahin coins before swap expiry. In this case, Boltz will also automatically refund
  /// its own locked onchain coins and the Lightning payment is cancelled.
  transactionRefunded('transaction.refunded');

  final String jsonName;

  const RevSwapStatus(this.jsonName);

  static Map<RevSwapStatus, String> dataValues() => Map.fromEntries(values.map((e) => MapEntry(e, e.jsonName)));
}

enum ChainSwapStatus {
  /// The initial state of the chain swap.
  created('swap.created'),

  /// The server has rejected a 0-conf transaction for this swap.
  transactionZeroConfRejected('transaction.zeroconf.rejected'),

  /// The lockup transaction of the client was found in the mempool.
  transactionMempool('transaction.mempool'),

  /// The lockup transaction of the client was confirmed in a block. When the server accepts 0-conf,
  /// for the lockup transaction, this state is skipped.
  transactionConfirmed('transaction.confirmed'),

  /// The lockup transaction of the server has been broadcast.
  transactionServerMempool('transaction.server.mempool'),

  /// The lockup transaction of the server has been included in a block.
  transactionServerConfirmed('transaction.server.confirmed'),

  /// The server claimed the coins that the client locked.
  transactionClaimed('transaction.claimed'),

  /// Indicates the lockup failed, which is usually because the user sent too little.
  transactionLockupFailed('transaction.lockupFailed'),

  /// This is the final status of a swap, if the swap expires without a chain bitcoin transaction.
  swapExpired('swap.expired'),

  /// Set in the unlikely event that Boltz is unable to lock the agreed amount of chain bitcoin.
  /// The user needs to submit a refund transaction to reclaim the chain bitcoin if bitcoin were
  /// already sent.
  transactionFailed('transaction.failed'),

  /// If the user and Boltz both successfully locked up bitcoin on the chain, but the user did not
  /// claim the locked chain bitcoin until swap expiry, Boltz will automatically refund its own locked
  /// chain bitcoin.
  transactionRefunded('transaction.refunded'),

  /// This state is not from boltz and used by app to determine if the lockup funds has refunded.
  swapRefunded('swap.refunded');

  final String jsonName;

  const ChainSwapStatus(this.jsonName);

  static Map<ChainSwapStatus, String> dataValues() => Map.fromEntries(values.map((e) => MapEntry(e, e.jsonName)));
}
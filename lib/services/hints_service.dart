import 'dart:math' as math;

class HintsService {
  static final random = math.Random();

  static final List<String> hints = [
    'You can add public comments on BTC Map locations by paying a small fee.',
    'BTC Map shows all the places near you that you can spend your bitcoin.',
    'In Manna, your coins are stored as LBTC on the Liquid protocol and secured with your own private keys that no one else can access.',
    "Data stored in the Manna database is encrypted with your own keys. Even we can't access it.",
    'You can chat with other Manna users securely, as it is end-to-end encrypted. No one except you and the recipient can read the messages (not even us).',
    'You can create external contacts as well as customize Manna user contacts.',
    'You can import your NOSTR contacts using Npub.',
    'You can use Manna to log in with Lightning on other platforms (LUD-04).',
    'You can create multiple taxes or fees for different categories for your shop.',
    'You can receive tips on your shop.',
    'Long press on your balance to switch formats.',
    'Click on your balance to hide it',
    'Bitcoin is more than just an asset - it’s a digital currency designed to be spent',
    'HODL',
    'Sell fiat, buy bitcoin',
    'Bitcoin is the only real cryptocurrency',
    'Stack sats...',
    'Bitcoin fixes the broken economy',
    'Money without borders',
    'Not your keys, not your bitcoin',
    'When you buy altcoins, you are just buying bitcoin for someone else',
    'You can see the current value of btc anywhere in app by clicking on the fiat value below the bitcoin amount.',
  ];

  static String getRandomHint() => hints[random.nextInt(hints.length)];
}

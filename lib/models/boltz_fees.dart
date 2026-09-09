import 'dart:convert';
import 'package:manna/config.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna_core/manna_core.dart';

class SwapLimits {
  SwapLimits({
    required this.minimal,
    required this.maximal,
    required this.maximalZeroConf,
    required this.minimalBatched,
  });

  factory SwapLimits.fromMap(Map<String, dynamic> map) => SwapLimits(
    minimal: parseInt(map['minimal']),
    maximal: parseInt(map['maximal']),
    maximalZeroConf: parseIntN(map['maximalZeroConf']),
    minimalBatched: parseIntN(map['minimalBatched']),
  );

  final int minimal;
  final int maximal;
  final int? maximalZeroConf;
  final int? minimalBatched;

  Map<String, dynamic> toMap() => {
    'minimal': minimal,
    'maximal': maximal,
    'maximalZeroConf': maximalZeroConf,
    'minimalBatched': minimalBatched,
  };
}

class SubSwapFees {
  SubSwapFees({required this.percentage, required this.minerFees});
  factory SubSwapFees.fromMap(Map<String, dynamic> map) =>
      SubSwapFees(percentage: parseDouble(map['percentage']), minerFees: parseInt(map['minerFees']));

  final double percentage;
  final int minerFees;

  Map<String, dynamic> toMap() => {'percentage': percentage, 'minerFees': minerFees};
}

class SubmarineFeesAndLimits {
  SubmarineFeesAndLimits({
    required this.btcLimits,
    required this.lbtcLimits,
    required this.btcFees,
    required this.lbtcFees,
  });

  factory SubmarineFeesAndLimits.fromMap(Map<String, dynamic> map) {
    final btc = map['BTC']?['BTC'];
    final lbtc = map['L-BTC']?['BTC'];
    return SubmarineFeesAndLimits(
      btcLimits: SwapLimits.fromMap(btc?['limits'] ?? {}),
      lbtcLimits: SwapLimits.fromMap(lbtc?['limits'] ?? {}),
      btcFees: SubSwapFees.fromMap(btc?['fees'] ?? {}),
      lbtcFees: SubSwapFees.fromMap(lbtc?['fees'] ?? {}),
    );
  }

  final SwapLimits btcLimits;
  final SwapLimits lbtcLimits;
  final SubSwapFees btcFees;
  final SubSwapFees lbtcFees;

  Map<String, dynamic> toMap() => {
    'BTC': {
      'BTC': {'limits': btcLimits.toMap(), 'fees': btcFees.toMap()},
    },
    'L-BTC': {
      'BTC': {'limits': lbtcLimits.toMap(), 'fees': lbtcFees.toMap()},
    },
  };
}

class MinerFees {
  MinerFees({required this.lockup, required this.claim});
  factory MinerFees.fromMap(Map<String, dynamic> map) =>
      MinerFees(lockup: parseInt(map['lockup']), claim: parseInt(map['claim']));

  final int lockup;
  final int claim;

  Map<String, dynamic> toMap() => {'lockup': lockup, 'claim': claim};
}

class RevSwapFees {
  RevSwapFees({required this.percentage, required this.minerFees});
  factory RevSwapFees.fromMap(Map<String, dynamic> map) =>
      RevSwapFees(percentage: parseDouble(map['percentage']), minerFees: MinerFees.fromMap(map['minerFees'] ?? {}));

  final double percentage;
  final MinerFees minerFees;

  Map<String, dynamic> toMap() => {'percentage': percentage, 'minerFees': minerFees.toMap()};
}

class ReverseFeesAndLimits {
  ReverseFeesAndLimits({
    required this.btcLimits,
    required this.lbtcLimits,
    required this.btcFees,
    required this.lbtcFees,
  });

  factory ReverseFeesAndLimits.fromMap(Map<String, dynamic> map) {
    final btc = map['BTC']?['BTC'];
    final lbtc = map['BTC']?['L-BTC'];
    return ReverseFeesAndLimits(
      btcLimits: SwapLimits.fromMap(btc?['limits'] ?? {}),
      lbtcLimits: SwapLimits.fromMap(lbtc?['limits'] ?? {}),
      btcFees: RevSwapFees.fromMap(btc?['fees'] ?? {}),
      lbtcFees: RevSwapFees.fromMap(lbtc?['fees'] ?? {}),
    );
  }

  final SwapLimits btcLimits;
  final SwapLimits lbtcLimits;
  final RevSwapFees btcFees;
  final RevSwapFees lbtcFees;

  Map<String, dynamic> toMap() => {
    'BTC': {
      'BTC': {'limits': btcLimits.toMap(), 'fees': btcFees.toMap()},
      'L-BTC': {'limits': lbtcLimits.toMap(), 'fees': lbtcFees.toMap()},
    },
  };
}

class ChainSwapFees {
  ChainSwapFees({required this.percentage, required this.userLockup, required this.userClaim, required this.server});

  factory ChainSwapFees.fromMap(Map<String, dynamic> map) => ChainSwapFees(
    percentage: parseDouble(map['percentage']),
    userLockup: parseInt(map['minerFees']?['user']?['lockup']),
    userClaim: parseInt(map['minerFees']?['user']?['claim']),
    server: parseInt(map['minerFees']?['server']),
  );

  final double percentage;
  final int userLockup;
  final int userClaim;
  final int server;

  Map<String, dynamic> toMap() => {
    'percentage': percentage,
    'minerFees': {
      'user': {'lockup': userLockup, 'claim': userClaim},
      'server': server,
    },
  };
}

class ChainFeesAndLimits {
  ChainFeesAndLimits({
    required this.btcLimits,
    required this.lbtcLimits,
    required this.btcFees,
    required this.lbtcFees,
  });

  factory ChainFeesAndLimits.fromMap(Map<String, dynamic> map) {
    final btc = map['L-BTC']?['BTC'];
    final lbtc = map['BTC']?['L-BTC'];
    return ChainFeesAndLimits(
      btcLimits: SwapLimits.fromMap(btc?['limits'] ?? {}),
      lbtcLimits: SwapLimits.fromMap(lbtc?['limits'] ?? {}),
      btcFees: ChainSwapFees.fromMap(btc?['fees'] ?? {}),
      lbtcFees: ChainSwapFees.fromMap(lbtc?['fees'] ?? {}),
    );
  }

  // lbtc->btc
  final SwapLimits btcLimits;
  // btc->lbtc
  final SwapLimits lbtcLimits;
  final ChainSwapFees btcFees;
  final ChainSwapFees lbtcFees;

  Map<String, dynamic> toMap() => {
    'BTC': {
      'L-BTC': {'limits': lbtcLimits.toMap(), 'fees': lbtcFees.toMap()},
    },
    'L-BTC': {
      'BTC': {'limits': btcLimits.toMap(), 'fees': btcFees.toMap()},
    },
  };
}

class BoltzFees {
  static SubmarineFeesAndLimits _submarineFeesAndLimits = SubmarineFeesAndLimits.fromMap({});
  static ReverseFeesAndLimits _reverseFeesAndLimits = ReverseFeesAndLimits.fromMap({});
  static ChainFeesAndLimits _chainFeesAndLimits = ChainFeesAndLimits.fromMap({});

  static final MutexRun _submarineMutex = MutexRun();
  static final MutexRun _reverseMutex = MutexRun();
  static final MutexRun _chainMutex = MutexRun();

  static SubmarineFeesAndLimits getSubmarineFeesAndLimits() {
    _submarineMutex.run(() async {
      try {
        _submarineFeesAndLimits = SubmarineFeesAndLimits.fromMap(
          jsonDecode(await getSubmarineJson(apiConfig: Config.apiConfig, network: Config.network)),
        );
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
    });

    return _submarineFeesAndLimits;
  }

  static ReverseFeesAndLimits getReverseFeesAndLimits() {
    _reverseMutex.run(() async {
      try {
        _reverseFeesAndLimits = ReverseFeesAndLimits.fromMap(
          jsonDecode(await getReverseJson(apiConfig: Config.apiConfig, network: Config.network)),
        );
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
    });

    return _reverseFeesAndLimits;
  }

  static ChainFeesAndLimits getChainFeesAndLimits({Network? network}) {
    _chainMutex.run(() async {
      try {
        _chainFeesAndLimits = ChainFeesAndLimits.fromMap(
          jsonDecode(await getChainJson(apiConfig: Config.apiConfig, network: network ?? Config.network)),
        );
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
    });

    return _chainFeesAndLimits;
  }
}

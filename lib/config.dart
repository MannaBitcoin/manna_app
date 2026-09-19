import 'package:manna/app_state.dart';
import 'package:manna/env.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna_core/manna_core.dart';

class Config {
  static Network get network {
    try {
      final net = Network.values.elementAtOrNull(AppState.prefs.getInt('network') ?? 0) ?? Network.mainnet;
      if (net == Network.regtest && !isRegtestOn) {
        return Network.mainnet;
      } else {
        return net;
      }
    } catch (_) {}
    return Network.mainnet;
  }

  static late final String breezApiKey;

  static late final ApiConfig apiConfig;
  static late final bool isRegtestOn;

  static late final bool isBolt12SendEnabled;

  static void init(Env env) {
    breezApiKey = env.breezApiKey;
    apiConfig = ApiConfig(
      mainnet: NetworkConfig(
        bitcoin: NetworkEndpoints(esplora: env.bitcoinEsploraUrlMainnet, electrum: env.bitcoinElectrumUrlMainnet),
        liquid: NetworkEndpoints(esplora: env.liquidEsploraUrlMainnet, electrum: env.liquidElectrumUrlMainnet),
        boltzUrl: env.boltzUrlMainnet,
        boltzFeeCacheTimeoutMs: env.boltzFeeCacheTimeoutMsMainnet.bigInt,
        supabase: SupabaseConfig(projectRef: env.supabaseProjectIdMainnet, apiKey: env.supabaseApiKeyMainnet),
        serverUrl: env.serverUrlMainnet,
        serverApiVersion: env.serverApiVersionMainnet,
      ),
      regtest: NetworkConfig(
        bitcoin: NetworkEndpoints(
          esplora: env.bitcoinEsploraUrlRegtest ?? '',
          electrum: env.bitcoinElectrumUrlRegtest ?? '',
        ),
        liquid: NetworkEndpoints(
          esplora: env.liquidEsploraUrlRegtest ?? '',
          electrum: env.liquidElectrumUrlRegtest ?? '',
        ),
        boltzUrl: env.boltzUrlRegtest ?? '',
        boltzFeeCacheTimeoutMs: env.boltzFeeCacheTimeoutMsRegtest.bigInt,
        supabase: SupabaseConfig(
          projectRef: env.supabaseProjectIdRegtest ?? '',
          apiKey: env.supabaseApiKeyRegtest ?? '',
        ),
        serverUrl: env.serverUrlRegtest ?? '',
        serverApiVersion: env.serverApiVersionRegtest ?? '',
      ),
      // Never used
      testnet: NetworkConfig(
        bitcoin: NetworkEndpoints(esplora: env.bitcoinEsploraUrlTestnet, electrum: env.bitcoinElectrumUrlTestnet),
        liquid: NetworkEndpoints(esplora: env.liquidEsploraUrlTestnet, electrum: env.liquidElectrumUrlTestnet),
        boltzUrl: env.boltzUrlTestnet,
        boltzFeeCacheTimeoutMs: env.boltzFeeCacheTimeoutMsTestnet.bigInt,
        supabase: SupabaseConfig(
          projectRef: env.supabaseProjectIdTestnet ?? '',
          apiKey: env.supabaseApiKeyTestnet ?? '',
        ),
        serverUrl: env.serverUrlTestnet ?? '',
        serverApiVersion: env.serverApiVersionTestnet ?? '',
      ),
    );

    final regtest = apiConfig.regtest;
    isRegtestOn =
        regtest.supabase.projectRef.isNotEmpty &&
        regtest.supabase.apiKey.isNotEmpty &&
        regtest.serverUrl.isNotEmpty &&
        regtest.serverApiVersion.isNotEmpty &&
        regtest.bitcoin.esplora.isNotEmpty &&
        regtest.bitcoin.electrum.isNotEmpty &&
        regtest.liquid.esplora.isNotEmpty &&
        regtest.liquid.electrum.isNotEmpty;
    isBolt12SendEnabled = env.enableBolt12Send;
  }

  static NetworkConfig get current => of(network);

  static NetworkConfig of(Network network) => switch (network) {
    Network.mainnet => apiConfig.mainnet,
    Network.testnet => apiConfig.testnet,
    Network.regtest => apiConfig.regtest,
  };

  static String lBtcId({Network? network}) => switch (network ?? Config.network) {
    Network.mainnet => '6f0279e9ed041c3d710a9f57d0c02928416460c4b722ae3457a11eec381c526d',
    Network.testnet => '144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49',
    Network.regtest => '5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225',
  };

  static String? get sparkWebhookUrl {
    final config = Config.current;
    return config.serverUrl.isNotEmpty ? config.getServerApiEndpoint('webhook/spark') : null;
  }
}

extension ConfigExtension on NetworkConfig {
  String getServerEndpoint(String path) => Uri(scheme: 'https', host: serverUrl, path: path).toString();

  String getServerCDNEndpoint(String path) => Uri(scheme: 'https', host: 'cdn.$serverUrl', path: path).toString();

  String getServerApiEndpoint(String path) =>
      Uri(scheme: 'https', host: 'api.$serverUrl', path: '$serverApiVersion/$path').toString();
}

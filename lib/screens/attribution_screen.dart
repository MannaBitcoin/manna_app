import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:url_launcher/url_launcher_string.dart';

class AttributionScreen extends StatefulWidget {
  const AttributionScreen({super.key});

  @override
  State<AttributionScreen> createState() => _AttributionScreenState();
}

class _AttributionScreenState extends State<AttributionScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Attributions')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          spacing: 8,
          children: [
            Card(
              child: ListTile(
                leading: Image.asset(AppImages.boltz, height: 32, width: 32, fit: BoxFit.contain),
                title: const Text('Boltz'),
                subtitle: const Text('Non-Custodial Bitcoin Bridge'),
                onTap: () => launchUrlString('https://api.docs.boltz.exchange/'),
              ),
            ),
            Card(
              child: ListTile(
                leading: SvgPicture.string(
                  AppImages.timechainStatsSVG,
                  height: 32,
                  width: 32,
                  colorFilter: const ColorFilter.mode(Color.fromARGB(255, 247, 148, 26), BlendMode.srcATop),
                ),
                title: const Text('Time chain stats'),
                subtitle: const Text('Live bitcoin prices'),
                onTap: () => launchUrlString('https://timechainstats.com/'),
              ),
            ),
            Card(
              child: ExpansionTile(
                shape: const Border(),
                title: const Text('Block Explorers'),
                children: [
                  ListTile(
                    title: Builder(
                      builder: (context) {
                        final provider = getImageProvider(
                          context.isDarkMode
                              ? 'https://design.blockstream.com/assets/pages/logo/logo.png'
                              : 'https://design.blockstream.com/assets/pages/logo/black_logo.png',
                        );
                        const fallback = SizedBox.shrink();
                        if (provider != null) {
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Image(
                              image: provider,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) => fallback,
                              loadingBuilder: imageLoadingBuilder,
                              width: 108,
                            ),
                          );
                        }
                        return fallback;
                      },
                    ),
                    onTap: () => launchUrlString('https://blockstream.info/'),
                  ),
                  ListTile(title: const Text('mempool.space'), onTap: () => launchUrlString('https://mempool.space')),
                  ListTile(title: const Text('liquid.network'), onTap: () => launchUrlString('https://liquid.network')),
                  ListTile(
                    title: const Text('mempool.bullbitcoin.com'),
                    onTap: () => launchUrlString('https://mempool.bullbitcoin.com'),
                  ),
                  ListTile(
                    title: const Text('liquid.bullbitcoin.com'),
                    onTap: () => launchUrlString('https://liquid.bullbitcoin.com'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

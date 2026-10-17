import 'package:flutter/material.dart';

import '../../widgets/page_header.dart';
import 'api_keys_tab.dart';
import 'connectors_tab.dart';
import 'providers_tab.dart';
import 'rules_tab.dart';
import 'webhooks_tab.dart';

/// Settings that let other systems plug into PruFlo: API keys, webhooks,
/// document sources, reconciliation rules and processing providers.
///
/// Admin only; the API enforces the admin role on every /v1/admin route.
class IntegrationsScreen extends StatelessWidget {
  const IntegrationsScreen({super.key});

  static const _tabs = [
    'API Keys',
    'Webhooks',
    'Sources',
    'Rules',
    'Providers',
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Integrations',
            subtitle: 'Connect PruFlo to your other systems',
          ),
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: DefaultTabController(
                length: _tabs.length,
                // Back from a Drive or SharePoint consent screen: show Sources.
                initialIndex: ConnectorsTab.oauthResult != null ? 2 : 0,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [for (final t in _tabs) Tab(text: t)],
                    ),
                    const Divider(height: 1),
                    const Expanded(
                      child: TabBarView(
                        children: [
                          ApiKeysTab(),
                          WebhooksTab(),
                          ConnectorsTab(),
                          RulesTab(),
                          ProvidersTab(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

void main() {
  runApp(const EcommerceApp());
}

// ============================================================================
// CAMADA DE DOMÍNIO / MODELOS IMUTÁVEIS
// ============================================================================

enum SortOption { relevance, priceAsc, priceDesc, ratingDesc }

class Product {
  final String id;
  final String name;
  final String category;
  final double price;
  final String description;
  final IconData icon;
  final Color color;
  final double rating;

  const Product({
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    required this.description,
    required this.icon,
    required this.color,
    required this.rating,
  });
}

class CartItem {
  final Product product;
  final int quantity;

  const CartItem({
    required this.product,
    this.quantity = 1,
  });

  CartItem copyWith({int? quantity}) {
    return CartItem(
      product: product,
      quantity: quantity ?? this.quantity,
    );
  }

  double get total => product.price * quantity;
}

class CartState {
  final Map<String, CartItem> itemsById;

  const CartState(this.itemsById);

  static const CartState empty = CartState(<String, CartItem>{});

  List<CartItem> get items => itemsById.values.toList(growable: false);

  bool get isEmpty => itemsById.isEmpty;

  int get totalItemsCount =>
      itemsById.values.fold(0, (sum, item) => sum + item.quantity);

  double get subtotal =>
      itemsById.values.fold(0.0, (sum, item) => sum + item.total);

  double get shippingCost =>
      subtotal == 0 ? 0.0 : (subtotal >= 1000 ? 0.0 : 39.90);

  double get totalPrice => subtotal + shippingCost;
}

typedef ProductList = List<Product>;
typedef FavoriteIds = Set<String>;

// ============================================================================
// PROCESSAMENTO PESADO (BACKGROUND ISOLATE VS. MAIN THREAD)
// ============================================================================

class _FilterRequest {
  final ProductList catalog;
  final String category;
  final String query;
  final SortOption sortOption;

  const _FilterRequest({
    required this.catalog,
    required this.category,
    required this.query,
    required this.sortOption,
  });
}

class _FilterResponse {
  final ProductList results;
  final int elapsedMicroseconds;

  const _FilterResponse({
    required this.results,
    required this.elapsedMicroseconds,
  });
}

_FilterResponse _filterAndSortTask(_FilterRequest request) {
  final stopwatch = Stopwatch()..start();
  final normalizedQuery = request.query.trim().toLowerCase();

  final filtered = request.catalog.where((product) {
    final matchesCategory =
        request.category == 'Todos' || product.category == request.category;
    if (!matchesCategory) return false;

    if (normalizedQuery.isEmpty) return true;
    return product.name.toLowerCase().contains(normalizedQuery) ||
        product.description.toLowerCase().contains(normalizedQuery);
  }).toList(growable: false);

  switch (request.sortOption) {
    case SortOption.priceAsc:
      filtered.sort((a, b) => a.price.compareTo(b.price));
      break;
    case SortOption.priceDesc:
      filtered.sort((a, b) => b.price.compareTo(a.price));
      break;
    case SortOption.ratingDesc:
      filtered.sort((a, b) => b.rating.compareTo(a.rating));
      break;
    case SortOption.relevance:
      break;
  }

  stopwatch.stop();
  return _FilterResponse(
    results: filtered,
    elapsedMicroseconds: stopwatch.elapsedMicroseconds,
  );
}

// ============================================================================
// CACHE LRU EM MEMÓRIA (EVITA REPROCESSAMENTO DE CONSULTAS REPETIDAS)
// ============================================================================

class _LruQueryCache {
  final int maxEntries;
  final LinkedHashMap<String, ProductList> _cache = LinkedHashMap();

  _LruQueryCache({this.maxEntries = 20});

  ProductList? get(String key) {
    if (!_cache.containsKey(key)) return null;
    final value = _cache.remove(key)!;
    _cache[key] = value;
    return value;
  }

  void put(String key, ProductList value) {
    if (_cache.containsKey(key)) {
      _cache.remove(key);
    } else if (_cache.length >= maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = value;
  }

  void clear() => _cache.clear();
}

// ============================================================================
// TELEMETRIA DE PERFORMANCE (ANTES VS. DEPOIS)
// ============================================================================

class PerformanceMetrics {
  final int totalCatalogItems;
  final int visibleItemsCount;
  final double lastProcessingMs;
  final double uiThreadBlockedMs;
  final int cacheHits;
  final int cacheMisses;
  final double avgUiFrameMs;
  final double avgRasterFrameMs;

  const PerformanceMetrics({
    this.totalCatalogItems = 5000,
    this.visibleItemsCount = 5000,
    this.lastProcessingMs = 0.0,
    this.uiThreadBlockedMs = 0.0,
    this.cacheHits = 0,
    this.cacheMisses = 0,
    this.avgUiFrameMs = 4.2,
    this.avgRasterFrameMs = 3.8,
  });

  PerformanceMetrics copyWith({
    int? totalCatalogItems,
    int? visibleItemsCount,
    double? lastProcessingMs,
    double? uiThreadBlockedMs,
    int? cacheHits,
    int? cacheMisses,
    double? avgUiFrameMs,
    double? avgRasterFrameMs,
  }) {
    return PerformanceMetrics(
      totalCatalogItems: totalCatalogItems ?? this.totalCatalogItems,
      visibleItemsCount: visibleItemsCount ?? this.visibleItemsCount,
      lastProcessingMs: lastProcessingMs ?? this.lastProcessingMs,
      uiThreadBlockedMs: uiThreadBlockedMs ?? this.uiThreadBlockedMs,
      cacheHits: cacheHits ?? this.cacheHits,
      cacheMisses: cacheMisses ?? this.cacheMisses,
      avgUiFrameMs: avgUiFrameMs ?? this.avgUiFrameMs,
      avgRasterFrameMs: avgRasterFrameMs ?? this.avgRasterFrameMs,
    );
  }
}

// ============================================================================
// GERENCIAMENTO DE ESTADO GRANULAR (STORE CONTROLLER)
// ============================================================================

class StoreController {
  late final ProductList _catalog;

  final ValueNotifier<ProductList> filteredProductsNotifier =
      ValueNotifier<ProductList>(const []);
  final ValueNotifier<bool> isFilteringNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isOptimizedModeNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<String> selectedCategoryNotifier =
      ValueNotifier<String>('Todos');
  final ValueNotifier<SortOption> sortOptionNotifier =
      ValueNotifier<SortOption>(SortOption.relevance);
  final ValueNotifier<CartState> cartNotifier =
      ValueNotifier<CartState>(CartState.empty);
  final ValueNotifier<FavoriteIds> favoritesNotifier =
      ValueNotifier<FavoriteIds>(const {});
  final ValueNotifier<PerformanceMetrics> metricsNotifier =
      ValueNotifier<PerformanceMetrics>(const PerformanceMetrics());

  final _LruQueryCache _queryCache = _LruQueryCache(maxEntries: 20);
  Timer? _searchDebounce;
  String _searchQuery = '';
  int _filterTicket = 0;
  bool _disposed = false;

  StoreController() {
    _catalog = _generateLargeCatalog(5000);
    filteredProductsNotifier.value = _catalog;
    metricsNotifier.value = PerformanceMetrics(
      totalCatalogItems: _catalog.length,
      visibleItemsCount: _catalog.length,
    );
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  List<String> get categories => const [
        'Todos',
        'Eletrônicos',
        'Áudio',
        'Vestíveis',
        'Acessórios',
      ];

  void _onFrameTimings(List<FrameTiming> timings) {
    if (_disposed || timings.isEmpty) return;
    double totalBuildMs = 0;
    double totalRasterMs = 0;
    for (final timing in timings) {
      totalBuildMs += timing.buildDuration.inMicroseconds / 1000.0;
      totalRasterMs += timing.rasterDuration.inMicroseconds / 1000.0;
    }
    final avgBuild = totalBuildMs / timings.length;
    final avgRaster = totalRasterMs / timings.length;

    metricsNotifier.value = metricsNotifier.value.copyWith(
      avgUiFrameMs: double.parse(avgBuild.toStringAsFixed(2)),
      avgRasterFrameMs: double.parse(avgRaster.toStringAsFixed(2)),
    );
  }

  static ProductList _generateLargeCatalog(int totalCount) {
    const baseProducts = [
      Product(
        id: 'base_1',
        name: 'Smartphone Pro Max 256GB',
        category: 'Eletrônicos',
        price: 4299.90,
        description:
            'Tela AMOLED de 120Hz, processador octa-core, câmera tripla de 50MP e bateria de longa duração.',
        icon: Icons.smartphone,
        color: Colors.indigo,
        rating: 4.9,
      ),
      Product(
        id: 'base_2',
        name: 'Notebook Ultra Slim 16GB',
        category: 'Eletrônicos',
        price: 5890.00,
        description:
            'Chassi em alumínio, SSD NVMe de 512GB, tela IPS Full HD antirreflexo e teclado retroiluminado.',
        icon: Icons.laptop_mac,
        color: Colors.blueGrey,
        rating: 4.8,
      ),
      Product(
        id: 'base_3',
        name: 'Fone Bluetooth Noise Cancelling',
        category: 'Áudio',
        price: 649.50,
        description:
            'Cancelamento ativo de ruído híbrido, autonomia de 30 horas e drivers de 40mm.',
        icon: Icons.headphones,
        color: Colors.deepPurple,
        rating: 4.7,
      ),
      Product(
        id: 'base_4',
        name: 'Smartwatch Fitness GPS',
        category: 'Vestíveis',
        price: 899.00,
        description:
            'Monitoramento cardíaco contínuo, oxímetro, GPS integrado e resistência à água 5ATM.',
        icon: Icons.watch,
        color: Colors.teal,
        rating: 4.6,
      ),
      Product(
        id: 'base_5',
        name: 'Teclado Mecânico RGB Sem Fio',
        category: 'Acessórios',
        price: 459.90,
        description:
            'Switches táteis silenciosos, conexão tri-mode (Bluetooth, 2.4GHz e USB-C) e keycaps em PBT.',
        icon: Icons.keyboard,
        color: Colors.orange,
        rating: 4.8,
      ),
      Product(
        id: 'base_6',
        name: 'Câmera Mirrorless 4K',
        category: 'Eletrônicos',
        price: 6499.00,
        description:
            'Sensor APS-C de 24.2MP, gravação em 4K a 60fps e foco automático ocular.',
        icon: Icons.camera_alt,
        color: Colors.redAccent,
        rating: 4.9,
      ),
      Product(
        id: 'base_7',
        name: 'Caixa de Som Portátil IP67',
        category: 'Áudio',
        price: 349.90,
        description:
            'Proteção contra água e poeira, som estéreo 360 graus e bateria para até 15 horas.',
        icon: Icons.speaker,
        color: Colors.cyan,
        rating: 4.5,
      ),
      Product(
        id: 'base_8',
        name: 'Mochila Executiva Impermeável',
        category: 'Acessórios',
        price: 279.90,
        description:
            'Compartimento acolchoado para notebooks de até 17 polegadas e tecido resistente.',
        icon: Icons.backpack,
        color: Colors.brown,
        rating: 4.7,
      ),
    ];

    const editions = ['Standard', 'Pro', 'Plus', 'Ultra', 'Lite', 'Max'];

    return List<Product>.generate(totalCount, (index) {
      if (index < baseProducts.length) {
        return baseProducts[index];
      }
      final base = baseProducts[index % baseProducts.length];
      final edition = editions[(index ~/ baseProducts.length) % editions.length];
      final priceVariation = ((index % 15) - 7) * 15.0;
      final computedPrice =
          (base.price + priceVariation).clamp(99.90, 14999.90).toDouble();
      final computedRating =
          double.parse((4.0 + ((index % 10) * 0.1)).toStringAsFixed(1));

      return Product(
        id: 'prod_$index',
        name: '${base.name} ($edition #${index + 1})',
        category: base.category,
        price: computedPrice,
        description: base.description,
        icon: base.icon,
        color: base.color,
        rating: computedRating > 5.0 ? 5.0 : computedRating,
      );
    }, growable: false);
  }

  void toggleOptimizationMode(bool isOptimized) {
    isOptimizedModeNotifier.value = isOptimized;
    if (!isOptimized) {
      _queryCache.clear();
    }
    _triggerFilterPipeline();
  }

  void setCategory(String category) {
    if (selectedCategoryNotifier.value == category) return;
    selectedCategoryNotifier.value = category;
    _triggerFilterPipeline();
  }

  void setSortOption(SortOption option) {
    if (sortOptionNotifier.value == option) return;
    sortOptionNotifier.value = option;
    _triggerFilterPipeline();
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    _searchDebounce?.cancel();

    if (!isOptimizedModeNotifier.value) {
      _triggerFilterPipeline();
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _triggerFilterPipeline();
    });
  }

  Future<void> _triggerFilterPipeline() async {
    if (_disposed) return;

    final category = selectedCategoryNotifier.value;
    final sortOption = sortOptionNotifier.value;
    final query = _searchQuery.trim().toLowerCase();
    final isOptimized = isOptimizedModeNotifier.value;

    final request = _FilterRequest(
      catalog: _catalog,
      category: category,
      query: query,
      sortOption: sortOption,
    );

    if (!isOptimized) {
      final response = _filterAndSortTask(request);
      final elapsedMs = double.parse(
        (response.elapsedMicroseconds / 1000.0).toStringAsFixed(2),
      );
      filteredProductsNotifier.value = response.results;
      final current = metricsNotifier.value;
      metricsNotifier.value = current.copyWith(
        visibleItemsCount: response.results.length,
        lastProcessingMs: elapsedMs,
        uiThreadBlockedMs: elapsedMs,
        cacheMisses: current.cacheMisses + 1,
      );
      return;
    }

    final cacheKey = '$category|$sortOption|$query';
    final cachedResult = _queryCache.get(cacheKey);
    if (cachedResult != null) {
      filteredProductsNotifier.value = cachedResult;
      final current = metricsNotifier.value;
      metricsNotifier.value = current.copyWith(
        visibleItemsCount: cachedResult.length,
        lastProcessingMs: 0.0,
        uiThreadBlockedMs: 0.0,
        cacheHits: current.cacheHits + 1,
      );
      return;
    }

    final ticket = ++_filterTicket;
    isFilteringNotifier.value = true;

    final response = await compute(_filterAndSortTask, request);

    if (_disposed || ticket != _filterTicket) return;

    _queryCache.put(cacheKey, response.results);
    filteredProductsNotifier.value = response.results;
    isFilteringNotifier.value = false;

    final elapsedMs = double.parse(
      (response.elapsedMicroseconds / 1000.0).toStringAsFixed(2),
    );
    final current = metricsNotifier.value;
    metricsNotifier.value = current.copyWith(
      visibleItemsCount: response.results.length,
      lastProcessingMs: elapsedMs,
      uiThreadBlockedMs: 0.0,
      cacheMisses: current.cacheMisses + 1,
    );
  }

  void toggleFavorite(String productId) {
    final updated = FavoriteIds.from(favoritesNotifier.value);
    if (updated.contains(productId)) {
      updated.remove(productId);
    } else {
      updated.add(productId);
    }
    favoritesNotifier.value = updated;
  }

  ProductList getFavoriteProducts(FavoriteIds favIds) {
    if (favIds.isEmpty) return const [];
    return _catalog.where((p) => favIds.contains(p.id)).toList(growable: false);
  }

  void addToCart(Product product, {int quantity = 1}) {
    final updated = Map<String, CartItem>.from(cartNotifier.value.itemsById);
    if (updated.containsKey(product.id)) {
      final existing = updated[product.id]!;
      updated[product.id] =
          existing.copyWith(quantity: existing.quantity + quantity);
    } else {
      updated[product.id] = CartItem(product: product, quantity: quantity);
    }
    cartNotifier.value = CartState(updated);
  }

  void updateQuantity(String productId, int delta) {
    final updated = Map<String, CartItem>.from(cartNotifier.value.itemsById);
    if (!updated.containsKey(productId)) return;

    final currentItem = updated[productId]!;
    final newQuantity = currentItem.quantity + delta;
    if (newQuantity <= 0) {
      updated.remove(productId);
    } else {
      updated[productId] = currentItem.copyWith(quantity: newQuantity);
    }
    cartNotifier.value = CartState(updated);
  }

  void clearCart() {
    cartNotifier.value = CartState.empty;
  }

  void dispose() {
    _disposed = true;
    _searchDebounce?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    filteredProductsNotifier.dispose();
    isFilteringNotifier.dispose();
    isOptimizedModeNotifier.dispose();
    selectedCategoryNotifier.dispose();
    sortOptionNotifier.dispose();
    cartNotifier.dispose();
    favoritesNotifier.dispose();
    metricsNotifier.dispose();
  }
}

// ============================================================================
// UTILITÁRIOS DE FORMATAÇÃO (SEM REGEXP)
// ============================================================================

String formatCurrency(double value) {
  final parts = value.toStringAsFixed(2).split('.');
  final digits = parts[0];
  final buffer = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    final remaining = digits.length - i;
    if (i > 0 && remaining % 3 == 0) {
      buffer.write('.');
    }
    buffer.write(digits[i]);
  }
  return 'R\$ ${buffer.toString()},${parts[1]}';
}

// ============================================================================
// APLICATIVO PRINCIPAL
// ============================================================================

class EcommerceApp extends StatefulWidget {
  const EcommerceApp({super.key});

  @override
  State<EcommerceApp> createState() => _EcommerceAppState();
}

class _EcommerceAppState extends State<EcommerceApp> {
  final StoreController _store = StoreController();

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlutShop High-Performance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        scaffoldBackgroundColor: const Color(0xFFF6F7FB),
      ),
      home: MainNavigationScreen(store: _store),
    );
  }
}

// ============================================================================
// NAVEGAÇÃO PRINCIPAL (SEM REBUILD GLOBAL)
// ============================================================================

class MainNavigationScreen extends StatefulWidget {
  final StoreController store;

  const MainNavigationScreen({super.key, required this.store});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.bolt, color: Colors.indigo),
            SizedBox(width: 6),
            Text(
              'FlutShop',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Métricas e Comparativo (Antes vs. Depois)',
            icon: const Icon(Icons.speed, color: Colors.indigo),
            onPressed: () => _showPerformanceModal(context, widget.store),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: ValueListenableBuilder<CartState>(
              valueListenable: widget.store.cartNotifier,
              builder: (context, cart, _) {
                final totalItems = cart.totalItemsCount;
                return IconButton(
                  onPressed: () => setState(() => _currentIndex = 2),
                  icon: Badge(
                    isLabelVisible: totalItems > 0,
                    label: Text('$totalItems'),
                    child: const Icon(Icons.shopping_cart_outlined),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          CatalogView(store: widget.store),
          FavoritesView(store: widget.store),
          CartView(store: widget.store),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: 'Loja',
          ),
          NavigationDestination(
            icon: ValueListenableBuilder<FavoriteIds>(
              valueListenable: widget.store.favoritesNotifier,
              builder: (context, favs, _) {
                return Badge(
                  isLabelVisible: favs.isNotEmpty,
                  label: Text('${favs.length}'),
                  child: const Icon(Icons.favorite_border),
                );
              },
            ),
            selectedIcon: const Icon(Icons.favorite),
            label: 'Favoritos',
          ),
          NavigationDestination(
            icon: ValueListenableBuilder<CartState>(
              valueListenable: widget.store.cartNotifier,
              builder: (context, cart, _) {
                final totalItems = cart.totalItemsCount;
                return Badge(
                  isLabelVisible: totalItems > 0,
                  label: Text('$totalItems'),
                  child: const Icon(Icons.shopping_cart_outlined),
                );
              },
            ),
            selectedIcon: const Icon(Icons.shopping_cart),
            label: 'Carrinho',
          ),
        ],
      ),
    );
  }

  void _showPerformanceModal(BuildContext context, StoreController store) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return ValueListenableBuilder<PerformanceMetrics>(
          valueListenable: store.metricsNotifier,
          builder: (context, metrics, _) {
            final totalQueries = metrics.cacheHits + metrics.cacheMisses;
            final hitRate = totalQueries == 0
                ? '0%'
                : '${((metrics.cacheHits / totalQueries) * 100).toStringAsFixed(0)}%';
            final isSmooth = metrics.avgUiFrameMs <= 16.6;

            return Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.analytics, color: Colors.indigo),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Profiling (Antes vs. Depois)',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isSmooth
                              ? Colors.green.withAlpha(38)
                              : Colors.orange.withAlpha(38),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          isSmooth ? '60+ FPS' : 'Carga Alta',
                          style: TextStyle(
                            color: isSmooth
                                ? Colors.green[800]
                                : Colors.orange[800],
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<bool>(
                    valueListenable: store.isOptimizedModeNotifier,
                    builder: (context, isOptimized, _) {
                      return SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          isOptimized
                              ? 'Modo Otimizado (Isolate + Cache LRU)'
                              : 'Modo Sem Otimização (Main Thread)',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          isOptimized
                              ? 'Processamento paralelo sem travar a UI'
                              : 'Execução síncrona bloqueando a UI',
                        ),
                        value: isOptimized,
                        onChanged: store.toggleOptimizationMode,
                      );
                    },
                  ),
                  const Divider(),
                  _MetricRow(
                    label: 'Catálogo (Virtualizado):',
                    value: '${metrics.totalCatalogItems} itens',
                  ),
                  _MetricRow(
                    label: 'Itens Exibidos:',
                    value: '${metrics.visibleItemsCount} itens',
                  ),
                  _MetricRow(
                    label: 'Tempo de Processamento:',
                    value: '${metrics.lastProcessingMs} ms',
                  ),
                  _MetricRow(
                    label: 'Bloqueio na UI Thread:',
                    value: '${metrics.uiThreadBlockedMs} ms',
                  ),
                  _MetricRow(
                    label: 'Cache LRU (Hits / Misses):',
                    value:
                        '${metrics.cacheHits} / ${metrics.cacheMisses} ($hitRate)',
                  ),
                  _MetricRow(
                    label: 'UI Frame Time Médio:',
                    value: '${metrics.avgUiFrameMs} ms',
                  ),
                  _MetricRow(
                    label: 'Raster Frame Time Médio:',
                    value: '${metrics.avgRasterFrameMs} ms',
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;

  const _MetricRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: Colors.grey[700]),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ABA 1: CATÁLOGO DE PRODUTOS (VIRTUALIZAÇÃO + REPAINT BOUNDARY)
// ============================================================================

class CatalogView extends StatefulWidget {
  final StoreController store;

  const CatalogView({super.key, required this.store});

  @override
  State<CatalogView> createState() => _CatalogViewState();
}

class _CatalogViewState extends State<CatalogView> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: widget.store.setSearchQuery,
                  decoration: InputDecoration(
                    hintText: 'Buscar entre 5.000 produtos...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        widget.store.setSearchQuery('');
                      },
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<SortOption>(
                valueListenable: widget.store.sortOptionNotifier,
                builder: (context, currentSort, _) {
                  return PopupMenuButton<SortOption>(
                    tooltip: 'Ordenar',
                    icon: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.sort, color: Colors.indigo),
                    ),
                    initialValue: currentSort,
                    onSelected: widget.store.setSortOption,
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: SortOption.relevance,
                        child: Text('Relevância'),
                      ),
                      PopupMenuItem(
                        value: SortOption.priceAsc,
                        child: Text('Menor Preço'),
                      ),
                      PopupMenuItem(
                        value: SortOption.priceDesc,
                        child: Text('Maior Preço'),
                      ),
                      PopupMenuItem(
                        value: SortOption.ratingDesc,
                        child: Text('Melhor Avaliação'),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: ValueListenableBuilder<String>(
            valueListenable: widget.store.selectedCategoryNotifier,
            builder: (context, selectedCategory, _) {
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemCount: widget.store.categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final category = widget.store.categories[index];
                  return ChoiceChip(
                    label: Text(category),
                    selected: category == selectedCategory,
                    onSelected: (_) => widget.store.setCategory(category),
                  );
                },
              );
            },
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: widget.store.isFilteringNotifier,
          builder: (context, isFiltering, _) {
            return isFiltering
                ? const LinearProgressIndicator(minHeight: 2)
                : const SizedBox(height: 2);
          },
        ),
        Expanded(
          child: ValueListenableBuilder<ProductList>(
            valueListenable: widget.store.filteredProductsNotifier,
            builder: (context, products, _) {
              if (products.isEmpty) {
                return const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search_off, size: 64, color: Colors.grey),
                      SizedBox(height: 12),
                      Text(
                        'Nenhum produto encontrado.',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }

              return LayoutBuilder(
                builder: (context, constraints) {
                  final crossAxisCount = constraints.maxWidth > 900
                      ? 4
                      : constraints.maxWidth > 600
                          ? 3
                          : 2;

                  return GridView.builder(
                    padding: const EdgeInsets.all(16),
                    cacheExtent: 300,
                    addAutomaticKeepAlives: false,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.72,
                    ),
                    itemCount: products.length,
                    itemBuilder: (context, index) {
                      return RepaintBoundary(
                        child: ProductCard(
                          product: products[index],
                          store: widget.store,
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class ProductCard extends StatelessWidget {
  final Product product;
  final StoreController store;

  const ProductCard({
    super.key,
    required this.product,
    required this.store,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ProductDetailScreen(
                product: product,
                store: store,
              ),
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Container(
                    width: double.infinity,
                    color: product.color.withAlpha(31),
                    child: Center(
                      child: Icon(
                        product.icon,
                        size: 58,
                        color: product.color,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: ValueListenableBuilder<FavoriteIds>(
                      valueListenable: store.favoritesNotifier,
                      builder: (context, favs, _) {
                        final isFav = favs.contains(product.id);
                        return IconButton(
                          icon: Icon(
                            isFav ? Icons.favorite : Icons.favorite_border,
                            color: isFav ? Colors.red : Colors.grey[700],
                          ),
                          onPressed: () => store.toggleFavorite(product.id),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          product.category.toUpperCase(),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey[600],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.star, size: 12, color: Colors.amber),
                      const SizedBox(width: 2),
                      Text(
                        '${product.rating}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(
                          formatCurrency(product.price),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.indigo,
                          ),
                        ),
                      ),
                      IconButton.filled(
                        style: IconButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.add_shopping_cart, size: 18),
                        onPressed: () {
                          store.addToCart(product);
                          ScaffoldMessenger.of(context).clearSnackBars();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('${product.name} adicionado!'),
                              duration: const Duration(milliseconds: 900),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      ),
                    ],
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

// ============================================================================
// TELA DE DETALHES DO PRODUTO
// ============================================================================

class ProductDetailScreen extends StatefulWidget {
  final Product product;
  final StoreController store;

  const ProductDetailScreen({
    super.key,
    required this.product,
    required this.store,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  int _quantity = 1;

  @override
  Widget build(BuildContext context) {
    final product = widget.product;

    return Scaffold(
      appBar: AppBar(
        title: Text(product.category),
        actions: [
          ValueListenableBuilder<FavoriteIds>(
            valueListenable: widget.store.favoritesNotifier,
            builder: (context, favs, _) {
              final isFav = favs.contains(product.id);
              return IconButton(
                icon: Icon(
                  isFav ? Icons.favorite : Icons.favorite_border,
                  color: isFav ? Colors.red : null,
                ),
                onPressed: () => widget.store.toggleFavorite(product.id),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 240,
              color: product.color.withAlpha(31),
              child: Center(
                child: Icon(
                  product.icon,
                  size: 110,
                  color: product.color,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.amber.withAlpha(51),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.star,
                              size: 16,
                              color: Colors.amber,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              product.rating.toString(),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Text(
                        formatCurrency(product.price),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    product.name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Descrição do Produto',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    product.description,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: Colors.grey[800],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Text(
                        'Quantidade:',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      IconButton.outlined(
                        onPressed: _quantity > 1
                            ? () => setState(() => _quantity--)
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          '$_quantity',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton.outlined(
                        onPressed: () => setState(() => _quantity++),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onPressed: () {
              widget.store.addToCart(product, quantity: _quantity);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    '${_quantity}x ${product.name} adicionado ao carrinho!',
                  ),
                  behavior: SnackBarBehavior.floating,
                ),
              );
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.shopping_bag),
            label: Text(
              'Adicionar • ${formatCurrency(product.price * _quantity)}',
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// ABA 2: FAVORITOS
// ============================================================================

class FavoritesView extends StatelessWidget {
  final StoreController store;

  const FavoritesView({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FavoriteIds>(
      valueListenable: store.favoritesNotifier,
      builder: (context, favIds, _) {
        final favorites = store.getFavoriteProducts(favIds);

        if (favorites.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.favorite_border, size: 64, color: Colors.grey),
                SizedBox(height: 12),
                Text(
                  'Você ainda não possui favoritos.',
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: favorites.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final product = favorites[index];
            return Card(
              elevation: 0,
              color: Colors.white,
              child: ListTile(
                contentPadding: const EdgeInsets.all(12),
                leading: CircleAvatar(
                  radius: 26,
                  backgroundColor: product.color.withAlpha(38),
                  child: Icon(product.icon, color: product.color),
                ),
                title: Text(
                  product.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  formatCurrency(product.price),
                  style: const TextStyle(
                    color: Colors.indigo,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.add_shopping_cart),
                      onPressed: () {
                        store.addToCart(product);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content:
                                Text('${product.name} adicionado ao carrinho!'),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => store.toggleFavorite(product.id),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ============================================================================
// ABA 3: CARRINHO DE COMPRAS E CHECKOUT
// ============================================================================

class CartView extends StatelessWidget {
  final StoreController store;

  const CartView({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CartState>(
      valueListenable: store.cartNotifier,
      builder: (context, cart, _) {
        if (cart.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.remove_shopping_cart_outlined,
                  size: 64,
                  color: Colors.grey,
                ),
                SizedBox(height: 12),
                Text(
                  'Seu carrinho está vazio.',
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
              ],
            ),
          );
        }

        final items = cart.items;
        final subtotal = cart.subtotal;
        final shippingCost = cart.shippingCost;
        final totalPrice = cart.totalPrice;

        return Column(
          children: [
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Card(
                    elevation: 0,
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Row(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: item.product.color.withAlpha(38),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              item.product.icon,
                              color: item.product.color,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.product.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  formatCurrency(item.total),
                                  style: const TextStyle(
                                    color: Colors.indigo,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () =>
                                    store.updateQuantity(item.product.id, -1),
                              ),
                              Text(
                                '${item.quantity}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline),
                                onPressed: () =>
                                    store.updateQuantity(item.product.id, 1),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Subtotal:'),
                      Text(formatCurrency(subtotal)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Frete (Grátis acima de R\$ 1.000):'),
                      Text(
                        shippingCost == 0
                            ? 'Grátis'
                            : formatCurrency(shippingCost),
                        style: TextStyle(
                          color: shippingCost == 0 ? Colors.green : null,
                          fontWeight: shippingCost == 0
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Total:',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        formatCurrency(totalPrice),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: () => _showCheckoutModal(context),
                    child: const Text(
                      'Finalizar Compra',
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  void _showCheckoutModal(BuildContext context) {
    final formKey = GlobalKey<FormState>();
    String paymentMethod = 'PIX (5% de desconto)';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Dados de Entrega e Pagamento',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  decoration: const InputDecoration(
                    labelText: 'Nome Completo',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Informe seu nome' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  decoration: const InputDecoration(
                    labelText: 'Endereço de Entrega (Rua, Número, CEP)',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Informe o endereço'
                      : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: paymentMethod,
                  decoration: const InputDecoration(
                    labelText: 'Forma de Pagamento',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'PIX (5% de desconto)',
                      child: Text('PIX (Aprovação Imediata)'),
                    ),
                    DropdownMenuItem(
                      value: 'Cartão de Crédito',
                      child: Text('Cartão de Crédito (Até 12x)'),
                    ),
                    DropdownMenuItem(
                      value: 'Boleto Bancário',
                      child: Text('Boleto Bancário'),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) paymentMethod = val;
                  },
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Confirmar Pedido'),
                  onPressed: () {
                    if (formKey.currentState!.validate()) {
                      store.clearCart();
                      Navigator.of(ctx).pop();
                      showDialog(
                        context: context,
                        builder: (dialogCtx) => AlertDialog(
                          icon: const Icon(
                            Icons.verified,
                            color: Colors.green,
                            size: 48,
                          ),
                          title: const Text('Pedido Confirmado!'),
                          content: Text(
                            'Seu pedido foi processado com sucesso via $paymentMethod.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(dialogCtx).pop(),
                              child: const Text('Fechar'),
                            ),
                          ],
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}